-- lib/batchapi.lua
-- Batch image processing — POST /api/batch-img
--
-- Processes all image files in a local path (file or directory) using either:
--   mode=local   — libvips in-process (zero network, saturates local CPU)
--   mode=remote  — forwards each image to a remote /api/img endpoint
--                  (offloads heavy compute to a high-power box)
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
--     -- image processing params (same as /api/img / /img/)
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
--     -- remote mode options (ignored when mode=local)
--     "remote_url":  "http://10.0.0.5:5080/api/img",  -- remote /api/img endpoint
--     "concurrency": 8,                   -- parallel requests to remote (default: 4, max: 64)
--     "connect_timeout_ms": 5000,         -- TCP connect timeout ms (default: 5000)
--     "send_timeout_ms":    30000,        -- send timeout ms (default: 30000)
--     "recv_timeout_ms":    60000,        -- recv timeout ms (default: 60000)
--
--     -- local mode concurrency (ignored when mode=remote)
--     "local_threads": 0                  -- vips worker threads per item (0 = auto, default: 0)
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
-- Local mode:
--   • Uses ngx.thread.spawn to run multiple vips pipelines in the same worker.
--   • vips.concurrency_set controls internal thread pool per vips operation.
--   • Images are read and written directly to disk (no body buffering needed).
--   • No network I/O.
--
-- Remote mode:
--   • Each image is read from disk, sent via HTTP/1.1 POST to remote /api/img.
--   • Uses ngx.socket.tcp with manual HTTP framing for zero-copy body streaming.
--   • A counting semaphore (ngx.semaphore) caps simultaneous in-flight requests
--     to `concurrency` so we don't flood the remote with too many connections.
--   • Keep-Alive is requested but not enforced (remote may or may not honour it).
--   • Result bytes are received into memory, then written to dst path on disk.
--
-- Output naming:
--   • out_suffix="/images/thumbs"  → write to /images/thumbs/<original-name>.<ext>
--   • out_suffix="-thumb"          → /path/to/photo.jpg → /path/to/photo-thumb.jpg
--   • neither                      → overwrite source in-place
--   • fmt conversion is applied to the extension when out_dir or out_suffix used.

local _M = {}

-- ── Deps ───────────────────────────────────────────────────────────────────

local ffi      = require("ffi")
local bit      = require("bit")

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

-- ── Image extensions we process ───────────────────────────────────────────

local IMAGE_EXTS = {
    jpg=true, jpeg=true, png=true, webp=true,
    avif=true, gif=true, tiff=true, tif=true, bmp=true,
}

-- MIME types for HTTP send
local MIME_OF_EXT = {
    jpg="image/jpeg", jpeg="image/jpeg",
    png="image/png",  webp="image/webp",
    avif="image/avif", gif="image/gif",
    tiff="image/tiff", tif="image/tiff",
    bmp="image/bmp",
}

-- ── Helpers ────────────────────────────────────────────────────────────────

local function parse_int(v, default)
    local n = tonumber(v)
    if n and n > 0 then return math.floor(n) end
    return default
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
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
    -- Create all missing parent directories
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

