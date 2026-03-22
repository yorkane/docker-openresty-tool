-- lib/imgapi.lua
-- Binary image processing API — POST /api/img
-- Accepts raw image bytes in request body, returns processed image bytes.
-- Parameters are identical to /img/ (w, h, fit, crop, fmt, q, ignore_exts).
--
-- Designed for high-concurrency, high-throughput real-time processing:
--   - Reads image entirely from memory (no disk I/O)
--   - Uses vips.Image.new_from_buffer() for zero-copy load
--   - Enables vips thread concurrency to saturate all CPU cores
--   - No caching (stateless, caller is responsible for caching)
--   - Streams output buffer directly to client
--
-- Memory-for-speed optimisations:
--   - nginx client_body_buffer_size 32m  → 32 MB images stay fully in RAM, no temp-file spooling
--   - JPEG shrink-on-load hint           → vips decodes at 1/2, 1/4, 1/8 native size when possible
--                                          (2-4× faster decode, proportionally less RAM for the decoded pixels)
--   - Random-access (default) mode       → decoded pixel buffer lives in RAM; avoids any seek latency
--   - strip metadata on save             → smaller output buffer, faster encoding, less memcpy
--
-- Animated image handling:
--   - Detects animated WebP and GIF via header inspection
--   - Returns original bytes with X-Vips: passthrough-animated header
--   - Prevents accidental loss of animation during resize/format conversion
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
--   200 OK        processed image binary (X-Vips: processed)
--   200 OK        original bytes if animated/ignored (X-Vips: passthrough-animated or passthrough-ignored)
--   400           missing or empty body
--   415           unsupported / unreadable image
--   503           lua-vips not available

local _M = {}

local imgproc = require("lib.imgproc")

-- ── Main handler ─────────────────────────────────────────────────────────────

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

    -- ── Maximize CPU concurrency ───────────────────────────────────────────
    local vips_conc = os.getenv("VIPS_CONCURRENCY")
    if not vips_conc then
        local ok_vips, vips = pcall(require, "vips")
        if ok_vips then
            pcall(function() vips.concurrency_set(0) end)
        end
    end

    -- ── Parse query params ─────────────────────────────────────────────────
    local args      = ngx.req.get_uri_args()
    local w         = imgproc.parse_int(args.w, nil)
    local h         = imgproc.parse_int(args.h, nil)
    local fit       = args.fit or "contain"
    local q         = imgproc.parse_int(args.q, 82)
    local fmt       = args.fmt
    local crop_str  = args.crop
    local ignore_exts = args.ignore_exts

    -- Derive source format hint from Content-Type
    local ct      = ngx.req.get_headers()["content-type"] or ""
    local src_ext = imgproc.ext_of_content_type(ct)

    -- Check if extension should be ignored
    local ignore_set = imgproc.parse_ignore_exts(ignore_exts)
    if imgproc.is_ext_ignored(src_ext, ignore_set) then
        ngx.header["Content-Type"]   = ct or imgproc.mime_of_ext(src_ext)
        ngx.header["Content-Length"] = #body
        ngx.header["X-Vips"]         = "passthrough-ignored"
        ngx.print(body)
        return
    end

    -- ── Fast path: no processing params → return body as-is ───────────────
    if not w and not h and not fmt and not crop_str then
        ngx.header["Content-Type"]   = ct or imgproc.mime_of_ext(src_ext)
        ngx.header["Content-Length"] = #body
        ngx.header["X-Vips"]         = "passthrough"
        ngx.print(body)
        return
    end

    -- ── Load image from memory buffer ──────────────────────────────────────
    local ok, img_or_reason = imgproc.load_from_buffer(body, src_ext, {w=w, h=h})
    if not ok then
        -- Check if it's animated (should passthrough)
        if img_or_reason and img_or_reason:find("animated") then
            ngx.header["Content-Type"]   = ct or imgproc.mime_of_ext(src_ext)
            ngx.header["Content-Length"] = #body
            ngx.header["X-Vips"]         = "passthrough-animated"
            ngx.print(body)
            return
        end
        ngx.log(ngx.ERR, "[imgapi] failed to decode image from buffer, err=", tostring(img_or_reason),
                " body_len=", #body)
        ngx.status = 415
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"unsupported_media_type","message":"cannot decode image — unsupported or corrupt format"}')
        return ngx.exit(415)
    end

    local img = img_or_reason

    -- ── Process pipeline ───────────────────────────────────────────────────
    local params = { w=w, h=h, fit=fit, crop=crop_str, fmt=fmt, q=q }
    local ok2, result = imgproc.process_pipeline(img, params, src_ext, {strip=true})
    if not ok2 then
        ngx.log(ngx.ERR, "[imgapi] processing failed: ", tostring(result))
        ngx.status = 500
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"internal","message":"image processing failed"}')
        return ngx.exit(500)
    end

    -- ── Send response ──────────────────────────────────────────────────────
    ngx.header["Content-Type"]   = result.content_type
    ngx.header["Content-Length"] = #result.buf
    ngx.header["X-Vips"]         = "processed"
    ngx.header["X-Vips-Size"]    = result.width .. "x" .. result.height
    ngx.print(result.buf)
end

return _M
