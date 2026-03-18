-- lib/vips.lua
-- Dynamic image processing via libvips (lua-vips)
-- Supports resize, crop, format conversion via URL query params
--
-- URL format:
--   /img/<path/to/image>?w=200&h=150&fit=cover&fmt=webp&q=80
--   /img/<path/to/image>?crop=x,y,w,h&fmt=jpeg
--
-- Query params:
--   w      - target width  (pixels)
--   h      - target height (pixels)
--   fit    - resize mode: contain (default) | cover | fill | scale
--   crop   - crop before resize: "x,y,width,height" (pixels)
--   fmt    - output format: jpeg | webp | png | avif | gif  (default: keep original)
--   q      - quality 1-100 (jpeg/webp/avif, default 82)
--
-- Source root: $webdav_root (same as WebDAV)
--
-- Caching: Handled entirely by nginx proxy_cache in main.conf
--   - Nginx handles all caching logic
--   - No cache-related logic in Lua

local _M = {}

-- ── MIME / format tables ───────────────────────────────────────────────────────

local mime_map = {
    jpeg = "image/jpeg",
    jpg  = "image/jpeg",
    png  = "image/png",
    webp = "image/webp",
    avif = "image/avif",
    gif  = "image/gif",
    tiff = "image/tiff",
    tif  = "image/tiff",
}

local function ext_of(path)
    return path:match("%.([^./]+)$") or ""
end

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

-- Build vips save suffix (controls format + quality)
local function build_save_suffix(fmt, quality, src_ext)
    fmt = (fmt and fmt:lower()) or ""
    if fmt == "jpeg" then fmt = "jpg" end
    local q = clamp(parse_int(quality, 82), 1, 100)

    if fmt == "jpg" then
        return ".jpg[Q=" .. q .. "]", "image/jpeg", "jpg"
    elseif fmt == "webp" then
        return ".webp[Q=" .. q .. "]", "image/webp", "webp"
    elseif fmt == "avif" then
        return ".avif[Q=" .. q .. "]", "image/avif", "avif"
    elseif fmt == "png" then
        return ".png", "image/png", "png"
    elseif fmt == "gif" then
        return ".gif", "image/gif", "gif"
    end

    -- Keep original format
    local e = src_ext:lower()
    if e == "jpg" or e == "jpeg" then
        return ".jpg[Q=" .. q .. "]", "image/jpeg", "jpg"
    elseif e == "png" then
        return ".png", "image/png", "png"
    elseif e == "webp" then
        return ".webp[Q=" .. q .. "]", "image/webp", "webp"
    elseif e == "avif" then
        return ".avif[Q=" .. q .. "]", "image/avif", "avif"
    elseif e == "gif" then
        return ".gif", "image/gif", "gif"
    else
        return ".jpg[Q=" .. q .. "]", "image/jpeg", "jpg"
    end
end

-- ── Main handler ──────────────────────────────────────────────────────────────

function _M.handle(webdav_root)
    local uri = ngx.var.uri
    -- Strip /img/ or /img_internal/ prefix (internal proxy loop uses /img_internal/)
    local rel = uri:match("^/img/(.+)$") or uri:match("^/img_internal/img/(.+)$")
    if not rel then
        return ngx.exit(ngx.HTTP_NOT_FOUND)
    end

    local src_path = webdav_root .. "/" .. rel

    -- Check source file exists
    local f = io.open(src_path, "rb")
    if not f then
        ngx.log(ngx.WARN, "[vips] file not found: ", src_path)
        return ngx.exit(ngx.HTTP_NOT_FOUND)
    end
    f:close()

    local args     = ngx.req.get_uri_args()
    local w        = parse_int(args.w, nil)
    local h        = parse_int(args.h, nil)
    local fit      = args.fit or "contain"
    local q        = parse_int(args.q, 82)
    local fmt      = args.fmt
    local crop_str = args.crop  -- "x,y,w,h"

    local src_ext = ext_of(rel):lower()

    -- ── Fast path: no processing params → serve original ──────────────────
    if not w and not h and not fmt and not crop_str then
        ngx.header["Content-Type"] = mime_map[src_ext] or "application/octet-stream"
        ngx.header["X-Vips"] = "passthrough"
        ngx.header["Cache-Control"] = "public, max-age=86400"
        local fh   = io.open(src_path, "rb")
        local data = fh:read("*a")
        fh:close()
        ngx.print(data)
        return
    end

    -- ── Process via libvips ─────────────────────────────────────────────────
    local ok, vips = pcall(require, "vips")
    if not ok then
        ngx.log(ngx.ERR, "[vips] lua-vips not available: ", vips)
        ngx.status = 503
        ngx.header["Content-Type"] = "text/plain"
        ngx.print("Image processing unavailable: lua-vips not installed")
        return
    end

    -- Load image
    local ok2, img = pcall(vips.Image.new_from_file, src_path .. "[access=sequential]")
    if not ok2 or not img then
        ngx.log(ngx.ERR, "[vips] failed to load: ", src_path, " err=", tostring(img))
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Crop first if requested
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

    -- Resize
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

    -- Determine final output format
    local save_suffix, content_type
    save_suffix, content_type, out_ext = build_save_suffix(fmt, q, src_ext)

    -- Write to memory buffer
    local ok6, buf = pcall(function()
        return img:write_to_buffer(save_suffix)
    end)
    if not ok6 or not buf then
        ngx.log(ngx.ERR, "[vips] write_to_buffer failed: ", tostring(buf))
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Send response
    ngx.header["Content-Type"]   = content_type
    ngx.header["Content-Length"] = #buf
    ngx.header["X-Vips"]         = "processed"
    ngx.header["X-Vips-Size"]    = img:width() .. "x" .. img:height()
    ngx.header["Cache-Control"]  = "public, max-age=86400"

    ngx.print(buf)
end

return _M
