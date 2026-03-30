-- lib/imgproxy.lua
-- Shared imgproxy client library
--
-- Provides:
--   - Upstream server pool with round-robin load balancing
--   - imgproxy URL building and processing string generation
--   - Common HTTP request function for imgproxy
--
-- Usage:
--   local imgproxy = require("lib.imgproxy")

local _M = {}

local http = require("resty.http")

-- ─────────────────────────────────────────────────────────────────────────────
-- Upstream Server Pool
-- ─────────────────────────────────────────────────────────────────────────────

-- Parse OR_IMGPROXY_UPSTREAM env var (comma-separated list of host:port)
-- Returns: array of {host, port} tables
-- If OR_IMGPROXY_UPSTREAM is not set, uses default imgproxy:8080
local function parse_upstream()
    local ok, env = pcall(require, "env")
    env = (ok and env) or {}
    local upstream_str = env.OR_IMGPROXY_UPSTREAM or ""

    -- Default: single server using Docker Compose service name
    if not upstream_str or upstream_str == "" then
        return {{host = "imgproxy", port = 8080}}
    end

    local servers = {}
    for server in upstream_str:gmatch("[^,]+") do
        server = server:gsub("%s+", "")  -- trim whitespace
        local host, port = server:match("([^:]+):(%d+)")
        if host and port then
            table.insert(servers, {host = host, port = tonumber(port)})
        else
            -- No port specified, use default
            table.insert(servers, {host = server, port = 8080})
        end
    end

    if #servers == 0 then
        return {{host = "imgproxy", port = 8080}}
    end

    return servers
end

-- Server pool (initialized lazily)
local server_pool = nil
local pool_index = 0  -- round-robin counter

