-- lib/zipfs.lua
-- ZIP Virtual Filesystem for OpenResty
--
-- HTTP access:
--   GET /zip/<path/to/archive.zip>/          → directory listing
--   GET /zip/<path/to/archive.cbz>/<entry>   → serve file from ZIP-like archive
--
-- WebDAV transparent integration (rewrite_by_lua_block in main.conf):
--   PROPFIND on any *.zip / *.cbz path → returns DAV XML for entries inside archive
--   GET/HEAD on *.zip / *.cbz path     → redirects to /zip/ virtual FS
--   Enabled by default; set OR_ZIPFS_TRANSPARENT=false to disable
--
-- Supported extensions: configured via OR_ZIP_EXTS env var (default: zip,cbz)
-- Requires: luazip (already installed in orabase:1)

local _M = {}

-- ──────────────────────────────────────────────────────────
-- Supported ZIP-like extensions (configurable via OR_ZIP_EXTS)
-- Default: zip,cbz
-- Set OR_ZIP_EXTS=zip,cbz,cbr,epub to override
-- ──────────────────────────────────────────────────────────
local _zip_exts  -- lazily initialised set, keys are lowercase extensions

local function get_zip_exts()
    if _zip_exts then return _zip_exts end
    local raw = "zip,cbz"  -- built-in default
    local ok, env = pcall(require, "env")
    if ok and env and env.OR_ZIP_EXTS and env.OR_ZIP_EXTS ~= "" then
        raw = env.OR_ZIP_EXTS
    end
    _zip_exts = {}
    for ext in raw:gmatch("[^,;%s]+") do
        _zip_exts[ext:lower()] = true
    end
    return _zip_exts
end

-- Find the position (end index) of the first zip-like ext occurrence in s
-- Returns: end_pos (inclusive)  e.g. for "foo/bar.cbz/img" → 11
local function find_zip_ext(s)
    local exts = get_zip_exts()
    local best_pos, best_ext = nil, nil
    for ext in pairs(exts) do
        local pat = "%." .. ext  -- Lua pattern, not plain (ext has no specials)
        local i, j = s:lower():find(pat)
        if i then
            if not best_pos or i < best_pos then
                best_pos = j  -- end of the extension
                best_ext  = s:sub(i, j)  -- preserve original case from URI
            end
        end
    end
    return best_pos, best_ext
end

-- ──────────────────────────────────────────────────────────
-- MIME types
-- ──────────────────────────────────────────────────────────
local mime_map = {
    html="text/html; charset=utf-8", htm="text/html; charset=utf-8",
    css="text/css", js="application/javascript", json="application/json",
    xml="application/xml", txt="text/plain; charset=utf-8", md="text/plain; charset=utf-8",
    jpg="image/jpeg", jpeg="image/jpeg", jfif="image/jpeg", jpe="image/jpeg",
    png="image/png", gif="image/gif", webp="image/webp", avif="image/avif",
    svg="image/svg+xml", ico="image/x-icon", bmp="image/bmp",
    heic="image/heic", heif="image/heif", tiff="image/tiff", tif="image/tiff",
    pdf="application/pdf", zip="application/zip", gz="application/gzip", cbz="application/zip",
    mp4="video/mp4", mp3="audio/mpeg",
    woff="font/woff", woff2="font/woff2",
}

local function mime_of(filename)
    local ext = (filename or ""):match("%.([^./]+)$") or ""
    return mime_map[ext:lower()] or "application/octet-stream"
end

local function html_escape(s)
    return (tostring(s or "")):gsub("[&<>\"']", {
        ["&"]="&amp;", ["<"]="&lt;", [">"]="&gt;", ['"']="&quot;", ["'"]="&#39;",
    })
end

local function human_size(n)
    n = n or 0
    if n < 1024 then return n.." B"
    elseif n < 1048576 then return string.format("%.1f KB", n/1024)
    else return string.format("%.1f MB", n/1048576) end
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

-- ──────────────────────────────────────────────────────────
-- ZIP helpers
-- ──────────────────────────────────────────────────────────

