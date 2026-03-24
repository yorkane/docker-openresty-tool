-- lib/imgproc.lua
-- Image processing shared library — format handling, animated detection, processing core
--
-- Unified interface for:
--   • lib/vips.lua      — /img/<path>  (file-based, nginx proxy_cache)
--   • lib/imgapi.lua    — POST /api/img (memory-based, real-time)
--   • lib/batchapi.lua  — POST /api/batch-img (batch local/remote)

local _M = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Format tables
-- ─────────────────────────────────────────────────────────────────────────────

-- MIME type by extension
_M.MIME_OF_EXT = {
    jpg="image/jpeg", jpeg="image/jpeg", jfif="image/jpeg", jpe="image/jpeg",
    png="image/png",
    webp="image/webp",
    avif="image/avif",
    gif="image/gif",
    tiff="image/tiff", tif="image/tiff",
    bmp="image/bmp",
    heic="image/heic", heif="image/heif",
    ico="image/x-icon",
    svg="image/svg+xml",
}

-- Extension normalization (canonical → aliases)
_M.EXT_ALIASES = {
    jpeg={"jpg","jfif","jpe"},
    tiff={"tif"},
}

-- Reverse: alias → canonical
_M.EXT_CANONICAL = {}
for canon, aliases in pairs(_M.EXT_ALIASES) do
    for _, alias in ipairs(aliases) do
        _M.EXT_CANONICAL[alias] = canon
    end
end
setmetatable(_M.EXT_CANONICAL, {
    __index = function(t, k) return k end
})

-- Formats that may be animated (we should avoid processing to preserve animation)
_M.ANIMATED_FORMATS = {
    webp=true,
    gif=true,
}

