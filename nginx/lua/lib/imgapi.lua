-- lib/imgapi.lua
-- Binary image processing API — POST /api/img
-- Accepts raw image bytes in request body, forwards to imgproxy for processing.
-- Parameters are identical to /img/ (w, h, fit, crop, fmt, q, ignore_exts).
--
-- Designed for high-concurrency, high-throughput real-time processing:
--   - Reads image entirely from memory (no disk I/O for source)
--   - Forwards to imgproxy via HTTP raw upload mode
--   - imgproxy handles all image processing (resize, crop, format conversion)
--   - No caching (stateless, caller is responsible for caching)
--   - Streams output buffer directly to client
--
-- imgproxy architecture:
--   - imgproxy runs as separate Docker service (imgproxy container)
--   - yot (this service) handles HTTP caching via nginx proxy_cache
--   - imgproxy has built-in cache DISABLED for performance (yot caches instead)
--   - imgproxy reads from shared /data directory for local:// URLs
--   - For raw uploads, image is sent in request body to imgproxy
--
-- URL:
--   POST /api/img?w=200&h=150&fit=cover&fmt=webp&q=80
--   POST /api/img?crop=x,y,w,h&fmt=jpeg&q=90
--
-- Query params (same as /img/):
--   w            - target width  (pixels)
--   h            - target height (pixels)
--   fit          - resize mode: contain (default) | cover | fill | scale
--   crop         - crop before resize: "x,y,width,height"
--   fmt          - output format: jpeg | webp | png | avif | gif
--   q            - quality 1-100 (jpeg/webp/avif, default 82)
--   ignore_exts  - comma-separated extensions to skip processing (e.g. "gif,webp")
--
-- Request:
--   Method:       POST
--   Content-Type: image/* (any supported image format)
--   Body:         raw image binary
--
-- Response:
--   200 OK        processed image binary (X-Imgproxy: processed)
--   200 OK        original bytes if no processing params (X-Imgproxy: passthrough)
--   400           missing or empty body
--   415           unsupported / unreadable image
--   502           imgproxy error

local _M = {}

local imgproc = require("lib.imgproc")
local http = require("resty.http")

-- ── Config ─────────────────────────────────────────────────────────────────

local IMGPROXY_HOST = os.getenv("IMGPROXY_HOST") or "imgproxy"
local IMGPROXY_PORT = os.getenv("IMGPROXY_PORT") or "8080"

-- ── Build imgproxy processing string ───────────────────────────────────────

local function build_processing_string(w, h, fit, fmt, q)
    local parts = {}

    if w and w > 0 then
        table.insert(parts, "width:" .. tostring(w))
    end
    if h and h > 0 then
        table.insert(parts, "height:" .. tostring(h))
    end
    if fit and fit ~= "contain" then
        table.insert(parts, "fit:" .. fit)
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

-- ── Main handler ───────────────────────────────────────────────────────────

function _M.handle()
    -- ── Only POST allowed ──────────────────────────────────────────────────
    if ngx.req.get_method() ~= "POST" then
        ngx.status = 405
        ngx.header["Allow"] = "POST"
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"method_not_allowed","message":"use POST"}')
        return ngx.exit(405)
    end

    -- ── Read request body ──────────────────────────────────────────────────
    ngx.req.read_body()
    local body = ngx.req.get_body_data()

    if not body then
        -- Body was spooled to a temp file (larger than client_body_buffer_size)
        local fname = ngx.req.get_body_file()
        if fname then
            local fh = io.open(fname, "rb")
            if fh then
                body = fh:read("*a")
                fh:close()
            end
        end
    end

    if not body or #body == 0 then
        ngx.status = 400
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"bad_request","message":"empty body — send image binary as POST body"}')
        return ngx.exit(400)
    end

    -- ── Parse query params ─────────────────────────────────────────────────
    local args        = ngx.req.get_uri_args()
    local w           = imgproc.parse_int(args.w, nil)
    local h           = imgproc.parse_int(args.h, nil)
    local fit         = args.fit or "contain"
    local q           = imgproc.parse_int(args.q, 82)
    local fmt         = args.fmt
    local crop_str    = args.crop
    local ignore_exts = args.ignore_exts

    -- Derive source format hint from Content-Type
    local ct      = ngx.req.get_headers()["content-type"] or ""
    local src_ext = imgproc.ext_of_content_type(ct)

    -- Check if extension should be ignored (passthrough)
    local ignore_set = imgproc.parse_ignore_exts(ignore_exts)
    if imgproc.is_ext_ignored(src_ext, ignore_set) then
        ngx.header["Content-Type"]   = ct or imgproc.mime_of_ext(src_ext)
        ngx.header["Content-Length"] = #body
        ngx.header["X-Imgproxy"]     = "passthrough-ignored"
        ngx.print(body)
        return
    end

    -- ── Fast path: no processing params → return body as-is ───────────────
    -- For raw upload, we still need to send to imgproxy to get proper content-type
    -- but with no processing extensions
    if not w and not h and not fmt and not crop_str then
        -- Still forward to imgproxy for content-type normalization
        -- but don't apply any processing
    end

    -- ── Build imgproxy URL ─────────────────────────────────────────────────
    -- imgproxy raw upload URL format:
    -- /insecure/<processing>/raw
    -- The image is sent in the request body
    local processing = build_processing_string(w, h, fit, fmt, q)
    local imgproxy_path = "/insecure/" .. processing .. "/raw"

    -- ── Forward to imgproxy via HTTP ──────────────────────────────────────
    local httpc = http.new()
    httpc:set_timeout(30000) -- 30 second timeout

    -- Connect to imgproxy
    local ok, err = httpc:connect(IMGPROXY_HOST, tonumber(IMGPROXY_PORT))
    if not ok then
        ngx.log(ngx.ERR, "[imgapi] failed to connect to imgproxy: ", err)
        ngx.status = 502
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"bad_gateway","message":"imgproxy unavailable"}')
        return ngx.exit(502)
    end

    -- Build proxy request
    local content_type = ct
    if content_type == "" then
        content_type = imgproc.mime_of_ext(src_ext)
    end

    local proxy_req = {
        method = "POST",
        path = imgproxy_path,
        headers = {
            ["Host"] = "localhost",
            ["Content-Type"] = content_type,
            ["Content-Length"] = tostring(#body),
        },
        body = body,
    }

    -- Send request to imgproxy
    local proxy_res, err = httpc:request(proxy_req)
    if not proxy_res then
        ngx.log(ngx.ERR, "[imgapi] imgproxy request failed: ", err)
        httpc:close()
        ngx.status = 502
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"bad_gateway","message":"imgproxy request failed"}')
        return ngx.exit(502)
    end

    -- Read response body
    local res_body, err = proxy_res:read_body()
    if not res_body then
        ngx.log(ngx.ERR, "[imgapi] failed to read imgproxy response: ", err)
        httpc:close()
        ngx.status = 502
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"bad_gateway","message":"failed to read imgproxy response"}')
        return ngx.exit(502)
    end

    -- Keep connection alive for connection pool
    httpc:set_keepalive(10000, 64)

    -- Check imgproxy response status
    local status = proxy_res.status
    if status ~= 200 then
        ngx.log(ngx.WARN, "[imgapi] imgproxy returned status ", status)
        ngx.status = 502
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"bad_gateway","message":"imgproxy processing failed"}')
        return ngx.exit(502)
    end

    -- ── Send response to client ────────────────────────────────────────────
    local res_headers = proxy_res.headers
    ngx.status = 200
    ngx.header["Content-Type"]   = res_headers["Content-Type"] or "application/octet-stream"
    ngx.header["Content-Length"] = #res_body
    ngx.header["X-Imgproxy"]     = "processed"
    ngx.header["Cache-Control"] = "private, max-age=86400"
    ngx.print(res_body)
end

return _M