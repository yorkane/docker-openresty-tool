-- lib/imgproxy_client.lua
-- Direct HTTP client for imgproxy using Lua cosocket
-- Bypasses nginx's proxy_pass URL parsing issues with imgproxy's local:// URL scheme
--
-- Supports multiple upstream servers via IMGPROXY_UPSTREAM env var:
--   IMGPROXY_UPSTREAM=imgproxy1:8080,imgproxy2:8080,imgproxy3:8080
--   If not set, falls back to IMGPROXY_HOST:IMGPROXY_PORT (single server)
-- Uses round-robin load balancing across upstream servers.

local _M = {}

local http = require("resty.http")

-- ── Upstream Server Pool ─────────────────────────────────────────────────────

-- Parse IMGPROXY_UPSTREAM env var (comma-separated list of host:port)
-- Returns: array of {host, port} tables
local function parse_upstream()
    local upstream_str = os.getenv("IMGPROXY_UPSTREAM")
    if not upstream_str or upstream_str == "" then
        -- Fallback to single server mode
        local host = os.getenv("IMGPROXY_HOST") or "imgproxy"
        local port = os.getenv("IMGPROXY_PORT") or "8080"
        return {{host = host, port = tonumber(port)}}
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
        local host = os.getenv("IMGPROXY_HOST") or "imgproxy"
        local port = os.getenv("IMGPROXY_PORT") or "8080"
        return {{host = host, port = tonumber(port)}}
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

-- Build the imgproxy processing string
local function build_processing(w, h, fit, fmt, q)
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
        table.insert(parts, "format:" .. fmt)
    end

    if q and q > 0 then
        table.insert(parts, "quality:" .. tostring(q))
    end

    return table.concat(parts, "/")
end

-- Process image from HTTP URL via imgproxy
-- full_url: the complete HTTP URL to fetch the source image from
-- e.g., "http://yot:5080/zip/archives/book.cbz/images/cover.jpg?w=360&h=504&fit=cover&q=82"
function _M.process_http(full_url, params)
    local w = params.w
    local h = params.h
    local fit = params.fit or "contain"
    local fmt = params.fmt or ""
    local q = params.q or 82

    -- Build processing string
    local processing = build_processing(w, h, fit, fmt, q)

    -- Get next server from upstream pool (round-robin)
    local server = get_next_server()

    -- Strip query parameters from full_url before passing to imgproxy
    -- imgproxy will read the raw file; all processing is done via the processing string
    -- If we pass query params, serve_zip will double-process the image (bad!)
    local source_url = full_url:gsub("%?.*$", "")

    -- Build imgproxy URL with HTTP source (no query params in source URL)
    -- imgproxy_path: /insecure/<processing>/plain/http://<source_url>
    local imgproxy_path = "/insecure/" .. processing .. "/plain/" .. source_url

    -- Make HTTP request to imgproxy
    local httpc = http.new()
    httpc:set_timeout(30000)

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
        ngx.log(ngx.WARN, "[imgproxy_client] error: ", err_msg)
        return nil, err_msg, status
    end

    return {
        status = status,
        headers = headers,
        body = body
    }
end

-- Process image from local path via imgproxy
-- webdav_root: the webdav root directory (e.g. "/webdav" → maps to /data)
-- rel_path:    path relative to webdav_root (e.g. "images/photo.jpg")
-- use_webdav: if true, use webdav:// URL instead of local:// (for zip/cbz access via zipfs)
function _M.process_local(webdav_root, rel_path, params, use_webdav)
    local w = params.w
    local h = params.h
    local fit = params.fit or "contain"
    local fmt = params.fmt or ""
    local q = params.q or 82

    -- Build processing string
    local processing = build_processing(w, h, fit, fmt, q)

    -- Get next server from upstream pool (round-robin)
    local server = get_next_server()

    -- Build imgproxy URL
    local imgproxy_path
    if use_webdav then
        -- Use webdav:// URL for zip/cbz transparent access via zipfs
        -- IMGPROXY_WEBDAV_ROOT=/webdav, so path should be relative to /webdav
        -- e.g., rel_path="archives/book.cbz/cover.jpg" → webdav:/archives/book.cbz/cover.jpg
        local webdav_rel = rel_path
        imgproxy_path = "/insecure/" .. processing .. "/plain/webdav:/" .. webdav_rel
    else
        -- Build imgproxy URL: /insecure/<processing>/plain/local:///<abs_path_no_leading_slash>
        -- imgproxy LOCAL_FILESYSTEM_ROOT=/, so we pass the full path without leading slash:
        --   webdav_root="/webdav" → maps to /data in imgproxy container
        --   rel_path="images/photo.jpg" → full path = "data/images/photo.jpg"
        -- Note: /webdav and /data both resolve to the same bind mount (./data)
        local full_rel
        if webdav_root and webdav_root ~= "" then
            -- Map /webdav → data (strip leading slash, replace with "data/")
            full_rel = "data/" .. rel_path
        else
            full_rel = rel_path
        end
        imgproxy_path = "/insecure/" .. processing .. "/plain/local:///" .. full_rel
    end

    -- Make HTTP request to imgproxy
    local httpc = http.new()
    httpc:set_timeout(30000)

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
        ngx.log(ngx.WARN, "[imgproxy_client] error: ", err_msg)
        return nil, err_msg, status
    end

    return {
        status = status,
        headers = headers,
        body = body
    }
end

return _M