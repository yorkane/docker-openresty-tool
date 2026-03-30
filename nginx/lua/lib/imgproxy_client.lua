-- lib/imgproxy_client.lua
-- Direct HTTP client for imgproxy using Lua cosocket
-- Bypasses nginx's proxy_pass URL parsing issues with imgproxy's local:// URL scheme
--
-- Supports multiple upstream servers via OR_IMGPROXY_UPSTREAM env var:
--   OR_IMGPROXY_UPSTREAM=imgproxy1:8080,imgproxy2:8080,imgproxy3:8080
--   If not set, uses default imgproxy:8080 (single server)
-- Uses round-robin load balancing across upstream servers.
--
-- Image source address for imgproxy requests:
--   OR_IMGPROXY_WEBDAV_ENDPOINT - internal address imgproxy uses to fetch from yot (default: http://yot:80)

local _M = {}

local imgproxy = require("lib.imgproxy")

-- Load env module for environment variables
local ok_env, env_loader = pcall(require, "env")
local env = (ok_env and env_loader) or {}

-- Internal auth header for imgproxy → yot requests
-- This header allows imgproxy to bypass yot's IP whitelist
-- Supports both X-Internal-Auth (legacy) and Authorization: Bearer token
local INTERNAL_AUTH_HEADER = env.OR_INTERNAL_AUTH_HEADER or ""  -- legacy
local INTERNAL_AUTH_BEARER = env.OR_AUTH_BEARER or ""

-- WebDAV endpoint for imgproxy to fetch images from yot
-- Default: http://yot:80 (internal Docker port)
local WEBDAV_ENDPOINT = env.OR_IMGPROXY_WEBDAV_ENDPOINT or "http://yot:80"

-- Check if using remote imgproxy (has OR_IMGPROXY_UPSTREAM with different host)
local USE_HTTP_MODE = false
local upstream = env.OR_IMGPROXY_UPSTREAM or ""
if upstream ~= "" then
    USE_HTTP_MODE = true
end

-- ── Public API ───────────────────────────────────────────────────────────────

-- Extract query parameters into a params table
-- args: ngx.req.get_uri_args() result
-- Returns: {w, h, fit, fmt, q}
local function extract_params(args)
    return {
        w = tonumber(args.w) or 0,
        h = tonumber(args.h) or 0,
        fit = args.fit or "contain",
        fmt = args.fmt or "",
        q = tonumber(args.q) or 82
    }
end

-- Send HTTP response from imgproxy result
-- result: imgproxy result table {status, headers, body}
local function send_response(result)
    ngx.status = 200
    ngx.header["Content-Type"] = result.headers["Content-Type"] or "application/octet-stream"
    ngx.header["Content-Length"] = #result.body
    ngx.header["Cache-Control"] = "public, max-age=86400"
    ngx.print(result.body)
end

-- Handle errors
local function handle_error(err, status)
    ngx.log(ngx.ERR, "[img] imgproxy error: ", err)
    ngx.status = status or 500
    ngx.print(err or "internal error")
end

-- ── Image Processing Handlers ─────────────────────────────────────────────────

-- Process image from /img/ location
-- uri_path: full URI like "/img/images/photo.jpg"
-- args: query parameters from ngx.req.get_uri_args()
-- Returns: result, err, status (sends response directly on success)
function _M.process_img(uri_path, args)
    -- Extract path from URI (strips /img/ prefix)
    local rel_path = uri_path:match("^/img/(.+)$")
    if not rel_path then
        ngx.status = 404
        ngx.print("path not found")
        return nil, "path not found", 404
    end

    -- Decode URL-encoded path for constructing HTTP URL
    local rel_path_decoded = ngx.unescape_uri(rel_path)
    local params = extract_params(args)

    -- Add internal auth header if configured
    local extra_headers = nil
    if INTERNAL_AUTH_BEARER ~= "" then
        extra_headers = {["Authorization"] = "Bearer " .. INTERNAL_AUTH_BEARER}
    end

    local result, err, status
    if USE_HTTP_MODE then
        -- Use HTTP URL mode for remote imgproxy
        -- imgproxy will fetch from yot via HTTP using OR_IMGPROXY_WEBDAV_ENDPOINT
        local source_url = WEBDAV_ENDPOINT .. "/" .. rel_path
        result, err, status = _M.process_http(source_url, params, extra_headers)
    else
        -- Use local mode for same-host imgproxy (local:// filesystem sharing)
        result, err, status = _M.process_local("/webdav", rel_path_decoded, params)
    end

    if not result then
        return nil, err, status
    end

    send_response(result)
    return result
end

-- Process image from ZIP/CBZ archive via /imgproxy/zip/ location
-- zip_rel: relative path inside ZIP, e.g. "archives/book.cbz/images/cover.jpg"
-- args: query parameters from ngx.req.get_uri_args()
-- Returns: result, err, status
function _M.process_zip(zip_rel, args)
    if not zip_rel or zip_rel == "" then
        ngx.status = 404
        ngx.print("path not found")
        return nil, "path not found", 404
    end

    -- Decode once to normalize double-encoded characters
    local zip_rel_decoded = ngx.unescape_uri(zip_rel)
    local params = extract_params(args)

    -- Build internal ZIP URL: http://yot:80/zip/<zip_rel>
    local zip_url = WEBDAV_ENDPOINT .. "/zip/" .. zip_rel_decoded

    local result, err, status = _M.process_http(zip_url, params, nil)
    if not result then
        return nil, err, status
    end

    send_response(result)
    return result
end

-- Process image from ZIP/CBZ archive via /imgproxy-zip/ location (webdav mode)
-- zip_rel: relative path inside ZIP, e.g. "archives/book.cbz/cover.jpg"
-- args: query parameters from ngx.req.get_uri_args()
-- Returns: result, err, status
function _M.process_zip_webdav(zip_rel, args)
    if not zip_rel or zip_rel == "" then
        ngx.status = 404
        ngx.print("path not found")
        return nil, "path not found", 404
    end

    local params = extract_params(args)

    -- Use process_local with webdav mode (zipfs will intercept and extract from ZIP)
    local result, err, status = _M.process_local("/webdav", zip_rel, params, true)
    if not result then
        return nil, err, status
    end

    send_response(result)
    return result
end

-- ── Core Functions ───────────────────────────────────────────────────────────

-- Process image from HTTP URL via imgproxy
-- full_url: the complete HTTP URL to fetch the source image from
-- e.g., "http://yot:5080/zip/archives/book.cbz/images/cover.jpg"
-- params: {w, h, fit, fmt, q}
-- extra_headers: optional additional headers for the request
function _M.process_http(full_url, params, extra_headers_arg)
    -- Build processing string
    local processing = imgproxy.build_processing(params.w, params.h, params.fit, params.fmt, params.q)

    -- Strip query parameters from full_url before passing to imgproxy
    -- imgproxy will read the raw file; all processing is done via the processing string
    -- If we pass query params, serve_zip will double-process the image (bad!)
    local source_url = full_url:gsub("%?.*$", "")

    -- Build imgproxy URL with HTTP source (no query params in source URL)
    -- imgproxy_path: /insecure/<processing>/plain/http://<source_url>
    local imgproxy_path = imgproxy.build_http_url(source_url, processing)

    -- Merge extra headers: module-level INTERNAL_AUTH_BEARER + caller-provided headers
    local extra_headers = nil
    if INTERNAL_AUTH_BEARER ~= "" or extra_headers_arg then
        extra_headers = {}
        if INTERNAL_AUTH_BEARER ~= "" then
            extra_headers["Authorization"] = "Bearer " .. INTERNAL_AUTH_BEARER
        end
        if extra_headers_arg then
            for k, v in pairs(extra_headers_arg) do
                extra_headers[k] = v
            end
        end
    end

    return imgproxy.request(imgproxy_path, nil, extra_headers)
end

-- Process image from local path via imgproxy
-- webdav_root: the webdav root directory (e.g. "/webdav" → maps to /data)
-- rel_path:    path relative to webdav_root (e.g. "images/photo.jpg")
-- params:      {w, h, fit, fmt, q}
-- use_webdav: if true, use webdav:// URL instead of local:// (for zip/cbz access via zipfs)
function _M.process_local(webdav_root, rel_path, params, use_webdav)
    -- Add internal auth header if configured (allows bypassing yot's IP whitelist)
    local extra_headers = nil
    if INTERNAL_AUTH_BEARER ~= "" then
        extra_headers = {["Authorization"] = "Bearer " .. INTERNAL_AUTH_BEARER}
    end
    return imgproxy.process_local(webdav_root, rel_path, params, use_webdav, extra_headers)
end

return _M