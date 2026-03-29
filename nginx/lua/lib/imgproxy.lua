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

-- Parse IMGPROXY_UPSTREAM env var (comma-separated list of host:port)
-- Returns: array of {host, port} tables
-- If IMGPROXY_UPSTREAM is not set, uses default imgproxy:8080
local function parse_upstream()
    local upstream_str = os.getenv("IMGPROXY_UPSTREAM")

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
    -- Use triple-slash local:/// to avoid hostname parsing bug
    return "/insecure/" .. processing .. "/plain/local:///" .. rel_path
end

-- Build imgproxy HTTP source URL
-- source_url: full HTTP URL to the source image
-- processing: processing string from build_processing()
function _M.build_http_url(source_url, processing)
    return "/insecure/" .. processing .. "/plain/" .. source_url
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
-- Returns: result {status, headers, body} or nil, error, status
function _M.request(imgproxy_path, timeout_ms)
    timeout_ms = timeout_ms or 30000

    local httpc = http.new()
    httpc:set_timeout(timeout_ms)

    local server = get_next_server()
    local ok, err = httpc:connect(server.host, server.port)
    if not ok then
        return nil, "failed to connect to imgproxy: " .. err
    end

    local res, err = httpc:request({
        method = "GET",
        path = imgproxy_path,
        headers = {
            ["Host"] = "localhost",
        }
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
-- Convenience wrappers for common patterns
-- ─────────────────────────────────────────────────────────────────────────────

-- Process image from local path via imgproxy
-- webdav_root: the webdav root directory (e.g. "/webdav" → maps to /data)
-- rel_path: path relative to webdav_root (e.g. "images/photo.jpg")
-- params: {w, h, fit, fmt, q}
-- use_webdav: if true, use webdav:// URL instead of local:// (for zip/cbz access)
function _M.process_local(webdav_root, rel_path, params, use_webdav)
    local w = params.w
    local h = params.h
    local fit = params.fit or "contain"
    local fmt = params.fmt or ""
    local q = params.q or 82

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
        imgproxy_path = _M.build_local_url(full_rel, processing)
    end

    return _M.request(imgproxy_path)
end

-- Process image from HTTP URL via imgproxy
-- full_url: the complete HTTP URL to fetch the source image from
-- e.g., "http://yot:5080/zip/archives/book.cbz/images/cover.jpg"
-- params: {w, h, fit, fmt, q}
function _M.process_http(full_url, params)
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
    return _M.request(imgproxy_path)
end

return _M