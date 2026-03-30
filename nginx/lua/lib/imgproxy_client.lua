-- lib/imgproxy_client.lua
-- Direct HTTP client for imgproxy using Lua cosocket
-- Bypasses nginx's proxy_pass URL parsing issues with imgproxy's local:// URL scheme
--
-- Supports multiple upstream servers via OR_IMGPROXY_UPSTREAM env var:
--   OR_IMGPROXY_UPSTREAM=imgproxy1:8080,imgproxy2:8080,imgproxy3:8080
--   If not set, uses default imgproxy:8080 (single server)
-- Uses round-robin load balancing across upstream servers.

local _M = {}

local imgproxy = require("lib.imgproxy")

-- Internal auth header for imgproxy → yot requests
-- This header allows imgproxy to bypass yot's IP whitelist
local INTERNAL_AUTH_HEADER = os.getenv("OR_INTERNAL_AUTH_HEADER") or ""

-- ── Public API ───────────────────────────────────────────────────────────────

-- Process image from HTTP URL via imgproxy
-- full_url: the complete HTTP URL to fetch the source image from
-- e.g., "http://yot:5080/zip/archives/book.cbz/images/cover.jpg?w=360&h=504&fit=cover&q=82"
-- params: {w, h, fit, fmt, q}
function _M.process_http(full_url, params)
    local w = params.w
    local h = params.h
    local fit = params.fit or "contain"
    local fmt = params.fmt or ""
    local q = params.q or 82

    -- Build processing string
    local processing = imgproxy.build_processing(w, h, fit, fmt, q)

    -- Strip query parameters from full_url before passing to imgproxy
    -- imgproxy will read the raw file; all processing is done via the processing string
    -- If we pass query params, serve_zip will double-process the image (bad!)
    local source_url = full_url:gsub("%?.*$", "")

    -- Build imgproxy URL with HTTP source (no query params in source URL)
    -- imgproxy_path: /insecure/<processing>/plain/http://<source_url>
    local imgproxy_path = imgproxy.build_http_url(source_url, processing)

    -- Add internal auth header if configured (allows bypassing yot's IP whitelist)
    local extra_headers = nil
    if INTERNAL_AUTH_HEADER ~= "" then
        extra_headers = {["X-Internal-Auth"] = INTERNAL_AUTH_HEADER}
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
    if INTERNAL_AUTH_HEADER ~= "" then
        extra_headers = {["X-Internal-Auth"] = INTERNAL_AUTH_HEADER}
    end
    return imgproxy.process_local(webdav_root, rel_path, params, use_webdav, extra_headers)
end

return _M