-- Collect all entries from zip into a flat list using luazip iterator API
-- Each entry: {name=string, size=int, is_dir=bool}
local function collect_entries(zip_handle)
    local entries = {}
    for e in zip_handle:files() do
        local name = e.filename or ""
        entries[#entries+1] = {
            name    = name,
            size    = e.uncompressed_size or 0,
            is_dir  = name:sub(-1) == "/"
        }
    end
    return entries
end

-- List direct children of a directory prefix inside a ZIP
-- prefix: "" for root, "subdir/" for subdirectory
-- Returns: dirs[], files[] (each with .name, .size)
local function list_dir(entries, prefix)
    local dirs, files, seen = {}, {}, {}
    for _, e in ipairs(entries) do
        local name = e.name
        -- must start with prefix
        if name:sub(1, #prefix) == prefix then
            local rel = name:sub(#prefix + 1)
            if rel ~= "" then
                local slash = rel:find("/")
                if slash then
                    -- sub-directory
                    local dname = rel:sub(1, slash - 1)
                    if dname ~= "" and not seen[dname] then
                        seen[dname] = true
                        dirs[#dirs+1] = dname
                    end
                else
                    -- direct file
                    files[#files+1] = {name=rel, size=e.size}
                end
            end
        end
    end
    table.sort(dirs)
    table.sort(files, function(a,b) return a.name < b.name end)
    return dirs, files
end

-- ──────────────────────────────────────────────────────────
-- Parse URI: /<prefix>/<zip_rel>/<inner>   (prefix may be "" or "/zip")
-- Supports any configured zip-like extension (zip, cbz, …)
-- ──────────────────────────────────────────────────────────
-- Strip a leading prefix (may be "" meaning no prefix) and parse zip boundary.
-- Returns zip_rel, inner  or nil, nil
local function parse_zip_uri_with_prefix(uri, prefix)
    local rest
    if prefix == "" then
        rest = uri:gsub("^/+", "")
    else
        rest = uri:match("^" .. prefix .. "/(.*)$")
    end
    if not rest then return nil, nil end
    local zip_end = find_zip_ext(rest)
    if not zip_end then return nil, nil end
    local zip_rel = rest:sub(1, zip_end)
    local inner   = rest:sub(zip_end + 1):gsub("^/+", "")
    return zip_rel, inner
end

-- ──────────────────────────────────────────────────────────
-- Parse URI: /zip/<zip_rel>/<inner>
-- Supports any configured zip-like extension (zip, cbz, …)
-- ──────────────────────────────────────────────────────────
local function parse_zip_uri(uri)
    return parse_zip_uri_with_prefix(uri, "/zip")
end

-- ──────────────────────────────────────────────────────────
-- HTML directory listing
-- url_prefix: "/zip" for the /zip/ handler, "" for transparent mode
-- ──────────────────────────────────────────────────────────
local function render_listing(zip_rel, inner, entries, url_prefix)
    url_prefix = url_prefix or "/zip"
    local prefix = (inner == "" and "" or (inner:gsub("/*$", "") .. "/"))
    local dirs, files = list_dir(entries, prefix)
    local title = "/" .. zip_rel .. "/" .. inner

    local h = {
        '<!DOCTYPE html><html><head><meta charset="utf-8">',
        '<title>' .. html_escape(title) .. '</title>',
        '<style>',
        'body{font-family:monospace;padding:20px;background:#1e1e1e;color:#d4d4d4;max-width:900px}',
        'h1{font-size:1.1em;color:#569cd6;word-break:break-all}',
        'table{border-collapse:collapse;width:100%}',
        'tr:hover td{background:#2a2a2a}',
        'td,th{padding:5px 14px;text-align:left;border-bottom:1px solid #333}',
        'th{color:#9cdcfe;background:#252526}',
        'a{color:#4ec9b0;text-decoration:none}a:hover{text-decoration:underline}',
        '.dir{color:#dcdcaa}.sz{text-align:right;color:#808080;width:80px}',
        '</style></head><body>',
        '<h1>&#128230;&nbsp;' .. html_escape(title) .. '</h1>',
        '<table><tr><th>Name</th><th class="sz">Size</th></tr>',
    }

    -- Parent link
    if inner ~= "" then
        local stripped = inner:gsub("/*$", "")
        local parent = stripped:match("^(.*)/[^/]+$") or ""
        local parent_url = url_prefix .. "/" .. zip_rel .. (parent ~= "" and ("/" .. parent .. "/") or "/")
        h[#h+1] = '<tr><td><a href="' .. html_escape(parent_url) .. '">&#8593; ..</a></td><td class="sz">—</td></tr>'
    end

    for _, d in ipairs(dirs) do
        local href = url_prefix .. "/" .. zip_rel .. "/" .. prefix .. d .. "/"
        h[#h+1] = '<tr><td class="dir"><a href="' .. html_escape(href) .. '">&#128193;&nbsp;' .. html_escape(d) .. '/</a></td><td class="sz">—</td></tr>'
    end
    for _, f in ipairs(files) do
        local href = url_prefix .. "/" .. zip_rel .. "/" .. prefix .. f.name
        h[#h+1] = '<tr><td><a href="' .. html_escape(href) .. '">' .. html_escape(f.name) .. '</a></td>'
        h[#h+1] = '<td class="sz">' .. human_size(f.size) .. '</td></tr>'
    end

    h[#h+1] = '</table></body></html>'
    return table.concat(h, "\n")
end

-- ──────────────────────────────────────────────────────────
-- Image processing helpers (for ZIP cover thumbnails)
-- ──────────────────────────────────────────────────────────

-- Check if a filename is an image
local function is_image(filename)
    local ext = (filename or ""):match("%.([^./]+)$") or ""
    ext = ext:lower()
    return mime_map[ext] and mime_map[ext]:sub(1, 6) == "image/"
end

-- RAM Disk Bridge config (same as imgapi.lua)
-- yot writes to /mnt/ramdisk/.imgapi-tmp/ (shared named tmpfs volume)
-- imgproxy reads from /mnt/ramdisk/ (same volume mounted)
-- imgproxy LOCAL_FILESYSTEM_ROOT=/, so local:///mnt/ramdisk/.imgapi-tmp/file → /mnt/ramdisk/.imgapi-tmp/file

-- imgproxy upstream config (supports multiple servers)
local function parse_upstream()
    local upstream_str = os.getenv("IMGPROXY_UPSTREAM")
    if not upstream_str or upstream_str == "" then
        local host = os.getenv("IMGPROXY_HOST") or "imgproxy"
        local port = os.getenv("IMGPROXY_PORT") or "8080"
        return {{host = host, port = tonumber(port)}}
    end

    local servers = {}
    for server in upstream_str:gmatch("[^,]+") do
        server = server:gsub("%s+", "")
        local host, port = server:match("([^:]+):(%d+)")
        if host and port then
            table.insert(servers, {host = host, port = tonumber(port)})
        else
            table.insert(servers, {host = server, port = 8080})
        end
    end

    if #servers == 0 then
        local host = os.getenv("IMGPROXY_HOST") or "imgproxy"
        local port = os.getenv("IMGPROXY_PORT") or "8080"
        return {{host = host, port = tonumber(port)}}
    end
    return servers
end

local server_pool = nil
local pool_index = 0

local function get_next_server()
    if not server_pool then
        server_pool = parse_upstream()
        pool_index = 0
    end
    pool_index = (pool_index % #server_pool) + 1
    return server_pool[pool_index]
end

local TMP_DIR         = "/mnt/ramdisk/.imgapi-tmp"
local TMP_REL_DIR     = "mnt/ramdisk/.imgapi-tmp"  -- no leading / for imgproxy local:// URL

-- Ensure tmp directory exists with correct permissions
os.execute("mkdir -p " .. TMP_DIR .. " && chmod 1777 " .. TMP_DIR)

-- Save image data to temp file, return absolute path and relative path for imgproxy
local function save_to_temp_file(img_data, ext)
    os.execute("mkdir -p " .. TMP_DIR .. " && chmod 1777 " .. TMP_DIR)
    local unique_id = ngx.now() * 1000 + math.random(1000)
    local filename = string.format("%d.%s", unique_id, ext or "jpg")
    local abs_path = TMP_DIR .. "/" .. filename
    local f, err = io.open(abs_path, "wb")
    if not f then
        return nil, nil, "failed to open temp file: " .. tostring(err)
    end
    local ok, werr = f:write(img_data)
    f:close()
    if not ok then
        return nil, nil, "failed to write temp file: " .. tostring(werr)
    end
    -- abs_path: /mnt/ramdisk/.imgapi-tmp/xxx.jpg (for cleanup)
    -- rel_path: mnt/ramdisk/.imgapi-tmp/xxx.jpg (for imgproxy local:// URL)
    local rel_path = TMP_REL_DIR .. "/" .. filename
    return abs_path, rel_path
end

-- Process image via imgproxy using RAM Disk Bridge
-- 1. Write image data to tmpfs (ramdisk)
-- 2. Call imgproxy with local:// URL to read from ramdisk
-- 3. Return result and cleanup temp file
-- Returns: result {body, headers}, err, status
local function process_image_via_api(img_data, opts, ext)
    local http = require("resty.http")

    -- Normalize extension
    ext = ext or "jpg"
    if ext == "jpeg" then ext = "jpg" end

    -- Save to temp file
    local abs_path, rel_path, err = save_to_temp_file(img_data, ext)
    if not abs_path then
        return nil, "failed to save temp file: " .. err, 500
    end

    -- Build processing string
    local parts = {}
    if opts.w and opts.w > 0 then
        table.insert(parts, "width:" .. tostring(opts.w))
    end
    if opts.h and opts.h > 0 then
        table.insert(parts, "height:" .. tostring(opts.h))
    end
    if opts.fit == "cover" then
        table.insert(parts, "resizing_type:fill")
    elseif opts.fit == "fill" then
        -- imgproxy doesn't support stretch, use default
    end
    if opts.fmt and opts.fmt ~= "" then
        local fmt = opts.fmt
        if fmt == "jpeg" then fmt = "jpg" end
        table.insert(parts, "format:" .. fmt)
    end
    if opts.q and opts.q > 0 then
        table.insert(parts, "quality:" .. tostring(opts.q))
    end
    local processing = table.concat(parts, "/")

    -- Build imgproxy URL with local:// scheme pointing to ramdisk
    -- imgproxy LOCAL_FILESYSTEM_ROOT=/, so local:///mnt/ramdisk/.imgapi-tmp/file → /mnt/ramdisk/.imgapi-tmp/file
    local imgproxy_path = "/insecure/" .. processing .. "/plain/local:///" .. rel_path

    local httpc = http.new()
    httpc:set_timeout(30000)

    local server = get_next_server()
    local ok, conn_err = httpc:connect(server.host, server.port)
    if not ok then
        os.remove(abs_path)
        return nil, "failed to connect to imgproxy: " .. tostring(conn_err), 502
    end

    local proxy_res, perr = httpc:request({
        method = "GET",
        path = imgproxy_path,
        headers = {
            ["Host"] = "localhost",
        }
    })

    if not proxy_res then
        httpc:close()
        os.remove(abs_path)
        return nil, "imgproxy request failed: " .. tostring(perr), 502
    end

    local res_body, rerr = proxy_res:read_body()
    if not res_body then
        httpc:close()
        os.remove(abs_path)
        return nil, "failed to read imgproxy response: " .. tostring(rerr), 502
    end

    httpc:set_keepalive(10000, 64)

    -- Cleanup temp file
    os.remove(abs_path)

    if proxy_res.status ~= 200 then
        return nil, "imgproxy returned " .. proxy_res.status, proxy_res.status
    end

    return {
        body = res_body,
        headers = proxy_res.headers,
    }, nil, 200
end

-- ──────────────────────────────────────────────────────────
-- Shared serve logic: given zip_rel + inner, serve listing or file content.
-- url_prefix is used to generate directory-listing links.
-- ──────────────────────────────────────────────────────────
local function serve_zip(webdav_root, zip_rel, inner, url_prefix)
    local zip_path = webdav_root .. "/" .. zip_rel
    if not file_exists(zip_path) then
        ngx.log(ngx.WARN, "[zipfs] zip not found: ", zip_path)
        return ngx.exit(ngx.HTTP_NOT_FOUND)
    end

    local ok, zf = pcall(require("zip").open, zip_path)
    if not ok or not zf then
        ngx.log(ngx.ERR, "[zipfs] cannot open: ", zip_path, " err=", tostring(zf))
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local entries = collect_entries(zf)

    -- Directory listing
    local is_dir = (inner == "" or inner:sub(-1) == "/")
    if is_dir then
        local body = render_listing(zip_rel, inner:gsub("/*$",""), entries, url_prefix)
        zf:close()
        ngx.header["Content-Type"] = "text/html; charset=utf-8"
        ngx.header["X-ZipFS"] = "dir-listing"
        return ngx.print(body)
    end

    -- File read
    local ok2, fe = pcall(function() return zf:open(inner) end)
    if not ok2 or not fe then
        zf:close()
        ngx.log(ngx.WARN, "[zipfs] entry not found: '", inner, "' in ", zip_path)
        return ngx.exit(ngx.HTTP_NOT_FOUND)
    end

    local data = fe:read("*a")
    fe:close()
    zf:close()

    if not data then return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR) end

    -- Check if image processing is requested
    local args = ngx.req.get_uri_args()
    local needs_processing = args.w or args.h or args.fit or args.fmt or args.q

    if is_image(inner) and needs_processing then
        -- Extract extension from inner filename for temp file naming
        local ext = inner:match("%.([^./]+)$") or "jpg"
        -- Process image via imgproxy (RAM Disk Bridge)
        local result, err, status = process_image_via_api(data, {
            w = tonumber(args.w) or 0,
            h = tonumber(args.h) or 0,
            fit = args.fit or "contain",
            fmt = args.fmt or "",
            q = tonumber(args.q) or 82
        }, ext)

        if result then
            ngx.header["Content-Type"] = result.headers["Content-Type"] or "application/octet-stream"
            ngx.header["Content-Length"] = #result.body
            ngx.header["X-ZipFS"] = "processed"
            ngx.header["Cache-Control"] = "public, max-age=3600"
            return ngx.print(result.body)
        else
            ngx.log(ngx.WARN, "[zipfs] image processing failed: ", err, ", serving original")
            -- Fall through to serve original
        end
    end

    ngx.header["Content-Type"]   = mime_of(inner)
    ngx.header["Content-Length"] = #data
    ngx.header["X-ZipFS"]        = "file"
    ngx.header["Cache-Control"]  = "public, max-age=3600"
    return ngx.print(data)
end

-- ──────────────────────────────────────────────────────────
-- Main HTTP handler  (location /zip/)
-- ──────────────────────────────────────────────────────────
function _M.handle(webdav_root)
    local uri = ngx.var.uri

    local zip_rel, inner = parse_zip_uri(uri)
    if not zip_rel then return ngx.exit(ngx.HTTP_NOT_FOUND) end

    return serve_zip(webdav_root, zip_rel, inner, "/zip")
end

-- ──────────────────────────────────────────────────────────
-- Transparent GET/HEAD handler — called from rewrite_by_lua_block
-- when OR_ZIPFS_TRANSPARENT is enabled.
-- Serves ZIP content directly at the original URL (no redirect).
-- Directory listing links will also use the same root URL prefix.
-- Returns true if the request was handled, false otherwise.
--
-- IMPORTANT: When inner == "" the request is for the ZIP file itself
-- (e.g. WebDAV client downloading /archive.zip). In that case we do NOT
-- intercept — let nginx serve the raw ZIP bytes normally.
-- ──────────────────────────────────────────────────────────
function _M.handle_transparent(webdav_root)
    local uri = ngx.var.uri

    -- Parse the URI without any /zip/ prefix
    local zip_rel, inner = parse_zip_uri_with_prefix(uri, "")
    if not zip_rel then return false end

    -- inner == "" means the client is requesting the ZIP file itself
    -- (e.g. a WebDAV client doing GET /path/to/archive.zip).
    -- Do NOT intercept: fall through to the normal nginx static file handler
    -- so the raw ZIP binary is served (not an HTML directory listing).
    if inner == "" then return false end

    -- inner != "" → access to a path inside the archive; handle transparently.
    -- Derive url_prefix: the part of the URI before the zip filename
    -- e.g. uri = "/archives/book.cbz/ch1"  → zip_rel = "archives/book.cbz"
    -- We want directory links to be like "/archives/book.cbz/subdir/"
    -- so url_prefix is just "" and hrefs start with "/".
    serve_zip(webdav_root, zip_rel, inner, "")
    return true
end

-- ──────────────────────────────────────────────────────────
-- WebDAV PROPFIND handler
-- Called from main.conf rewrite_by_lua_block for *.zip URIs
-- ──────────────────────────────────────────────────────────
function _M.webdav_propfind(webdav_root, uri, depth)
    depth = depth or "1"
    local rel = uri:gsub("^/+", "")

    local zip_end = find_zip_ext(rel)
    if not zip_end then return nil end

    local zip_rel = rel:sub(1, zip_end)
    local inner   = rel:sub(zip_end + 1):gsub("^/+", "")

    local zip_path = webdav_root .. "/" .. zip_rel
    if not file_exists(zip_path) then return nil end

    local ok, zf = pcall(require("zip").open, zip_path)
    if not ok or not zf then return nil end

    local entries = collect_entries(zf)
    zf:close()

    local base_href = "/" .. zip_rel
    local xml = { '<?xml version="1.0" encoding="utf-8"?>', '<D:multistatus xmlns:D="DAV:">' }

    local function add_prop(href, is_coll, size, name)
        xml[#xml+1] = '<D:response><D:href>' .. html_escape(href) .. '</D:href>'
        xml[#xml+1] = '<D:propstat><D:prop>'
        if is_coll then
            xml[#xml+1] = '<D:resourcetype><D:collection/></D:resourcetype>'
        else
            xml[#xml+1] = '<D:resourcetype/>'
            xml[#xml+1] = '<D:getcontentlength>' .. (size or 0) .. '</D:getcontentlength>'
            xml[#xml+1] = '<D:getcontenttype>' .. mime_of(name or "") .. '</D:getcontenttype>'
        end
        xml[#xml+1] = '<D:displayname>' .. html_escape(name or "") .. '</D:displayname>'
        xml[#xml+1] = '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>'
    end

    -- Self entry
    local self_name = zip_rel:match("[^/]+$") or zip_rel
    add_prop(base_href .. (inner ~= "" and ("/" .. inner) or ""), true, 0, self_name)

    if depth ~= "0" then
        local prefix = (inner == "" and "" or (inner:gsub("/*$","") .. "/"))
        local dirs, files = list_dir(entries, prefix)
        for _, d in ipairs(dirs) do
            add_prop(base_href .. "/" .. prefix .. d .. "/", true, 0, d)
        end
        for _, f in ipairs(files) do
            add_prop(base_href .. "/" .. prefix .. f.name, false, f.size, f.name)
        end
    end

    xml[#xml+1] = '</D:multistatus>'
    return table.concat(xml, "\n")
end

-- ──────────────────────────────────────────────────────────
-- Check if a URI points into a ZIP-like file
-- Matches any extension in OR_ZIP_EXTS (default: zip, cbz)
-- ──────────────────────────────────────────────────────────
function _M.is_zip_request(uri)
    return find_zip_ext(uri or "") ~= nil
end

-- ──────────────────────────────────────────────────────────
-- Return the end-index (1-based, inclusive) of the zip extension
-- boundary in the URI, or nil if no zip extension found.
-- Used by callers that need to split URI into zip_rel + inner.
-- e.g. "/foo/bar.zip/ch1" → 12  (end of ".zip")
-- ──────────────────────────────────────────────────────────
function _M.find_zip_boundary(uri)
    return find_zip_ext(uri or "")
end

-- ──────────────────────────────────────────────────────────
-- Transparent WebDAV/ZIP interception switch
-- Controlled by OR_ZIPFS_TRANSPARENT env var (default: true)
-- Set OR_ZIPFS_TRANSPARENT=false to disable the WebDAV interception
-- and let .zip/.cbz paths fall through to the normal WebDAV handler.
-- /zip/ HTTP access is NOT affected by this flag.
-- ──────────────────────────────────────────────────────────
local _transparent_enabled  -- nil = not yet loaded

function _M.is_transparent_enabled()
    if _transparent_enabled ~= nil then return _transparent_enabled end
    local ok, env = pcall(require, "env")
    if ok and env and env.OR_ZIPFS_TRANSPARENT == false then
        _transparent_enabled = false
    else
        -- default ON; accept "false" string from entrypoint.sh boolean conversion
        local raw = ok and env and env.OR_ZIPFS_TRANSPARENT
        if raw == "false" then
            _transparent_enabled = false
        else
            _transparent_enabled = true
        end
    end
    return _transparent_enabled
end

return _M