-- Collect image files from path (file or directory)
local function collect_files(path, recursive)
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
                    if IMAGE_EXTS[e] then
                        files[#files+1] = full
                    end
                elseif entry.d_type == DT_DIR and recursive then
                    local sub = collect_files(full, true)
                    for _, f in ipairs(sub) do files[#files+1] = f end
                end
            end
            entry = ffi.C.readdir(dir)
        end
        ffi.C.closedir(dir)
    else
        local e = ext_of(path)
        if IMAGE_EXTS[e] then
            files[1] = path
        end
    end
    table.sort(files)
    return files
end

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
local function build_query(params)
    local parts = {}
    if params.w    then parts[#parts+1] = "w="    .. params.w    end
    if params.h    then parts[#parts+1] = "h="    .. params.h    end
    if params.fit  then parts[#parts+1] = "fit="  .. params.fit  end
    if params.crop then parts[#parts+1] = "crop=" .. params.crop end
    if params.fmt  then parts[#parts+1] = "fmt="  .. params.fmt  end
    if params.q    then parts[#parts+1] = "q="    .. params.q    end
    return table.concat(parts, "&")
end

-- Build vips save suffix (strip metadata for speed)
local function build_save_suffix(fmt, q, src_ext)
    fmt = (fmt and fmt:lower()) or ""
    if fmt == "jpeg" then fmt = "jpg" end
    q = clamp(parse_int(q, 82), 1, 100)
    if fmt == "jpg"  then return ".jpg[Q="  .. q .. ",strip]", "jpg"
    elseif fmt == "webp" then return ".webp[Q=" .. q .. ",strip]", "webp"
    elseif fmt == "avif" then return ".avif[Q=" .. q .. ",strip]", "avif"
    elseif fmt == "png"  then return ".png[strip]", "png"
    elseif fmt == "gif"  then return ".gif", "gif"
    end
    local e = src_ext:lower()
    if e == "jpg" or e == "jpeg" then return ".jpg[Q="  .. q .. ",strip]", "jpg"
    elseif e == "png"  then return ".png[strip]", "png"
    elseif e == "webp" then return ".webp[Q=" .. q .. ",strip]", "webp"
    elseif e == "avif" then return ".avif[Q=" .. q .. ",strip]", "avif"
    elseif e == "gif"  then return ".gif", "gif"
    else                     return ".jpg[Q="  .. q .. ",strip]", "jpg"
    end
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

-- Minimal JSON request body parser: extracts string/number/bool fields
-- Only handles flat objects (no nested tables needed for our request schema)
local function parse_json_body(s)
    local out = {}
    -- strings
    for k, v in s:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
        out[k] = v
    end
    -- numbers (int / float)
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

-- ── Local processing (lib/vips directly) ──────────────────────────────────

local function process_local_one(src, dst, params, overwrite)
    if not overwrite and src ~= dst then
        local st = ffi.new("stat_t")
        if ffi.C.stat(dst, st) == 0 then
            return false, "exists"
        end
    end

    local t0 = ngx.now()

    local body, rerr = read_file(src)
    if not body then return false, rerr end

    local ok_vips, vips = pcall(require, "vips")
    if not ok_vips then return false, "lua-vips unavailable" end

    -- JPEG shrink hint
    local src_ext = ext_of(src)
    local load_opts = ""
    if (src_ext == "jpg" or src_ext == "jpeg") and (params.w or params.h) then
        load_opts = "[shrink=8]"
    end

    local ok2, img = pcall(vips.Image.new_from_buffer, body, load_opts)
    if not ok2 then return false, "decode failed: " .. tostring(img) end

    -- Release source body early (GC hint)
    body = nil  -- luacheck: ignore

    -- Crop
    if params.crop then
        local cx, cy, cw, ch = params.crop:match("(%d+),(%d+),(%d+),(%d+)")
        if cx then
            cx,cy,cw,ch = tonumber(cx),tonumber(cy),tonumber(cw),tonumber(ch)
            cw = math.min(cw, img:width()  - cx)
            ch = math.min(ch, img:height() - cy)
            if cw > 0 and ch > 0 then
                local ok3, c = pcall(function() return img:crop(cx,cy,cw,ch) end)
                if ok3 then img = c end
            end
        end
    end

    -- Resize
    if params.w or params.h then
        local sw, sh = img:width(), img:height()
        local fit = params.fit or "contain"
        if fit == "fill" then
            local tw = params.w or sw
            local th = params.h or sh
            local ok4, r = pcall(function() return img:resize(tw/sw, {vscale=th/sh}) end)
            if ok4 then img = r end
        elseif fit == "cover" then
            local tw    = params.w or sw
            local th    = params.h or sh
            local scale = math.max(tw/sw, th/sh)
            local ok4, r = pcall(function() return img:resize(scale) end)
            if ok4 then img = r end
            local cx2 = math.floor((img:width()  - tw) / 2)
            local cy2 = math.floor((img:height() - th) / 2)
            if cx2 >= 0 and cy2 >= 0 then
                local ok5, c2 = pcall(function() return img:crop(cx2,cy2,tw,th) end)
                if ok5 then img = c2 end
            end
        elseif fit == "scale" then
            if params.w then
                local ok4, r = pcall(function() return img:resize(params.w/sw) end)
                if ok4 then img = r end
            end
        else  -- contain
            local tw    = params.w or math.huge
            local th    = params.h or math.huge
            local scale = math.min(tw/sw, th/sh)
            if scale ~= 1.0 then
                local ok4, r = pcall(function() return img:resize(scale) end)
                if ok4 then img = r end
            end
        end
    end

    local save_sfx = build_save_suffix(params.fmt, params.q, src_ext)

    local ok6, buf = pcall(function() return img:write_to_buffer(save_sfx) end)
    if not ok6 or not buf then return false, "encode failed: " .. tostring(buf) end

    local sz_in  = file_size(src)
    local sz_out = #buf

    local wok, werr = write_file(dst, buf)
    if not wok then return false, werr end

    local ms = math.floor((ngx.now() - t0) * 1000)
    return true, { src=src, dst=dst, size_in=sz_in, size_out=sz_out, ms=ms }
end

-- ── Remote processing (HTTP/1.1 to remote /api/img) ───────────────────────

-- Parse host, port, path from a URL like http://host:port/api/img
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

-- Send one image to remote /api/img via raw TCP HTTP/1.1.
-- Returns processed_bytes, nil on success; nil, err on failure.
local function remote_send_one(host, port, path_base, query, body, mime,
                                connect_ms, send_ms, recv_ms)
    local sock = ngx.socket.tcp()
    sock:settimeout(connect_ms)

    local ok, err = sock:connect(host, port)
    if not ok then
        return nil, "connect failed: " .. tostring(err)
    end
    sock:settimeout(send_ms)

    -- Build HTTP/1.1 request
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

    -- Read response headers
    sock:settimeout(recv_ms)
    local status_line, rerr = sock:receive("*l")
    if not status_line then
        sock:close()
        return nil, "receive status failed: " .. tostring(rerr)
    end

    local status_code = tonumber(status_line:match("HTTP/%S+%s+(%d+)")) or 0
    local resp_headers = {}
    local content_length = nil

    while true do
        local line, lerr = sock:receive("*l")
        if not line or lerr then break end
        if line == "" or line == "\r" then break end
        local k, v = line:match("^([^:]+):%s*(.+)$")
        if k then
            local kl = k:lower():gsub("%s","")
            resp_headers[kl] = v:gsub("%s*$","")
            if kl == "content-length" then
                content_length = tonumber(v)
            end
        end
    end

    if status_code ~= 200 then
        -- Read error body for diagnostics
        local err_body = ""
        if content_length and content_length > 0 then
            err_body = sock:receive(math.min(content_length, 512)) or ""
        end
        sock:setkeepalive(10000, 64)
        return nil, "remote returned " .. status_code .. ": " .. err_body
    end

    -- Read response body
    local resp_body
    if content_length then
        resp_body, rerr = sock:receive(content_length)
        if not resp_body then
            sock:close()
            return nil, "receive body failed: " .. tostring(rerr)
        end
    else
        -- Chunked or connection-close: read until closed
        local chunks = {}
        while true do
            local chunk, cerr = sock:receive(65536)
            if not chunk then break end
            chunks[#chunks+1] = chunk
        end
        resp_body = table.concat(chunks)
    end

    sock:setkeepalive(10000, 64)  -- return to pool, keep-alive 10s, max 64 conns
    return resp_body, nil
end

local function process_remote_one(src, dst, params, overwrite,
                                   host, port, base_path,
                                   connect_ms, send_ms, recv_ms)
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
    local mime    = MIME_OF_EXT[src_ext] or "application/octet-stream"
    local query   = build_query(params)

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

    -- Parse request JSON
    local p = parse_json_body(req_body)

    if not p.path or p.path == "" then
        ngx.status = 400
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"bad_request","message":"field \\"path\\" is required"}')
        return ngx.exit(400)
    end

    -- Normalise path: relative → absolute under webdav_root
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

    local recursive = p.recursive == true
    local files = collect_files(abs_path, recursive)

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

    -- Resolve output naming
    local out_dir    = p.out_dir
    local out_suffix = p.out_suffix
    local overwrite  = (p.overwrite ~= false)  -- default true

    -- Build dst path list
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
            ngx.print('{"error":"bad_request","message":"mode=remote requires \\"remote_url\\""}')
            return ngx.exit(400)
        end

        local rhost, rport, rpath = parse_url(remote_url)
        if not rhost then
            ngx.status = 400
            ngx.header["Content-Type"] = "application/json; charset=utf-8"
            ngx.print('{"error":"bad_request","message":"invalid remote_url — expected http://host:port/path"}')
            return ngx.exit(400)
        end

        local concurrency   = clamp(parse_int(p.concurrency, 4), 1, 64)
        local connect_ms    = parse_int(p.connect_timeout_ms, 5000)
        local send_ms       = parse_int(p.send_timeout_ms,   30000)
        local recv_ms       = parse_int(p.recv_timeout_ms,   60000)

        -- Semaphore to cap simultaneous in-flight requests
        local ok_sem, sema = pcall(require, "ngx.semaphore")
        if not ok_sem then
            -- Fallback: sequential processing if semaphore unavailable
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
                    connect_ms, send_ms, recv_ms
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
            -- ngx.thread.wait returns: thread_ok, retval1, retval2, ...
            -- task() returns: proc_ok, data_or_err
            -- so we get: thread_ok, proc_ok, data_or_err
            local thread_ok, proc_ok, data = ngx.thread.wait(threads[i])
            if not thread_ok then
                -- coroutine itself threw an unhandled error
                errors[#errors+1] = { src=files[i], error=tostring(proc_ok) }
            elseif not proc_ok then
                -- process_remote_one returned false, data is the error string
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
        -- ── Local mode (sequential with vips internal threading) ────────────
        -- vips manages its own thread pool internally; each call to vips can
        -- saturate all CPU cores. Running multiple simultaneous vips calls
        -- in the same worker would compete, so we process sequentially here.
        -- For directory-level parallelism, scale nginx worker count instead.
        for i, src in ipairs(files) do
            local dst2 = dst_list[i]
            local ok2, res = process_local_one(src, dst2, img_params, overwrite)
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
