-- lib/batchapi.lua
-- Batch image processing — POST /api/batch-img
--
-- Processes all image files in a local path (file or directory) using either:
--   mode=local   — imgproxy HTTP API (same-host Docker service)
--   mode=remote  — forwards each image to a remote /api/img endpoint
--                  (offloads heavy compute to a high-power box)
--
-- IMPORTANT: This module now uses imgproxy for ALL image processing.
--   - lua-vips is no longer used (see lib/vips.lua - deprecated)
--   - local mode: imgproxy reads from shared /data directory via local:// URLs
--   - remote mode: forwards to remote /api/img endpoint
--
-- ─────────────────────────────────────────────────────────────────────────────
-- REQUEST
-- ─────────────────────────────────────────────────────────────────────────────
--
--   POST /api/batch-img
--   Content-Type: application/json
--
--   {
--     "path":        "/images/vacation",   -- local file or directory (required)
--     "recursive":   false,                -- recurse into sub-directories (default: false)
--
--     -- image processing params (same as /img/ / /api/img)
--     "w":    800,                         -- target width  (pixels)
--     "h":    600,                         -- target height (pixels)
--     "fit":  "contain",                   -- contain | cover | fill | scale
--     "crop": "0,0,1920,1080",             -- crop before resize: "x,y,w,h"
--     "fmt":  "webp",                      -- output format: jpeg|webp|png|avif|gif
--     "q":    85,                          -- quality 1-100 (default 82)
--
--     -- output control
--     "out_suffix": "-thumb",              -- append suffix before extension: photo.jpg → photo-thumb.jpg
--     "out_dir":    "/images/thumbs",      -- write outputs to this directory instead (keeps filenames)
--     "overwrite":  true,                  -- overwrite existing output files (default: true)
--
--     -- processing mode
--     "mode":        "local",             -- "local" (default) | "remote"
--
--     -- extension filtering
--     "ignore_exts": "gif,webp",          -- comma-separated list of extensions to skip (preserves original)
--
--     -- remote mode options (ignored when mode=local)
--     "remote_url":  "http://10.0.0.5:5080/api/img",  -- remote /api/img endpoint
--     "concurrency": 8,                   -- parallel requests to remote (default: 4, max: 64)
--     "connect_timeout_ms": 5000,         -- TCP connect timeout ms (default: 5000)
--     "send_timeout_ms":    30000,        -- send timeout ms (default: 30000)
--     "recv_timeout_ms":    60000,        -- recv timeout ms (default: 60000)
--   }
--
-- ─────────────────────────────────────────────────────────────────────────────
-- RESPONSE  200 OK
-- ─────────────────────────────────────────────────────────────────────────────
--
--   {
--     "ok":      true,
--     "total":   42,
--     "done":    41,
--     "skipped": 1,
--     "errors":  [],
--     "results": [
--       { "src": "/images/vacation/a.jpg", "dst": "/images/vacation/a-thumb.jpg",
--         "size_in": 2048000, "size_out": 184320, "ms": 38 },
--       ...
--     ]
--   }
--
-- ─────────────────────────────────────────────────────────────────────────────
-- DESIGN NOTES
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Local mode (imgproxy):
--   • imgproxy runs as separate Docker service accessible via Docker DNS
--   • imgproxy reads source files from shared /data directory via local:// URLs
--   • Uses triple-slash local:/// format to avoid hostname parsing bug
--   • HTTP request/response for each image (but zero-copy disk read on imgproxy side)
--   • Concurrent processing via ngx.thread.spawn
--
-- Remote mode:
--   • Each image is read from disk, sent via HTTP/1.1 POST to remote /api/img.
--   • Uses ngx.socket.tcp with manual HTTP framing for zero-copy body streaming.
--   • A counting semaphore (ngx.semaphore) caps simultaneous in-flight requests
--     to `concurrency` so we don't flood the remote with too many connections.
--   • Keep-Alive is requested but not enforced (remote may or may not honour it).
--   • Result bytes are received into memory, then written to dst path on disk.
--
-- Extension filtering:
--   • ignore_exts="gif,webp" will skip processing for matching files.
--   • Skipped files are recorded in the response with reason "ignored".
--   • Useful for preserving animated GIF/WebP without re-encoding.

