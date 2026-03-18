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
-- Disk cache:
--   Processed images are cached to OR_IMG_CACHE_PATH (default /usr/local/openresty/nginx/cache)
--   Cache TTL is OR_IMG_CACHE_TTL seconds (default 172800 = 2d)
--   Only requests with processing params (w/h/fit/fmt/q/crop) are cached.
--   X-Cache-Status: HIT | MISS | BYPASS is set on every response.

local _M = {}

-- ── Cache helpers ─────────────────────────────────────────────────────────────

local function cache_dir()
    local env = require('env')
    return (env.NGX_IMG_CACHE_PATH or "/usr/local/openresty/nginx/cache") .. "/img"
end

-- Parse TTL string like "2d", "12h", "3600" into seconds
local function parse_ttl(s)
    if not s then return 172800 end  -- default 2d
    s = tostring(s)
    local n, unit = s:match("^(%d+)([dhms]?)$")
    n = tonumber(n)
    if not n then return 172800 end
    if unit == "d" then return n * 86400
    elseif unit == "h" then return n * 3600
    elseif unit == "m" then return n * 60
    else return n end
end

local function cache_ttl()
    local env = require('env')
    return parse_ttl(env.NGX_IMG_CACHE_TTL)
end

-- Stable cache key: md5 of (uri + sorted args)
local function make_cache_key(uri, args)
    -- Build a canonical sorted query string
    local parts = {}
    for k, v in pairs(args) do
        table.insert(parts, k .. "=" .. tostring(v))
    end
    table.sort(parts)
    local canonical = uri .. "?" .. table.concat(parts, "&")
    -- Use ngx.md5 for a short, safe filename
    return ngx.md5(canonical)
end

-- Ensure directory exists (mkdir -p equivalent)
local function mkdir_p(path)
    os.execute("mkdir -p " .. path)
end

