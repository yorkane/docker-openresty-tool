-- lib/imgapi.lua
-- Binary image processing API — POST /api/img
-- Accepts raw image bytes in request body, returns processed image bytes.
-- Parameters are identical to /img/ (w, h, fit, crop, fmt, q).
--
-- Designed for high-concurrency, high-throughput real-time processing:
--   - Reads image entirely from memory (no disk I/O)
--   - Uses vips.Image.new_from_buffer() for zero-copy load
--   - Enables vips thread concurrency to saturate all CPU cores
--   - No caching (stateless, caller is responsible for caching)
--   - Streams output buffer directly to client
--
-- URL:
--   POST /api/img?w=200&h=150&fit=cover&fmt=webp&q=80
--   POST /api/img?crop=x,y,w,h&fmt=jpeg&q=90
--
-- Query params (same as /img/):
--   w      - target width  (pixels)
--   h      - target height (pixels)
--   fit    - resize mode: contain (default) | cover | fill | scale
--   crop   - crop before resize: "x,y,width,height"
--   fmt    - output format: jpeg | webp | png | avif | gif
--   q      - quality 1-100 (jpeg/webp/avif, default 82)
--
-- Request:
--   Method:       POST
--   Content-Type: image/* (any supported image format)
--   Body:         raw image binary
--
-- Response:
--   200 OK        processed image binary
--   400           missing or empty body
--   415           unsupported / unreadable image
--   503           lua-vips not available

local _M = {}

-- ── Helpers (same as lib/vips.lua) ────────────────────────────────────────────

local function parse_int(s, default)
    local n = tonumber(s)
    if n and n > 0 then return math.floor(n) end
    return default
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function ext_of_content_type(ct)
    -- Extract a rough extension hint from Content-Type for format fallback
    if not ct then return "jpg" end
    ct = ct:lower():match("^([^;]+)") or ct:lower()
    if ct:find("webp")  then return "webp" end
    if ct:find("avif")  then return "avif" end
    if ct:find("png")   then return "png"  end
    if ct:find("gif")   then return "gif"  end
    if ct:find("tiff")  then return "tiff" end
    return "jpg"  -- jpeg / unknown → jpg
end

-- Build vips save suffix (same logic as lib/vips.lua)
local function build_save_suffix(fmt, quality, src_ext)
    fmt = (fmt and fmt:lower()) or ""
    if fmt == "jpeg" then fmt = "jpg" end
    local q = clamp(parse_int(quality, 82), 1, 100)

    if fmt == "jpg" then
        return ".jpg[Q=" .. q .. "]", "image/jpeg"
    elseif fmt == "webp" then
        return ".webp[Q=" .. q .. "]", "image/webp"
    elseif fmt == "avif" then
        return ".avif[Q=" .. q .. "]", "image/avif"
    elseif fmt == "png" then
        return ".png", "image/png"
    elseif fmt == "gif" then
        return ".gif", "image/gif"
    end

    -- Keep original format (derive from Content-Type hint)
    local e = src_ext:lower()
    if e == "jpg" or e == "jpeg" then
        return ".jpg[Q=" .. q .. "]", "image/jpeg"
    elseif e == "png" then
        return ".png", "image/png"
    elseif e == "webp" then
        return ".webp[Q=" .. q .. "]", "image/webp"
    elseif e == "avif" then
        return ".avif[Q=" .. q .. "]", "image/avif"
    elseif e == "gif" then
        return ".gif", "image/gif"
    else
        return ".jpg[Q=" .. q .. "]", "image/jpeg"
    end
end

-- ── Main handler ───────────────────────────────────────────────────────────────

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
    -- ngx.req.read_body() is required before accessing body data.
    -- For large images nginx may have spooled the body to a temp file;
    -- we handle both in-memory and file-spooled cases.
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

    -- ── Load lua-vips ──────────────────────────────────────────────────────
    local ok, vips = pcall(require, "vips")
    if not ok then
        ngx.log(ngx.ERR, "[imgapi] lua-vips not available: ", vips)
        ngx.status = 503
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"service_unavailable","message":"image processing unavailable: lua-vips not installed"}')
        return ngx.exit(503)
    end

    -- ── Maximize CPU concurrency ───────────────────────────────────────────
    -- vips defaults to using N-1 threads; we allow it to use all cores.
    -- This is safe in an nginx worker process because vips manages its own
    -- thread pool internally. Set once; vips remembers the setting globally.
    --
    -- concurrency = 0  → vips chooses based on CPU count (recommended)
    -- We only set this if not already configured via VIPS_CONCURRENCY env.
    local vips_conc = os.getenv("VIPS_CONCURRENCY")
    if not vips_conc then
        -- vips.concurrency_set is a C binding; ignore errors if unavailable
        pcall(function() vips.concurrency_set(0) end)
    end

    -- ── Parse query params ─────────────────────────────────────────────────
    local args     = ngx.req.get_uri_args()
    local w        = parse_int(args.w, nil)
    local h        = parse_int(args.h, nil)
    local fit      = args.fit or "contain"
    local q        = parse_int(args.q, 82)
    local fmt      = args.fmt
    local crop_str = args.crop  -- "x,y,w,h"

    -- Derive source format hint from Content-Type
    local ct      = ngx.req.get_headers()["content-type"] or ""
    local src_ext = ext_of_content_type(ct)

    -- ── Fast path: no processing params → return body as-is ───────────────
    if not w and not h and not fmt and not crop_str then
        ngx.header["Content-Type"]   = ngx.req.get_headers()["content-type"] or "application/octet-stream"
        ngx.header["Content-Length"] = #body
        ngx.header["X-Vips"]         = "passthrough"
        ngx.print(body)
        return
    end

    -- ── Load image from memory buffer ──────────────────────────────────────
    -- new_from_buffer() decodes the full image into memory.
    -- "[access=sequential]" would save RAM for single-pass ops but is
    -- incompatible with crop+resize pipelines, so we use the default
    -- (random-access) mode here for maximum compatibility.
    local ok2, img = pcall(vips.Image.new_from_buffer, body, "")
    if not ok2 or not img then
        ngx.log(ngx.ERR, "[imgapi] failed to decode image from buffer, err=", tostring(img),
                " body_len=", #body)
        ngx.status = 415
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"unsupported_media_type","message":"cannot decode image — unsupported or corrupt format"}')
        return ngx.exit(415)
    end

    -- ── Crop first if requested ────────────────────────────────────────────
    if crop_str then
        local cx, cy, cw, ch = crop_str:match("(%d+),(%d+),(%d+),(%d+)")
        if cx then
            cx, cy, cw, ch = tonumber(cx), tonumber(cy), tonumber(cw), tonumber(ch)
            cw = math.min(cw, img:width()  - cx)
            ch = math.min(ch, img:height() - cy)
            if cw > 0 and ch > 0 then
                local ok3, cropped = pcall(function()
                    return img:crop(cx, cy, cw, ch)
                end)
                if ok3 then img = cropped end
            end
        end
    end

    -- ── Resize ────────────────────────────────────────────────────────────
    if w or h then
        local src_w = img:width()
        local src_h = img:height()

        if fit == "fill" then
            local tw = w or src_w
            local th = h or src_h
            local ok4, resized = pcall(function()
                return img:resize(tw / src_w, {vscale = th / src_h})
            end)
            if ok4 then img = resized end

        elseif fit == "cover" then
            local tw    = w or src_w
            local th    = h or src_h
            local scale = math.max(tw / src_w, th / src_h)
            local ok4, resized = pcall(function() return img:resize(scale) end)
            if ok4 then img = resized end
            local cx2 = math.floor((img:width()  - tw) / 2)
            local cy2 = math.floor((img:height() - th) / 2)
            if cx2 >= 0 and cy2 >= 0 then
                local ok5, cropped2 = pcall(function()
                    return img:crop(cx2, cy2, tw, th)
                end)
                if ok5 then img = cropped2 end
            end

        elseif fit == "scale" then
            if w then
                local scale = w / src_w
                local ok4, resized = pcall(function() return img:resize(scale) end)
                if ok4 then img = resized end
            end

        else  -- contain (default)
            local tw    = w or math.huge
            local th    = h or math.huge
            local scale = math.min(tw / src_w, th / src_h)
            if scale ~= 1.0 then
                local ok4, resized = pcall(function() return img:resize(scale) end)
                if ok4 then img = resized end
            end
        end
    end

    -- ── Encode to output format ────────────────────────────────────────────
    local save_suffix, content_type = build_save_suffix(fmt, q, src_ext)

    local ok6, buf = pcall(function()
        return img:write_to_buffer(save_suffix)
    end)
    if not ok6 or not buf then
        ngx.log(ngx.ERR, "[imgapi] write_to_buffer failed: ", tostring(buf))
        ngx.status = 500
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"internal","message":"image encoding failed"}')
        return ngx.exit(500)
    end

    -- ── Send response ──────────────────────────────────────────────────────
    ngx.header["Content-Type"]   = content_type
    ngx.header["Content-Length"] = #buf
    ngx.header["X-Vips"]         = "processed"
    ngx.header["X-Vips-Size"]    = img:width() .. "x" .. img:height()
    -- No Cache-Control: this endpoint is for real-time processing,
    -- caching is the caller's responsibility.

    ngx.print(buf)
end

return _M