-- Formats we can process via libvips
_M.PROCESSABLE_EXTS = {
    jpg=true, jpeg=true, png=true, webp=true,
    avif=true, gif=true, tiff=true, tif=true, bmp=true,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

function _M.parse_int(s, default)
    local n = tonumber(s)
    if n and n > 0 then return math.floor(n) end
    return default
end

function _M.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function _M.ext_of(path)
    return (path:match("%.([^./]+)$") or ""):lower()
end

function _M.canonical_ext(ext)
    return _M.EXT_CANONICAL[ext:lower()]
end

-- Extract extension hint from Content-Type header
function _M.ext_of_content_type(ct)
    if not ct then return "jpg" end
    ct = ct:lower():match("^([^;]+)") or ct:lower()
    if ct:find("webp")  then return "webp" end
    if ct:find("avif")  then return "avif" end
    if ct:find("png")   then return "png"  end
    if ct:find("gif")   then return "gif"  end
    if ct:find("tiff")  then return "tiff" end
    return "jpg"
end

-- Get MIME type by extension
function _M.mime_of_ext(ext)
    return _M.MIME_OF_EXT[ext:lower()] or "application/octet-stream"
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Animated image detection (quick heuristics)
-- ─────────────────────────────────────────────────────────────────────────────

-- Check if WebP is animated (VP8X chunk with ANIM flag)
-- Returns: is_animated (boolean), err (string or nil)
function _M.is_animated_webp(data)
    if not data or #data < 12 then return false end
    -- RIFF....WEBP
    if data:sub(1,4) ~= "RIFF" or data:sub(9,12) ~= "WEBP" then
        return false, "not a valid WebP"
    end
    -- Scan chunks for VP8X (0x56503858) with animation flag (bit 1 of flags byte)
    local pos = 13
    while pos + 8 <= #data do
        local chunk_id = data:sub(pos, pos+3)
        local b0 = data:byte(pos+4) or 0
        local b1 = data:byte(pos+5) or 0
        local b2 = data:byte(pos+6) or 0
        local b3 = data:byte(pos+7) or 0
        local chunk_sz = b0 + b1*256 + b2*65536 + b3*16777216
        if chunk_id == "VP8X" and pos + 8 < #data then
            local flags = data:byte(pos+8) or 0
            -- bit 1 (0x02) = animation flag
            return bit.band(flags, 0x02) ~= 0
        end
        pos = pos + 8 + chunk_sz + (chunk_sz % 2)  -- pad to even
        if chunk_sz > #data then break end
    end
    return false
end

-- Check if GIF is animated (multiple images/frames)
function _M.is_animated_gif(data)
    if not data or #data < 10 then return false end
    if data:sub(1,3) ~= "GIF" then return false end
    -- Count image descriptors (0x2C) excluding the global color table
    -- A crude heuristic: more than one 0x2C after headers suggests animation
    local count = 0
    for i = 14, math.min(#data, 1048576) do  -- scan first 1MB max
        if data:byte(i) == 0x2C then
            count = count + 1
            if count >= 2 then return true end
        end
    end
    return false
end

-- Generic animated check
-- Returns: should_skip (boolean), reason (string or nil)
function _M.should_skip_animated(ext, data)
    ext = ext:lower()
    if ext == "webp" then
        local animated, err = _M.is_animated_webp(data)
        if err then return false end  -- process if unsure
        if animated then return true, "animated webp — skipped to preserve animation" end
    elseif ext == "gif" then
        if _M.is_animated_gif(data) then
            return true, "animated gif — skipped to preserve animation"
        end
    end
    return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Build vips save suffix (format + quality + options)
-- ─────────────────────────────────────────────────────────────────────────────

-- Options:
--   strip    — remove EXIF/ICC/XMP metadata (default true for speed)
-- Returns: save_suffix (string), content_type (string), out_ext (string)
function _M.build_save_suffix(fmt, quality, src_ext, opts)
    opts = opts or {}
    local strip = (opts.strip ~= false)  -- default true

    fmt = (fmt and fmt:lower()) or ""
    if fmt == "jpeg" then fmt = "jpg" end
    local q = _M.clamp(_M.parse_int(quality, 82), 1, 100)

    local function sfx(ext, mime)
        local s = "." .. ext
        if ext == "jpg" or ext == "webp" or ext == "avif" then
            s = s .. "[Q=" .. q .. "]"
        end
        if strip then s = s .. "[strip]" end
        return s, mime, ext
    end

    if fmt == "jpg"  then return sfx("jpg", "image/jpeg") end
    if fmt == "webp" then return sfx("webp", "image/webp") end
    if fmt == "avif" then return sfx("avif", "image/avif") end
    if fmt == "png"  then
        local s = ".png"
        if strip then s = s .. "[strip]" end
        return s, "image/png", "png"
    end
    if fmt == "gif"  then return ".gif", "image/gif", "gif" end

    -- Keep original format
    local e = src_ext:lower()
    if e == "jpg" or e == "jpeg" then return sfx("jpg", "image/jpeg") end
    if e == "png"  then
        local s = ".png"
        if strip then s = s .. "[strip]" end
        return s, "image/png", "png"
    end
    if e == "webp" then return sfx("webp", "image/webp") end
    if e == "avif" then return sfx("avif", "image/avif") end
    if e == "gif"  then return ".gif", "image/gif", "gif" end
    return sfx("jpg", "image/jpeg")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- JPEG shrink-on-load hint for faster decode
-- ─────────────────────────────────────────────────────────────────────────────

function _M.jpeg_shrink_hint(body_len, target_w, target_h)
    if not target_w and not target_h then return nil end
    -- libjpeg supports 1,2,4,8; we request 8 and let vips clamp
    return "[shrink=8]"
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Core image processing pipeline
-- ─────────────────────────────────────────────────────────────────────────────

-- Params:
--   img        — vips.Image object (already loaded)
--   params     — table with w, h, fit, crop, fmt, q
--   src_ext    — source extension (for format fallback)
--   opts       — options: strip (bool)
-- Returns: ok (bool), result (table with buf, content_type, width, height) or error string
function _M.process_pipeline(img, params, src_ext, opts)
    opts = opts or {}
    local ok, err

    -- Crop first if requested
    if params.crop then
        local cx, cy, cw, ch = params.crop:match("(%d+),(%d+),(%d+),(%d+)")
        if cx then
            cx, cy, cw, ch = tonumber(cx), tonumber(cy), tonumber(cw), tonumber(ch)
            cw = math.min(cw, img:width()  - cx)
            ch = math.min(ch, img:height() - cy)
            if cw > 0 and ch > 0 then
                ok, err = pcall(function() return img:crop(cx, cy, cw, ch) end)
                if ok then img = err end
            end
        end
    end

    -- Resize
    if params.w or params.h then
        local src_w = img:width()
        local src_h = img:height()
        local fit = params.fit or "contain"

        if fit == "fill" then
            local tw = params.w or src_w
            local th = params.h or src_h
            ok, err = pcall(function()
                return img:resize(tw / src_w, {vscale = th / src_h})
            end)
            if ok then img = err end

        elseif fit == "cover" then
            local tw    = params.w or src_w
            local th    = params.h or src_h
            local scale = math.max(tw / src_w, th / src_h)
            ok, err = pcall(function() return img:resize(scale) end)
            if ok then img = err end
            local cx2 = math.floor((img:width()  - tw) / 2)
            local cy2 = math.floor((img:height() - th) / 2)
            if cx2 >= 0 and cy2 >= 0 then
                ok, err = pcall(function() return img:crop(cx2, cy2, tw, th) end)
                if ok then img = err end
            end

        elseif fit == "scale" then
            if params.w then
                local scale = params.w / src_w
                ok, err = pcall(function() return img:resize(scale) end)
                if ok then img = err end
            end

        else  -- contain (default)
            local tw    = params.w or math.huge
            local th    = params.h or math.huge
            local scale = math.min(tw / src_w, th / src_h)
            if scale ~= 1.0 then
                ok, err = pcall(function() return img:resize(scale) end)
                if ok then img = err end
            end
        end
    end

    -- Encode
    local save_suffix, content_type = _M.build_save_suffix(params.fmt, params.q, src_ext, opts)
    ok, err = pcall(function() return img:write_to_buffer(save_suffix) end)
    if not ok or not err then
        return false, "encode failed: " .. tostring(err)
    end

    return true, {
        buf = err,
        content_type = content_type,
        width = img:width(),
        height = img:height(),
    }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Extension filter for batch processing
-- ─────────────────────────────────────────────────────────────────────────────

-- Parse ignore_exts string like "gif,webp" or array {"gif","webp"}
-- Returns: set table {ext=true}, or nil
function _M.parse_ignore_exts(input)
    if not input then return nil end
    local t = {}
    if type(input) == "string" then
        for ext in input:gmatch("[^,]+") do
            ext = ext:gsub("^%s+", ""):gsub("%s+$", ""):lower()
            if ext ~= "" then t[ext] = true end
        end
    elseif type(input) == "table" then
        for _, ext in ipairs(input) do
            t[tostring(ext):lower()] = true
        end
    end
    if next(t) == nil then return nil end
    return t
end

function _M.is_ext_ignored(ext, ignore_set)
    if not ignore_set then return false end
    return ignore_set[ext:lower()] == true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- vips loader wrapper with animated skip support
-- ─────────────────────────────────────────────────────────────────────────────

-- For memory-based loading (imgapi)
-- Returns: ok (bool), img_or_reason (vips.Image or skip reason string) or error
function _M.load_from_buffer(body, src_ext, params)
    local skip, reason = _M.should_skip_animated(src_ext, body)
    if skip then
        return false, reason  -- caller should passthrough
    end

    local load_opts = ""
    local ext = src_ext:lower()
    if (ext == "jpg" or ext == "jpeg") and (params.w or params.h) then
        local hint = _M.jpeg_shrink_hint(#body, params.w, params.h)
        if hint then load_opts = hint end
    end

    local ok, vips = pcall(require, "vips")
    if not ok then return false, "lua-vips unavailable" end

    local ok2, img = pcall(vips.Image.new_from_buffer, body, load_opts)
    if not ok2 then return false, "decode failed: " .. tostring(img) end
    return true, img
end

-- For file-based loading (vips.lua)
function _M.load_from_file(path, src_ext, params)
    -- Read first 1MB to check animation
    local fh = io.open(path, "rb")
    if not fh then return false, "cannot open file" end
    local head = fh:read(1048576) or ""
    fh:close()

    local skip, reason = _M.should_skip_animated(src_ext, head)
    if skip then
        return false, reason
    end

    -- vips requires all options in a single [...] block, comma-separated
    -- e.g. [access=sequential,shrink=8] NOT [access=sequential][shrink=8]
    local ext = src_ext:lower()
    local load_opts
    if (ext == "jpg" or ext == "jpeg") and (params.w or params.h) then
        load_opts = "[access=sequential,shrink=8]"
    else
        load_opts = "[access=sequential]"
    end

    local ok, vips = pcall(require, "vips")
    if not ok then return false, "lua-vips unavailable" end

    local ok2, img = pcall(vips.Image.new_from_file, path .. load_opts)
    if not ok2 then return false, "decode failed: " .. tostring(img) end
    return true, img
end

return _M