local _M = {}

-- ── Deps ───────────────────────────────────────────────────────────────────

local ffi      = require("ffi")
local bit      = require("bit")
local imgproc  = require("lib.imgproc")
local http     = require("resty.http")

-- ── imgproxy config ─────────────────────────────────────────────────────────

local IMGPROXY_HOST = os.getenv("IMGPROXY_HOST") or "imgproxy"
local IMGPROXY_PORT = os.getenv("IMGPROXY_PORT") or "8080"

-- ── FFI: opendir/readdir/stat ──────────────────────────────────────────────

ffi.cdef[[
  typedef struct DIR DIR;
  struct dirent {
    uint64_t  d_ino;
    int64_t   d_off;
    uint16_t  d_reclen;
    uint8_t   d_type;
    char      d_name[256];
  };
  DIR*           opendir(const char *name);
  struct dirent* readdir(DIR *dirp);
  int            closedir(DIR *dirp);

  typedef struct {
    uint64_t st_dev;
    uint64_t st_ino;
    uint64_t st_nlink;
    uint32_t st_mode;
    uint32_t st_uid;
    uint32_t st_gid;
    uint32_t __pad0;
    uint64_t st_rdev;
    int64_t  st_size;
    int64_t  st_blksize;
    int64_t  st_blocks;
    uint64_t st_atime;
    uint64_t st_atime_nsec;
    uint64_t st_mtime;
    uint64_t st_mtime_nsec;
    uint64_t st_ctime;
    uint64_t st_ctime_nsec;
    int64_t  __unused[3];
  } stat_t;
  int stat(const char *path, stat_t *buf);
  int mkdir(const char *path, unsigned int mode);
]]

local DT_REG = 8
local DT_DIR = 4

-- ── Helpers ────────────────────────────────────────────────────────────────

local function parse_int(v, default)
    local n = tonumber(v)
    if n and n > 0 then return math.floor(n) end
    return default
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return v end
    return hi
end

local function ext_of(path)
    return (path:match("%.([^./]+)$") or ""):lower()
end

local function basename(path)
    return path:match("([^/]+)$") or path
end

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function is_dir(path)
    local st = ffi.new("stat_t")
    if ffi.C.stat(path, st) ~= 0 then return false end
    return bit.band(st.st_mode, 0xF000) == 0x4000
end

local function file_size(path)
    local st = ffi.new("stat_t")
    if ffi.C.stat(path, st) ~= 0 then return 0 end
    return tonumber(st.st_size)
end

