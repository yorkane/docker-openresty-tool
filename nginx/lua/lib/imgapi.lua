-- lib/imgapi.lua
-- Binary image processing API — POST /api/img
-- Accepts raw image bytes in request body, forwards to imgproxy for processing.
-- Parameters are identical to /img/ (w, h, fit, crop, fmt, q, ignore_exts).
--
-- Architecture: RAM Disk Bridge
-- imgproxy开源版不支持直接POST二进制流。本实现利用Linux内存盘(/dev/shm)作为高性能桥接：
--   1. OpenResty接收POST图片二进制流
--   2. 写入/mnt/ramdisk/.imgapi-tmp/ (共享tmpfs volume，零磁盘I/O)
--   3. 调用imgproxy: local:///mnt/ramdisk/.imgapi-tmp/file
--      (imgproxy LOCAL_FILESYSTEM_ROOT=/, 所以此路径即为绝对路径)
--   4. imgproxy从内存盘读取、处理、返回结果
--   5. OpenResty返回结果并立即删除临时文件
--
-- URL:
--   POST /api/img?w=200&h=150&fit=cover&fmt=webp&q=80
--   POST /api/img?crop=x,y,w,h&fmt=jpeg&q=90
--
-- Query params (same as /img/):
--   w            - target width  (pixels)
--   h            - target height (pixels)
--   fit          - resize mode: contain (default) | cover | fill | scale
--   crop         - crop before resize: "x,y,width,height" (NOT supported yet)
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
local imgproxy = require("lib.imgproxy")

-- ── Config ─────────────────────────────────────────────────────────────────

-- RAM Disk Bridge for zero disk I/O:
--   yot container:      writes to /mnt/ramdisk/.imgapi-tmp/ (shared named tmpfs volume)
--   imgproxy container: same volume mounted at /mnt/ramdisk/
--   imgproxy LOCAL_FILESYSTEM_ROOT=/, so local:///mnt/ramdisk/.imgapi-tmp/file → /mnt/ramdisk/.imgapi-tmp/file
local TMP_DIR     = "/mnt/ramdisk/.imgapi-tmp"
local TMP_REL_DIR = "mnt/ramdisk/.imgapi-tmp"  -- relative path for imgproxy local:// URL (no leading /)

-- Ensure tmp directory exists with correct permissions (writable by nginx workers)
os.execute("mkdir -p " .. TMP_DIR .. " && chmod 1777 " .. TMP_DIR)

-- ── Map fit modes to imgproxy resizing_type ─────────────────────────────────

-- Note: uses imgproxy.map_resizing_type from the shared library

-- ── Build imgproxy processing string ───────────────────────────────────────

-- Note: uses imgproxy.build_processing from the shared library

-- ── Save body to temp file ─────────────────────────────────────────────────

local function save_to_temp_file(body, ext)
    -- Ensure tmp directory exists and is writable by all users (like /tmp, sticky bit)
    os.execute("mkdir -p " .. TMP_DIR .. " && chmod 1777 " .. TMP_DIR)

    local unique_id = ngx.now() * 1000 + math.random(1000)
    local filename = string.format("%d", unique_id) .. "." .. ext
    local abs_path = TMP_DIR .. "/" .. filename
    local f, err = io.open(abs_path, "wb")
    if not f then
        return nil, nil, "failed to open temp file: " .. tostring(err)
    end
    local ok, werr = f:write(body)
    f:close()
    if not ok then
        return nil, nil, "failed to write temp file: " .. tostring(werr)
    end
    -- Return both absolute path (for cleanup) and relative path (for imgproxy local:// URL)
    -- imgproxy LOCAL_FILESYSTEM_ROOT=/data, mounted at /data/ramdisk in imgproxy container
    -- So local:///ramdisk/.imgapi-tmp/xxx.png → /data/ramdisk/.imgapi-tmp/xxx.png
    local rel_path = TMP_REL_DIR .. "/" .. filename
    return abs_path, rel_path
end

-- ── Process via imgproxy ───────────────────────────────────────────────────

local function process_via_imgproxy(rel_path, processing)
    local imgproxy_path = "/insecure/" .. processing .. "/plain/local:///" .. rel_path
    return imgproxy.request(imgproxy_path)
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

    -- ── No processing params → return body as-is ────────────────────────────
    if not w and not h and not fmt and not crop_str then
        ngx.header["Content-Type"]   = ct or imgproc.mime_of_ext(src_ext)
        ngx.header["Content-Length"] = #body
        ngx.header["X-Imgproxy"]     = "passthrough"
        ngx.print(body)
        return
    end

    -- ── Save body to temp file ──────────────────────────────────────────────
    local ext = src_ext
    if ext == "" or ext == "jpeg" then ext = "jpg" end

    local tmp_path, rel_path, err = save_to_temp_file(body, ext)
    if not tmp_path then
        ngx.log(ngx.ERR, "[imgapi] failed to save temp file: ", err)
        ngx.status = 500
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"internal","message":"failed to save temp file"}')
        return ngx.exit(500)
    end

    -- ── Build processing string ─────────────────────────────────────────────
    local processing = imgproxy.build_processing(w, h, fit, fmt, q)

    -- ── Process via imgproxy ────────────────────────────────────────────────
    local result, imgproxy_err, err_status = process_via_imgproxy(rel_path, processing)

    -- ── Clean up temp file ─────────────────────────────────────────────────
    os.remove(tmp_path)

    if not result then
        ngx.log(ngx.ERR, "[imgapi] imgproxy error: ", imgproxy_err)
        ngx.status = err_status or 502
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.print('{"error":"bad_gateway","message":"' .. ngx.escape_uri(imgproxy_err) .. '"}')
        return ngx.exit(ngx.status)
    end

    -- ── Send response to client ────────────────────────────────────────────
    ngx.status = 200
    ngx.header["Content-Type"]   = result.headers["Content-Type"] or "application/octet-stream"
    ngx.header["Content-Length"] = #result.body
    ngx.header["X-Imgproxy"]     = "processed"
    ngx.header["Cache-Control"] = "private, max-age=86400"
    ngx.print(result.body)
end

return _M