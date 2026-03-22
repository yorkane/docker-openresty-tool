-- lib/vips.lua
-- Dynamic image processing via libvips (lua-vips)
-- Supports resize, crop, format conversion via URL query params
--
-- URL format:
--   /img/<path/to/image>?w=200&h=150&fit=cover&fmt=webp&q=80
--   /img/<path/to/image>?crop=x,y,w,h&fmt=jpeg
--
-- Query params:
--   w            - target width  (pixels)
--   h            - target height (pixels)
--   fit          - resize mode: contain (default) | cover | fill | scale
--   crop         - crop before resize: "x,y,width,height" (pixels)
--   fmt          - output format: jpeg | webp | png | avif | gif  (default: keep original)
--   q            - quality 1-100 (jpeg/webp/avif, default 82)
--   ignore_exts  - comma-separated extensions to skip processing (e.g. "gif,webp")
--
-- Source root: $webdav_root (same as WebDAV)
--
-- Caching: Handled entirely by nginx proxy_cache in main.conf
--   - Nginx handles all caching logic
--   - No cache-related logic in Lua

local _M = {}

local imgproc = require("lib.imgproc")

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function parse_int(s, default)
    local n = tonumber(s)
    if n and n > 0 then return math.floor(n) end
    return default
end

local function ext_of(path)
    return (path:match("%.([^./]+)$") or ""):lower()
end

-- ── Main handler ─────────────────────────────────────────────────────────────

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

    local args      = ngx.req.get_uri_args()
    local w         = parse_int(args.w, nil)
    local h         = parse_int(args.h, nil)
    local fit       = args.fit or "contain"
    local q         = parse_int(args.q, 82)
    local fmt       = args.fmt
    local crop_str  = args.crop  -- "x,y,w,h"
    local ignore_exts = args.ignore_exts  -- comma-separated

    local src_ext = ext_of(rel):lower()

    -- Check if extension should be ignored (preserve original)
    local ignore_set = imgproc.parse_ignore_exts(ignore_exts)
    if imgproc.is_ext_ignored(src_ext, ignore_set) then
        ngx.header["Content-Type"] = imgproc.mime_of_ext(src_ext)
        ngx.header["X-Vips"] = "passthrough-ignored"
        ngx.header["Cache-Control"] = "public, max-age=86400"
        local fh = io.open(src_path, "rb")
        local data = fh:read("*a")
        fh:close()
        ngx.print(data)
        return
    end

    -- ── Fast path: no processing params → serve original ──────────────────
    if not w and not h and not fmt and not crop_str then
        ngx.header["Content-Type"] = imgproc.mime_of_ext(src_ext)
        ngx.header["X-Vips"] = "passthrough"
        ngx.header["Cache-Control"] = "public, max-age=86400"
        local fh = io.open(src_path, "rb")
        local data = fh:read("*a")
        fh:close()
        ngx.print(data)
        return
    end

    -- ── Load and process via libvips ──────────────────────────────────────
    local ok, img_or_reason = imgproc.load_from_file(src_path, src_ext, {w=w, h=h})
    if not ok then
        -- Check if it's a skip reason (animated image)
        if img_or_reason and img_or_reason:find("animated") then
            ngx.header["Content-Type"] = imgproc.mime_of_ext(src_ext)
            ngx.header["X-Vips"] = "passthrough-" .. img_or_reason:gsub("%s+%-.*", "")
            ngx.header["Cache-Control"] = "public, max-age=86400"
            local fh = io.open(src_path, "rb")
            local data = fh:read("*a")
            fh:close()
            ngx.print(data)
            return
        end
        ngx.log(ngx.ERR, "[vips] failed to load: ", src_path, " err=", tostring(img_or_reason))
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local img = img_or_reason

    -- Process pipeline
    local params = { w=w, h=h, fit=fit, crop=crop_str, fmt=fmt, q=q }
    local ok2, result = imgproc.process_pipeline(img, params, src_ext, {strip=true})
    if not ok2 then
        ngx.log(ngx.ERR, "[vips] processing failed: ", tostring(result))
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Send response
    ngx.header["Content-Type"]   = result.content_type
    ngx.header["Content-Length"] = #result.buf
    ngx.header["X-Vips"]         = "processed"
    ngx.header["X-Vips-Size"]    = result.width .. "x" .. result.height
    ngx.header["Cache-Control"]  = "public, max-age=86400"

    ngx.print(result.buf)
end

return _M