local function mkdir_p(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        parts[#parts+1] = part
    end
    local cur = ""
    for _, p in ipairs(parts) do
        cur = cur .. "/" .. p
        local st = ffi.new("stat_t")
        if ffi.C.stat(cur, st) ~= 0 then
            ffi.C.mkdir(cur, 0x1ED)  -- 0755
        end
    end
end

-- Read all bytes from a file; returns nil, err on failure
local function read_file(path)
    local fh = io.open(path, "rb")
    if not fh then return nil, "cannot open " .. path end
    local data = fh:read("*a")
    fh:close()
    return data
end

-- Write bytes to file, creating parent dirs as needed
local function write_file(path, data)
    mkdir_p(dirname(path))
    local fh = io.open(path, "wb")
    if not fh then return false, "cannot open for write: " .. path end
    fh:write(data)
    fh:close()
    return true
end

-- ── imgproxy URL builder ────────────────────────────────────────────────────

-- Map our fit values to imgproxy resizing_type
-- imgproxy supports: fit (default), fill (crop to fill), crop
-- Our API: contain (fit), cover (fill), fill (no equiv - fallback to fit), scale (fit)
-- Note: imgproxy has NO stretch mode, so fit=fill falls back to default (fit)
local function map_resizing_type(fit)
    if fit == "cover" then
        return "fill"  -- crop to fill, preserve aspect ratio
    elseif fit == "fill" then
        return nil  -- no stretch mode in imgproxy, fallback to default (fit)
    elseif fit == "scale" then
        return nil  -- same as contain, use default (fit)
    else
        return nil  -- nil means use imgproxy default (fit)
    end
end

-- Build imgproxy processing string from params
local function build_processing_string(w, h, fit, fmt, q)
    local parts = {}
    if w and w > 0 then table.insert(parts, "width:" .. tostring(w)) end
    if h and h > 0 then table.insert(parts, "height:" .. tostring(h)) end

    local resizing_type = map_resizing_type(fit)
    if resizing_type then
        table.insert(parts, "resizing_type:" .. resizing_type)
    end

    if fmt and fmt ~= "" then
        if fmt == "jpeg" then fmt = "jpg" end
        table.insert(parts, "format:" .. fmt)
    end
    if q and q > 0 then table.insert(parts, "quality:" .. tostring(q)) end
    return table.concat(parts, "/")
end

-- Build imgproxy local:// URL for a file path
-- imgproxy LOCAL_FILESYSTEM_ROOT=/data, so:
--   /data/images/photo.jpg → local:///images/photo.jpg
local function build_imgproxy_url(rel_path, w, h, fit, fmt, q)
    local processing = build_processing_string(w, h, fit, fmt, q)
    -- Use triple-slash local:/// to avoid hostname parsing bug
    return "/insecure/" .. processing .. "/plain/local:///" .. rel_path
end

-- ── Collect image files from path ──────────────────────────────────────────

-- Collect image files from path (file or directory)
-- ignore_set: table of extensions to skip (e.g. {gif=true, webp=true})
local function collect_files(path, recursive, ignore_set)
    local files = {}
    if is_dir(path) then
        local dir = ffi.C.opendir(path)
        if dir == nil then return files end
        local entry = ffi.C.readdir(dir)
        while entry ~= nil do
            local name = ffi.string(entry.d_name)
            if name ~= "." and name ~= ".." then
                local full = path .. "/" .. name
                if entry.d_type == DT_REG then
                    local e = ext_of(name)
                    if imgproc.PROCESSABLE_EXTS[e] and not imgproc.is_ext_ignored(e, ignore_set) then
                        files[#files+1] = full
                    end
                elseif entry.d_type == DT_DIR and recursive then
                    local sub = collect_files(full, true, ignore_set)
                    for _, f in ipairs(sub) do files[#files+1] = f end
                end
            end
            entry = ffi.C.readdir(dir)
        end
        ffi.C.closedir(dir)
    else
        local e = ext_of(path)
        if imgproc.PROCESSABLE_EXTS[e] and not imgproc.is_ext_ignored(e, ignore_set) then
            files[1] = path
        end
    end
    table.sort(files)
    return files
end

-- ── Build destination path ─────────────────────────────────────────────────

-- Build destination path for one source file
local function dst_path(src, out_dir, out_suffix, out_fmt)
    local base = basename(src)
    local stem = base:match("^(.+)%.[^.]+$") or base
    local ext  = ext_of(src)
    if out_fmt then
        ext = (out_fmt == "jpeg") and "jpg" or out_fmt
    end

    if out_dir then
        return out_dir:gsub("/+$", "") .. "/" .. stem .. "." .. ext
    elseif out_suffix then
        return dirname(src) .. "/" .. stem .. out_suffix .. "." .. ext
    else
        -- in-place: change extension only if fmt changed
        if out_fmt and ext ~= ext_of(src) then
            return dirname(src) .. "/" .. stem .. "." .. ext
        end
        return src
    end
end

-- Build /api/img query string from job params
local function build_query(params, ignore_exts)
    local parts = {}
    if params.w    then parts[#parts+1] = "w="    .. params.w    end
    if params.h    then parts[#parts+1] = "h="    .. params.h    end
    if params.fit  then parts[#parts+1] = "fit="  .. params.fit  end
    if params.crop then parts[#parts+1] = "crop=" .. params.crop end
    if params.fmt  then parts[#parts+1] = "fmt="  .. params.fmt  end
    if params.q    then parts[#parts+1] = "q="    .. params.q    end
    if ignore_exts then parts[#parts+1] = "ignore_exts=" .. ignore_exts end
    return table.concat(parts, "&")
end

-- ── Simple JSON helpers ────────────────────────────────────────────────────

local function json_str(s)
    if s == nil then return "null" end
    s = tostring(s)
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
    return '"' .. s .. '"'
end

local function json_encode(t)
    local parts = {"{"}
    local first  = true
    for k, v in pairs(t) do
        if not first then parts[#parts+1] = "," end
        first = false
        parts[#parts+1] = json_str(k) .. ":"
        local tv = type(v)
        if tv == "number"  then parts[#parts+1] = tostring(v)
        elseif tv == "boolean" then parts[#parts+1] = v and "true" or "false"
        elseif tv == "table"   then parts[#parts+1] = json_encode(v)
        else                       parts[#parts+1] = json_str(v)
        end
    end
    parts[#parts+1] = "}"
    return table.concat(parts)
end

local function json_array(arr)
    local parts = {"["}
    for i, v in ipairs(arr) do
        if i > 1 then parts[#parts+1] = "," end
        local tv = type(v)
        if tv == "table"   then parts[#parts+1] = json_encode(v)
        elseif tv == "number"  then parts[#parts+1] = tostring(v)
        elseif tv == "boolean" then parts[#parts+1] = v and "true" or "false"
        else                       parts[#parts+1] = json_str(v)
        end
    end
    parts[#parts+1] = "]"
    return table.concat(parts)
end

-- Minimal JSON request body parser
local function parse_json_body(s)
    local out = {}
    -- strings
    for k, v in s:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
        out[k] = v
    end
    -- numbers
    for k, v in s:gmatch('"([^"]+)"%s*:%s*(%-?%d+%.?%d*)') do
        if out[k] == nil then out[k] = tonumber(v) end
    end
    -- booleans
    for k in s:gmatch('"([^"]+)"%s*:%s*true') do
        if out[k] == nil then out[k] = true end
    end
    for k in s:gmatch('"([^"]+)"%s*:%s*false') do
        if out[k] == nil then out[k] = false end
    end
    -- null
    for k in s:gmatch('"([^"]+)"%s*:%s*null') do
        if out[k] == nil then out[k] = nil end
    end
    return out
end

-- ── Local processing via imgproxy HTTP ─────────────────────────────────────

local function process_local_one(src, dst, params, overwrite, webdav_root)
    if not overwrite and src ~= dst then
        local st = ffi.new("stat_t")
        if ffi.C.stat(dst, st) == 0 then
            return false, "exists"
        end
    end

    local t0 = ngx.now()

    -- Read source file
    local body, rerr = read_file(src)
    if not body then return false, rerr end

    local sz_in = #body
    local src_ext = ext_of(src)

    -- Check animated (quick header check)
    local skip, reason = imgproc.should_skip_animated(src_ext, body)
    if skip then
        -- Copy original if dst differs
        if src ~= dst then
            local wok, werr = write_file(dst, body)
            if not wok then return false, werr end
        end
        return true, { src=src, dst=dst, size_in=sz_in, size_out=sz_in, ms=0, note=reason }
    end

    -- Build imgproxy URL using local:// URL scheme
    -- Convert absolute path to relative path for local:// URL
    -- /data/images/photo.jpg → images/photo.jpg
    local rel_path = src
    if webdav_root and src:find("^" .. webdav_root) then
        rel_path = src:sub(#webdav_root + 2)
    elseif src:find("^/data/") then
        rel_path = src:sub(7)  -- remove /data/ prefix
    end

    local processing = build_processing_string(
        params.w and tonumber(params.w),
        params.h and tonumber(params.h),
        params.fit,
        params.fmt,
        params.q and tonumber(params.q)
    )

    -- Use local:// URL scheme: /insecure/<processing>/plain/local:///<rel_path>
    -- imgproxy reads directly from local filesystem (IMGPROXY_LOCAL_FILESYSTEM_ROOT=/data)
    local imgproxy_path = "/insecure/" .. processing .. "/plain/local:///" .. rel_path

    -- Connect to imgproxy and request the processed image
    local httpc = http.new()
    httpc:set_timeout(30000)

    local ok, err = httpc:connect(IMGPROXY_HOST, tonumber(IMGPROXY_PORT))
    if not ok then
        return false, "imgproxy connect failed: " .. tostring(err)
    end

    local proxy_res, err = httpc:request({
        method = "GET",
        path = imgproxy_path,
        headers = {
            ["Host"] = "localhost",
        }
    })

    if not proxy_res then
        httpc:close()
        return false, "imgproxy request failed: " .. tostring(err)
    end

    local res_body, err = proxy_res:read_body()
    if not res_body then
        httpc:close()
        return false, "imgproxy read body failed: " .. tostring(err)
    end

    httpc:set_keepalive(10000, 64)

    if proxy_res.status ~= 200 then
        return false, "imgproxy returned " .. proxy_res.status
    end

    local wok, werr = write_file(dst, res_body)
    if not wok then return false, werr end

    local ms = math.floor((ngx.now() - t0) * 1000)
    return true, { src=src, dst=dst, size_in=sz_in, size_out=#res_body, ms=ms }
end

-- ── Remote processing (HTTP/1.1 to remote /api/img) ───────────────────────

local function parse_url(url)
    local host, port, path = url:match("^https?://([^:/]+):(%d+)(/.*)$")
    if host then
        return host, tonumber(port), path
    end
    host, path = url:match("^https?://([^/]+)(/.*)$")
    if host then
        return host, 80, path
    end
    return nil
end

local function remote_send_one(host, port, path_base, query, body, mime,
                                connect_ms, send_ms, recv_ms)
    local sock = ngx.socket.tcp()
    sock:settimeout(connect_ms)

    local ok, err = sock:connect(host, port)
    if not ok then
        return nil, "connect failed: " .. tostring(err)
    end
    sock:settimeout(send_ms)

    local req_path = query ~= "" and (path_base .. "?" .. query) or path_base
    local req = table.concat({
        "POST " .. req_path .. " HTTP/1.1\r\n",
        "Host: " .. host .. ":" .. tostring(port) .. "\r\n",
        "Content-Type: " .. (mime or "application/octet-stream") .. "\r\n",
        "Content-Length: " .. #body .. "\r\n",
        "Connection: keep-alive\r\n",
        "Accept: */*\r\n",
        "\r\n",
    })

    local bytes, serr = sock:send(req)
    if not bytes then
        sock:close()
        return nil, "send header failed: " .. tostring(serr)
    end

    bytes, serr = sock:send(body)
    if not bytes then
        sock:close()
        return nil, "send body failed: " .. tostring(serr)
    end

    sock:settimeout(recv_ms)
    local status_line, rerr = sock:receive("*l")
    if not status_line then
        sock:close()
        return nil, "receive status failed: " .. tostring(rerr)
    end

    local status_code = tonumber(status_line:match("HTTP/%S+%s+(%d+)")) or 0
    local content_length = nil

    while true do
        local line, lerr = sock:receive("*l")
        if not line or lerr then break end
        if line == "" or line == "\r" then break end
        local k, v = line:match("^([^:]+):%s*(.+)$")
        if k then
            local kl = k:lower():gsub("%s","")
            if kl == "content-length" then
                content_length = tonumber(v)
            end
        end
    end

    if status_code ~= 200 then
        local err_body = ""
        if content_length and content_length > 0 then
            err_body = sock:receive(math.min(content_length, 512)) or ""
        end
        sock:setkeepalive(10000, 64)
        return nil, "remote returned " .. status_code .. ": " .. err_body
    end

    local resp_body
    if content_length then
        resp_body, rerr = sock:receive(content_length)
        if not resp_body then
            sock:close()
            return nil, "receive body failed: " .. tostring(rerr)
        end
    else
        local chunks = {}
        while true do
            local chunk, cerr = sock:receive(65536)
            if not chunk then break end
            chunks[#chunks+1] = chunk
        end
        resp_body = table.concat(chunks)
    end

    sock:setkeepalive(10000, 64)
    return resp_body, nil
end

local function process_remote_one(src, dst, params, overwrite,
                                   host, port, base_path,
                                   connect_ms, send_ms, recv_ms,
                                   ignore_exts)
    if not overwrite and src ~= dst then
        local st = ffi.new("stat_t")
        if ffi.C.stat(dst, st) == 0 then
            return false, "exists"
        end
    end

    local t0 = ngx.now()

    local body, rerr = read_file(src)
    if not body then return false, rerr end

    local sz_in  = #body
    local src_ext = ext_of(src)
    local mime    = imgproc.MIME_OF_EXT[src_ext] or "application/octet-stream"
    local query   = build_query(params, ignore_exts)

    local out_buf, oerr = remote_send_one(
        host, port, base_path, query, body, mime,
        connect_ms, send_ms, recv_ms
    )
    if not out_buf then return false, oerr end

    local sz_out = #out_buf
    local wok, werr = write_file(dst, out_buf)
    if not wok then return false, werr end

    local ms = math.floor((ngx.now() - t0) * 1000)
    return true, { src=src, dst=dst, size_in=sz_in, size_out=sz_out, ms=ms }
end

-- ── Main handler ───────────────────────────────────────────────────────────

function _M.handle(webdav_root)
    if ngx.req.get_method() ~= "POST" then
        ngx.status = 405
        ngx.header["Allow"] = "POST"
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"method_not_allowed","message":"use POST"}')
        return ngx.exit(405)
    end

    ngx.req.read_body()
    local req_body = ngx.req.get_body_data()
    if not req_body then
        local fname = ngx.req.get_body_file()
        if fname then
            local fh = io.open(fname, "rb")
            if fh then req_body = fh:read("*a"); fh:close() end
        end
    end

    if not req_body or #req_body == 0 then
        ngx.status = 400
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"bad_request","message":"empty body — send JSON parameters"}')
        return ngx.exit(400)
    end

    local p = parse_json_body(req_body)

    if not p.path or p.path == "" then
        ngx.status = 400
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"bad_request","message":"field \"path\" is required"}')
        return ngx.exit(400)
    end

    -- Normalise path
    local abs_path = p.path
    if abs_path:sub(1,1) ~= "/" then
        abs_path = (webdav_root or "") .. "/" .. abs_path
    end

    -- Security: reject path traversal
    if abs_path:find("%.%.") then
        ngx.status = 400
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"bad_request","message":"path traversal not allowed"}')
        return ngx.exit(400)
    end

    -- Parse ignore_exts
    local ignore_exts = p.ignore_exts
    local ignore_set = imgproc.parse_ignore_exts(ignore_exts)

    local recursive = p.recursive == true
    local files = collect_files(abs_path, recursive, ignore_set)

    if #files == 0 then
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"ok":true,"total":0,"done":0,"skipped":0,"errors":[],"results":[]}')
        return
    end

    -- Build image params table
    local img_params = {
        w    = p.w    and tostring(p.w)    or nil,
        h    = p.h    and tostring(p.h)    or nil,
        fit  = p.fit  or nil,
        crop = p.crop or nil,
        fmt  = p.fmt  or nil,
        q    = p.q    and tostring(p.q)    or nil,
    }

    local out_dir    = p.out_dir
    local out_suffix = p.out_suffix
    local overwrite  = (p.overwrite ~= false)

    local dst_list = {}
    for _, src in ipairs(files) do
        dst_list[#dst_list+1] = dst_path(src, out_dir, out_suffix, p.fmt)
    end

    local mode = (p.mode or "local"):lower()
    local results = {}
    local errors  = {}
    local done    = 0
    local skipped = 0

    if mode == "remote" then
        -- ── Remote mode ────────────────────────────────────────────────────
        local remote_url = p.remote_url
        if not remote_url or remote_url == "" then
            ngx.status = 400
            ngx.header["Content-Type"] = "application/json; charset=utf-8"
            ngx.print('{"error":"bad_request","message":"mode=remote requires \"remote_url\""}')
            return ngx.exit(400)
        end

        local rhost, rport, rpath = parse_url(remote_url)
        if not rhost then
            ngx.status = 400
            ngx.header["Content-Type"] = "application/json; charset=utf-8"
            ngx.print('{"error":"bad_request","message":"invalid remote_url"}')
            return ngx.exit(400)
        end

        local concurrency   = clamp(parse_int(p.concurrency, 4), 1, 64)
        local connect_ms    = parse_int(p.connect_timeout_ms, 5000)
        local send_ms       = parse_int(p.send_timeout_ms,   30000)
        local recv_ms       = parse_int(p.recv_timeout_ms,   60000)

        local ok_sem, sema = pcall(require, "ngx.semaphore")
        if not ok_sem then
            concurrency = 1
        end

        local sem = ok_sem and sema.new(concurrency) or nil
        local threads = {}

        local function spawn_one(i)
            local src = files[i]
            local dst = dst_list[i]
            local function task()
                if sem then
                    local wait_ok, wait_err = sem:wait(recv_ms / 1000 + 5)
                    if not wait_ok then
                        return false, "semaphore wait: " .. tostring(wait_err)
                    end
                end
                local ok2, res = process_remote_one(
                    src, dst, img_params, overwrite,
                    rhost, rport, rpath,
                    connect_ms, send_ms, recv_ms,
                    ignore_exts
                )
                if sem then sem:post(1) end
                return ok2, res
            end
            return ngx.thread.spawn(task)
        end

        for i = 1, #files do
            threads[i] = spawn_one(i)
        end

        for i = 1, #threads do
            local thread_ok, proc_ok, data = ngx.thread.wait(threads[i])
            if not thread_ok then
                errors[#errors+1] = { src=files[i], error=tostring(proc_ok) }
            elseif not proc_ok then
                if data == "exists" then
                    skipped = skipped + 1
                else
                    errors[#errors+1] = { src=files[i], error=tostring(data) }
                end
            elseif type(data) == "table" then
                done = done + 1
                results[#results+1] = data
            end
        end

    else
        -- ── Local mode (via imgproxy HTTP) ─────────────────────────────────
        for i, src in ipairs(files) do
            local dst2 = dst_list[i]
            local ok2, res = process_local_one(src, dst2, img_params, overwrite, webdav_root)
            if not ok2 then
                if res == "exists" then
                    skipped = skipped + 1
                else
                    errors[#errors+1] = { src=src, error=tostring(res) }
                end
            elseif type(res) == "table" then
                done = done + 1
                results[#results+1] = res
            end
        end
    end

    -- Build JSON response
    local resp = {
        ok      = (#errors == 0),
        total   = #files,
        done    = done,
        skipped = skipped,
        errors  = errors,
        results = results,
    }

    local ok_j, json_out = pcall(function()
        return table.concat({
            '{"ok":', resp.ok and "true" or "false",
            ',"total":',   resp.total,
            ',"done":',    resp.done,
            ',"skipped":', resp.skipped,
            ',"errors":',  json_array(resp.errors),
            ',"results":', json_array(resp.results),
            '}',
        })
    end)

    if not ok_j then
        ngx.log(ngx.ERR, "[batchapi] JSON encode failed: ", tostring(json_out))
        ngx.status = 500
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"internal","message":"response encode failed"}')
        return ngx.exit(500)
    end

    ngx.header["Content-Type"]   = "application/json; charset=utf-8"
    ngx.header["Content-Length"] = #json_out
    ngx.print(json_out)
end

return _M