-- Get next server from pool (round-robin)
local function get_next_server()
    if not server_pool then
        server_pool = parse_upstream()
        pool_index = 0
    end

    pool_index = (pool_index % #server_pool) + 1
    return server_pool[pool_index]
end

-- Expose for direct access if needed
_M.get_next_server = get_next_server

-- ─────────────────────────────────────────────────────────────────────────────
-- Processing String Builder
-- ─────────────────────────────────────────────────────────────────────────────

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

_M.map_resizing_type = map_resizing_type

-- Build the imgproxy processing string
-- w, h: target dimensions
-- fit: resize mode (contain, cover, fill, scale)
-- fmt: output format (jpeg, webp, png, avif, gif)
-- q: quality 1-100
function _M.build_processing(w, h, fit, fmt, q)
    local parts = {}

    if w and w > 0 then
        table.insert(parts, "width:" .. tostring(w))
    end
    if h and h > 0 then
        table.insert(parts, "height:" .. tostring(h))
    end

    local resizing_type = map_resizing_type(fit)
    if resizing_type then
        table.insert(parts, "resizing_type:" .. resizing_type)
    end

    if fmt and fmt ~= "" then
        -- Normalize jpeg -> jpg for imgproxy
        if fmt == "jpeg" then fmt = "jpg" end
        table.insert(parts, "format:" .. fmt)
    end

    if q and q > 0 then
        table.insert(parts, "quality:" .. tostring(q))
    end

    return table.concat(parts, "/")
end

-- Build imgproxy local:// URL for a file path
-- rel_path: path relative to imgproxy's LOCAL_FILESYSTEM_ROOT (e.g. "data/images/photo.jpg")
-- processing: processing string from build_processing()
function _M.build_local_url(rel_path, processing)
    -- URL-encode the path for imgproxy's local:// URL scheme
    -- Each path segment is encoded individually to preserve slashes
    local encoded_path = {}
    for segment in rel_path:gmatch("([^/]+)") do
        table.insert(encoded_path, ngx.escape_uri(segment))
    end
    local encoded_full = table.concat(encoded_path, "/")
    -- Use triple-slash local:/// to avoid hostname parsing bug
    return "/insecure/" .. processing .. "/plain/local:///" .. encoded_full
end

-- Build imgproxy HTTP source URL
-- source_url: full HTTP URL to the source image
-- processing: processing string from build_processing()
function _M.build_http_url(source_url, processing)
    -- Percent-encode the source URL to prevent imgproxy from misinterpreting
    -- encoded path segments (e.g. %E4BC9A → é) as escape sequences.
    -- Each % in %XX must be escaped as %25.
    local encoded_source = source_url:gsub("%%", "%%25")
    ngx.log(ngx.INFO, "[imgproxy] build_http_url: original_source=", source_url,
            " encoded_source=", encoded_source)
    return "/insecure/" .. processing .. "/plain/" .. encoded_source
end

-- Build imgproxy webdav:// URL
-- webdav_rel: path relative to webdav root (e.g. "archives/book.cbz/cover.jpg")
-- processing: processing string from build_processing()
function _M.build_webdav_url(webdav_rel, processing)
    return "/insecure/" .. processing .. "/plain/webdav:/" .. webdav_rel
end

-- ─────────────────────────────────────────────────────────────────────────────
-- HTTP Request Helper
-- ─────────────────────────────────────────────────────────────────────────────

-- Make HTTP request to imgproxy and return response
-- imgproxy_path: the path portion of the imgproxy URL (e.g. "/insecure/w:200/plain/local:///...")
-- timeout_ms: request timeout in milliseconds (default 30000)
-- extra_headers: optional table of additional headers to include
-- Returns: result {status, headers, body} or nil, error, status
function _M.request(imgproxy_path, timeout_ms, extra_headers)
    timeout_ms = timeout_ms or 30000

    -- Get server (only once to avoid pool index issues)
    local server = get_next_server()

    -- DEBUG: log exact request details including raw OR_IMGPROXY_UPSTREAM env var
    local ok_env, env = pcall(require, "env")
    local env_upstream = (ok_env and env and env.OR_IMGPROXY_UPSTREAM) or "nil"
    ngx.log(ngx.INFO, "[imgproxy] OR_IMGPROXY_UPSTREAM=", env_upstream,
            " using server=", server.host, ":", server.port,
            " imgproxy_path=", imgproxy_path,
            " extra_headers=", extra_headers and "yes" or "no")

    local httpc = http.new()
    httpc:set_timeout(timeout_ms)

    local ok, err = httpc:connect(server.host, server.port)
    if not ok then
        return nil, "failed to connect to imgproxy: " .. err
    end

    local headers = {
        ["Host"] = "localhost",
    }
    -- Merge extra headers
    if extra_headers then
        for k, v in pairs(extra_headers) do
            headers[k] = v
        end
    end

    local res, err = httpc:request({
        method = "GET",
        path = imgproxy_path,
        headers = headers
    })

    if not res then
        httpc:close()
        return nil, "imgproxy request failed: " .. err
    end

    local body, err = res:read_body()
    if not body then
        httpc:close()
        return nil, "failed to read imgproxy response: " .. err
    end

    httpc:set_keepalive(10000, 64)

    local status = res.status
    local headers = res.headers

    if status ~= 200 then
        local err_msg = body or "imgproxy returned status " .. status
        ngx.log(ngx.WARN, "[imgproxy] error: ", err_msg)
        return nil, err_msg, status
    end

    return {
        status = status,
        headers = headers,
        body = body
    }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Content-type Detection (for files with wrong extensions like .jfif that are actually WebP)
-- ─────────────────────────────────────────────────────────────────────────────

-- Detect actual image format from file content (first 12 bytes)
-- Returns: "webp", "jpeg", "png", "gif", or nil
function _M.detect_content_type(file_path)
    local f, err = io.open(file_path, "rb")
    if not f then return nil end
    local data = f:read(12)
    f:close()
    if not data or #data < 12 then return nil end
    -- PNG: 89 50 4E 47
    if data:byte(1) == 0x89 and data:sub(2, 5) == "PNG" then return "png" end
    -- JPEG: FF D8 FF
    if data:byte(1) == 0xFF and data:byte(2) == 0xD8 and data:byte(3) == 0xFF then return "jpeg" end
    -- GIF87a
    if data:sub(1, 6) == "GIF87a" then return "gif" end
    -- GIF89a
    if data:sub(1, 6) == "GIF89a" then return "gif" end
    -- RIFF....WEBP (both lossless and lossy WebP)
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return "webp" end
    return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Convenience wrappers for common patterns
-- ─────────────────────────────────────────────────────────────────────────────

-- Process image from local path via imgproxy
-- webdav_root: the webdav root directory (e.g. "/webdav" → maps to /data)
-- rel_path: path relative to webdav_root (e.g. "images/photo.jpg")
-- params: {w, h, fit, fmt, q}
-- use_webdav: if true, use webdav:// URL instead of local:// (for zip/cbz access)
-- extra_headers: optional table of additional headers
function _M.process_local(webdav_root, rel_path, params, use_webdav, extra_headers)
    local w = params.w
    local h = params.h
    local fit = params.fit or "contain"
    local fmt = params.fmt or ""
    local q = params.q or 82

    -- DEBUG: log the incoming path
    ngx.log(ngx.DEBUG, "[imgproxy] process_local: rel_path=", rel_path, " webdav_root=", webdav_root or "nil")

    local processing = _M.build_processing(w, h, fit, fmt, q)
    local imgproxy_path

    if use_webdav then
        imgproxy_path = _M.build_webdav_url(rel_path, processing)
    else
        -- Build imgproxy URL using local:// scheme
        -- imgproxy LOCAL_FILESYSTEM_ROOT=/, so:
        --   webdav_root="/webdav" → maps to /data in imgproxy container
        --   rel_path="images/photo.jpg" → full path = "data/images/photo.jpg"
        local full_rel
        if webdav_root and webdav_root ~= "" then
            full_rel = "data/" .. rel_path
        else
            full_rel = rel_path
        end

        -- Decode URL-encoded characters for filesystem access
        -- rel_path from nginx URI contains encoded chars (e.g. %20 for space)
        -- but filesystem paths use actual characters, so we need to decode first
        local full_rel_decoded = ngx.unescape_uri(full_rel)

        -- DEBUG: log full path before content detection
        ngx.log(ngx.DEBUG, "[imgproxy] full_rel (before detection)=", full_rel, " (decoded)=", full_rel_decoded)

        -- Detect actual content type to handle files with wrong extensions (e.g., .jfif that's actually WebP)
        -- imgproxy uses the file extension to determine how to DECODE the source image,
        -- so .jfif containing WebP data would fail. Fix by using .webp extension when content is WebP.
        local detected = _M.detect_content_type(full_rel_decoded)
        if detected == "webp" then
            -- Replace extension with .webp so imgproxy decodes it correctly
            full_rel_decoded = full_rel_decoded:gsub("%.[^.]+$", ".webp")
        elseif detected == "jpeg" then
            full_rel_decoded = full_rel_decoded:gsub("%.[^.]+$", ".jpg")
        end

        ngx.log(ngx.DEBUG, "[imgproxy] full_rel (after detection)=", full_rel_decoded, " imgproxy_path=", _M.build_local_url(full_rel_decoded, processing))

        imgproxy_path = _M.build_local_url(full_rel_decoded, processing)
    end

    return _M.request(imgproxy_path, nil, extra_headers)
end

-- Process image from HTTP URL via imgproxy
-- full_url: the complete HTTP URL to fetch the source image from
-- e.g., "http://yot:5080/zip/archives/book.cbz/images/cover.jpg"
-- params: {w, h, fit, fmt, q}
-- extra_headers: optional table of additional headers
function _M.process_http(full_url, params, extra_headers)
    local w = params.w
    local h = params.h
    local fit = params.fit or "contain"
    local fmt = params.fmt or ""
    local q = params.q or 82

    local processing = _M.build_processing(w, h, fit, fmt, q)

    -- Strip query parameters from full_url before passing to imgproxy
    -- imgproxy will read the raw file; all processing is done via the processing string
    local source_url = full_url:gsub("%?.*$", "")

    local imgproxy_path = _M.build_http_url(source_url, processing)
    return _M.request(imgproxy_path, nil, extra_headers)
end

return _M