-- Read file bytes, returns nil on error
local function read_file(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local data = fh:read("*a")
    fh:close()
    return data
end

-- Write bytes to file (atomic: write to tmp then rename)
local function write_file(path, data)
    local tmp = path .. ".tmp"
    local fh = io.open(tmp, "wb")
    if not fh then return false end
    fh:write(data)
    fh:close()
    return os.rename(tmp, path)
end

-- Get file mtime (seconds since epoch), returns nil if not exist
local function file_mtime(path)
    -- Try lfs_ffi (available in this OpenResty build)
    local ok, lfs = pcall(require, "lfs_ffi")
    if ok and lfs then
        local mtime, err = lfs.attributes(path, "modification")
        if mtime then return mtime end
    end
    -- Final fallback: just check existence (no TTL-based expiry)
    local fh = io.open(path, "rb")
    if fh then fh:close(); return os.time() end
    return nil
end

-- MIME type map
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

-- Extension to vips loader suffix map
local fmt_suffix = {
    jpeg = ".jpg[Q=%d]",
    jpg  = ".jpg[Q=%d]",
    png  = ".png",
    webp = ".webp[Q=%d]",
    avif = ".avif[Q=%d]",
    gif  = ".gif",
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
local function build_save_suffix(fmt, quality)
    fmt = fmt and fmt:lower() or ""
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
    return nil, nil  -- keep original format
end

function _M.handle(webdav_root)
    local uri = ngx.var.uri
    -- Strip /img/ prefix
    local rel = uri:match("^/img/(.+)$")
    if not rel then
        return ngx.exit(ngx.HTTP_NOT_FOUND)
    end

    local src_path = webdav_root .. "/" .. rel

    -- Check file exists
    local f = io.open(src_path, "rb")
    if not f then
        ngx.log(ngx.WARN, "[vips] file not found: ", src_path)
        return ngx.exit(ngx.HTTP_NOT_FOUND)
    end
    f:close()

    local args = ngx.req.get_uri_args()
    local w   = parse_int(args.w, nil)
    local h   = parse_int(args.h, nil)
    local fit = args.fit or "contain"
    local q   = parse_int(args.q, 82)
    local fmt = args.fmt
    local crop_str = args.crop  -- "x,y,w,h"

    -- Fast path: no processing needed, just serve the file (no cache)
    if not w and not h and not fmt and not crop_str then
        local src_ext = ext_of(rel):lower()
        ngx.header["Content-Type"] = mime_map[src_ext] or "application/octet-stream"
        ngx.header["X-Vips"] = "passthrough"
        ngx.header["X-Cache-Status"] = "BYPASS"
        local fh = io.open(src_path, "rb")
        local data = fh:read("*a")
        fh:close()
        ngx.print(data)
        return
    end

    -- ── Disk cache lookup ────────────────────────────────────────────────────
    -- Determine output extension for cache filename
    local out_ext = fmt and fmt:lower() or ext_of(rel):lower()
    if out_ext == "jpeg" then out_ext = "jpg" end
    local cache_key = make_cache_key(uri, args)
    local cdir = cache_dir()
    local cache_path = cdir .. "/" .. cache_key .. "." .. out_ext

    local ttl = cache_ttl()
    local mtime = file_mtime(cache_path)
    if mtime and (os.time() - mtime) < ttl then
        -- Cache HIT: serve from disk
        local cached = read_file(cache_path)
        if cached then
            local ct = mime_map[out_ext] or "application/octet-stream"
            ngx.header["Content-Type"]   = ct
            ngx.header["Content-Length"] = #cached
            ngx.header["X-Vips"]         = "cache-hit"
            ngx.header["X-Cache-Status"] = "HIT"
            ngx.header["Cache-Control"]  = "public, max-age=86400"
            ngx.print(cached)
            return
        end
    end
    -- Cache MISS — process and store below

    -- Load vips
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
            -- clamp to image bounds
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
            -- Stretch to exact dimensions
            local tw = w or src_w
            local th = h or src_h
            local ok4, resized = pcall(function()
                return img:resize(tw / src_w, {vscale = th / src_h})
            end)
            if ok4 then img = resized end

        elseif fit == "cover" then
            -- Scale to cover bounding box, then smart crop
            local tw = w or src_w
            local th = h or src_h
            local scale = math.max(tw / src_w, th / src_h)
            local ok4, resized = pcall(function()
                return img:resize(scale)
            end)
            if ok4 then img = resized end
            -- Center crop
            local cx2 = math.floor((img:width()  - tw) / 2)
            local cy2 = math.floor((img:height() - th) / 2)
            if cx2 >= 0 and cy2 >= 0 then
                local ok5, cropped2 = pcall(function()
                    return img:crop(cx2, cy2, tw, th)
                end)
                if ok5 then img = cropped2 end
            end

        elseif fit == "scale" then
            -- Scale by width only (ignore h)
            if w then
                local scale = w / src_w
                local ok4, resized = pcall(function() return img:resize(scale) end)
                if ok4 then img = resized end
            end

        else
            -- contain (default): fit within bounding box, preserve aspect ratio
            local tw = w or math.huge
            local th = h or math.huge
            local scale = math.min(tw / src_w, th / src_h)
            if scale ~= 1.0 then
                local ok4, resized = pcall(function() return img:resize(scale) end)
                if ok4 then img = resized end
            end
        end
    end

    -- Determine output format
    local src_ext = ext_of(rel):lower()
    local save_suffix, content_type = build_save_suffix(fmt, q)
    if not save_suffix then
        -- Keep original format
        if src_ext == "jpg" or src_ext == "jpeg" then
            save_suffix = ".jpg[Q=" .. q .. "]"
            content_type = "image/jpeg"
        elseif src_ext == "png" then
            save_suffix = ".png"
            content_type = "image/png"
        elseif src_ext == "webp" then
            save_suffix = ".webp[Q=" .. q .. "]"
            content_type = "image/webp"
        else
            save_suffix = ".jpg[Q=" .. q .. "]"
            content_type = "image/jpeg"
        end
    end

    -- Write to memory buffer
    local ok6, buf = pcall(function()
        return img:write_to_buffer(save_suffix)
    end)
    if not ok6 or not buf then
        ngx.log(ngx.ERR, "[vips] write_to_buffer failed: ", tostring(buf))
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Cache headers
    ngx.header["Content-Type"]  = content_type
    ngx.header["Content-Length"] = #buf
    ngx.header["X-Vips"]        = "processed"
    ngx.header["X-Vips-Size"]   = img:width() .. "x" .. img:height()
    ngx.header["Cache-Control"] = "public, max-age=86400"
    ngx.header["X-Cache-Status"] = "MISS"

    -- Write to disk cache (best-effort, don't fail on error)
    mkdir_p(cdir)
    write_file(cache_path, buf)

    ngx.print(buf)
end

return _M
