-- lib/gallerize.lua
-- Gallery organizer API — organizes directory structure and generates thumbnails
--
-- Routes:
--   POST /api/gallerize
--       Request body (application/json):
--       {
--           "path": "/data/gallery",           -- required: target directory
--           "type": "v1",                       -- required: "v1" or "v2"
--           "extra_file_path": "/data/extra",   -- optional: where to move non-image files
--           "w": 2560, "h": 2560,               -- optional: override default resize params
--           "fit": "contain", "q": 90           -- optional: override default
--       }
--
-- Type v1 behavior:
--   1. Move non-image files to extra_file_path
--   2. Flatten subdirectories (move all files to first level, remove empty dirs)
--   3. If only one subdirectory exists, promote its contents to root
--   4. Validate directory names (Windows-compatible, max 38 chars)
--   5. Skip if already processed (all .jiff files + ##cover.jiff exists)
--   6. Generate ##cover.jiff from first image (360x504 cover fit webp q=80)
--   7. Convert all images to webp (default 2560x2560 contain q=90)

local _M = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Dependencies
-- ─────────────────────────────────────────────────────────────────────────────
local ffi = require("ffi")
local imgproc = require("lib.imgproc")
local stat_ffi = require("lib.stat_ffi")

local C = ffi.C
local DT_DIR = 4

-- ─────────────────────────────────────────────────────────────────────────────
-- Configuration
-- ─────────────────────────────────────────────────────────────────────────────
local COVER_WIDTH = 360
local COVER_HEIGHT = 504
local COVER_FIT = "cover"
local COVER_FMT = "webp"
local COVER_Q = 80
local COVER_FILENAME = "##cover.jiff"

local DEFAULT_WIDTH = 2560
local DEFAULT_HEIGHT = 2560
local DEFAULT_FIT = "contain"
local DEFAULT_FMT = "webp"
local DEFAULT_Q = 90
local DEFAULT_OUT_EXT = "jiff"  -- renamed webp extension

local MAX_DIR_NAME_LEN = 38

-- Image extensions (for identifying image files)
local IMAGE_EXTS = {
    jpg = true, jpeg = true, png = true, webp = true,
    gif = true, bmp = true, tiff = true, tif = true,
    avif = true, heic = true, heif = true,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────
local function send_json(status, body)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.header["Cache-Control"] = "no-store"
    ngx.print(body)
    ngx.exit(status)
end

local function json_str(s)
    s = tostring(s or "")
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"')
           :gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
    return '"' .. s .. '"'
end

local function err_response(code, msg)
    return string.format('{"error":%s,"message":%s}', json_str(code), json_str(msg))
end

-- Recursively serialize value to JSON
local function to_json(v)
    if v == nil then
        return "null"
    elseif type(v) == "boolean" then
        return tostring(v)
    elseif type(v) == "number" then
        return tostring(v)
    elseif type(v) == "string" then
        return json_str(v)
    elseif type(v) == "table" then
        -- Check if array-like
        local is_array = true
        local max_idx = 0
        for k, _ in pairs(v) do
            if type(k) ~= "number" or k < 1 then
                is_array = false
                break
            end
            max_idx = math.max(max_idx, k)
        end
        if is_array and max_idx > 0 then
            -- Array
            local items = {}
            for i = 1, max_idx do
                table.insert(items, to_json(v[i]))
            end
            return "[" .. table.concat(items, ",") .. "]"
        else
            -- Object
            local items = {}
            for k, v2 in pairs(v) do
                table.insert(items, string.format('%s:%s', json_str(tostring(k)), to_json(v2)))
            end
            return "{" .. table.concat(items, ",") .. "}"
        end
    else
        return json_str(tostring(v))
    end
end

local function success_response(data)
    local parts = {'"ok":true'}
    for k, v in pairs(data or {}) do
        table.insert(parts, string.format('%s:%s', json_str(k), to_json(v)))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Check if path is within webdav_root
local function is_safe_path(webdav_root, path)
    return path:sub(1, #webdav_root) == webdav_root
end

-- Get file extension (lowercase)
local function get_ext(filename)
    return (filename:match("%.([^./]+)$") or ""):lower()
end

-- Check if file is an image
local function is_image(filename)
    return IMAGE_EXTS[get_ext(filename)] == true
end

-- Check if extension is .jiff (our processed format)
local function is_jiff(filename)
    return get_ext(filename) == "jiff"
end

-- Validate directory name (Windows-compatible)
local function is_valid_dir_name(name)
    -- Check length
    if #name > MAX_DIR_NAME_LEN then
        return false, "name exceeds 38 characters"
    end
    -- Check invalid Windows characters
    if name:find('[<>:"/\\|?*]') then
        return false, "name contains invalid characters"
    end
    -- Check reserved names
    local reserved = {CON = true, PRN = true, AUX = true, NUL = true,
                      COM1 = true, COM2 = true, COM3 = true, COM4 = true,
                      COM5 = true, COM6 = true, COM7 = true, COM8 = true, COM9 = true,
                      LPT1 = true, LPT2 = true, LPT3 = true, LPT4 = true,
                      LPT5 = true, LPT6 = true, LPT7 = true, LPT8 = true, LPT9 = true}
    local base = name:match("^([^.]+)") or name
    if reserved[base:upper()] then
        return false, "name is a Windows reserved name"
    end
    -- Check for trailing spaces or dots
    if name:sub(-1):match("[. ]") then
        return false, "name cannot end with space or dot"
    end
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- File system operations
-- ─────────────────────────────────────────────────────────────────────────────

-- List directory contents
-- Returns: entries = {{name=..., is_dir=..., path=...}, ...}
local function list_dir(dir_path)
    local entries = {}
    local dp = C.opendir(dir_path)
    if dp == nil then
        return nil, "cannot open directory: " .. dir_path
    end

    local entry = C.readdir(dp)
    while entry ~= nil do
        local name = ffi.string(entry.d_name)
        if name ~= "." and name ~= ".." then
            local full_path = dir_path .. "/" .. name
            local st = stat_ffi.new()
            if stat_ffi.lstat(full_path, st) == 0 then
                table.insert(entries, {
                    name = name,
                    is_dir = stat_ffi.is_dir(st),
                    path = full_path,
                })
            end
        end
        entry = C.readdir(dp)
    end
    C.closedir(dp)
    return entries
end

-- Ensure directory exists
local function mkdir_p(path)
    local parts = {}
    for seg in path:gmatch("[^/]+") do
        parts[#parts+1] = seg
    end

    local current = ""
    for _, seg in ipairs(parts) do
        current = current .. "/" .. seg
        local st = stat_ffi.new()
        if stat_ffi.lstat(current, st) == 0 then
            if not stat_ffi.is_dir(st) then
                return false, "path component is not a directory: " .. current
            end
        else
            if C.mkdir(current, 493) ~= 0 then  -- 0755
                return false, "mkdir failed: " .. current
            end
        end
    end
    return true
end

-- Move file
local function move_file(src, dst)
    local dst_parent = dst:match("^(.*)/[^/]*$") or "/"
    local ok, err = mkdir_p(dst_parent)
    if not ok then
        return false, err
    end
    if C.rename(src, dst) ~= 0 then
        return false, "rename failed: " .. ffi.string(C.strerror(ffi.errno()))
    end
    return true
end

-- Delete empty directory
local function rmdir_if_empty(dir_path)
    local entries = list_dir(dir_path)
    if not entries then return false end
    if #entries == 0 then
        C.rmdir(dir_path)
        return true
    end
    return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Image processing
-- ─────────────────────────────────────────────────────────────────────────────

-- Process single image using imgproc
-- Returns: ok (bool), result_or_error
local function process_image(src_path, dst_path, params)
    local ext = get_ext(src_path)
    local ok, img_or_reason = imgproc.load_from_file(src_path, ext, params)
    if not ok then
        -- Animated image or load error - copy as-is
        if img_or_reason and img_or_reason:find("animated") then
            -- Copy file
            local src_f = io.open(src_path, "rb")
            if not src_f then
                return false, "cannot open source: " .. src_path
            end
            local data = src_f:read("*a")
            src_f:close()

            local dst_f = io.open(dst_path, "wb")
            if not dst_f then
                return false, "cannot create destination: " .. dst_path
            end
            dst_f:write(data)
            dst_f:close()
            return true, {skipped = true, reason = img_or_reason}
        end
        return false, img_or_reason or "load failed"
    end

    local img = img_or_reason
    local ok2, result = imgproc.process_pipeline(img, params, ext, {strip = true})
    if not ok2 then
        return false, result
    end

    -- Write output
    local dst_f = io.open(dst_path, "wb")
    if not dst_f then
        return false, "cannot create output file: " .. dst_path
    end
    dst_f:write(result.buf)
    dst_f:close()

    return true, {
        width = result.width,
        height = result.height,
        size = #result.buf,
    }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Gallerize v1 logic
-- ─────────────────────────────────────────────────────────────────────────────

-- Check if gallery is already processed
local function is_already_processed(dir_path)
    local entries = list_dir(dir_path)
    if not entries then return false end

    local has_cover = false
    local all_jiff = true
    local has_files = false

    for _, e in ipairs(entries) do
        if not e.is_dir then
            has_files = true
            local ext = get_ext(e.name)
            if ext ~= "jiff" then
                -- Check if it's an ignored/protected format
                if imgproc.PROCESSABLE_EXTS[ext] then
                    all_jiff = false
                end
            end
            if e.name == COVER_FILENAME then
                has_cover = true
            end
        end
    end

    -- Consider processed if has cover and all processable images are .jiff
    return has_files and has_cover and all_jiff
end

-- Step 1: Move non-image files to extra_file_path (only from root level)
local function move_non_images_root(root_path, extra_path, moved)
    moved = moved or {}
    local entries = list_dir(root_path)
    if not entries then return moved end

    for _, e in ipairs(entries) do
        if not e.is_dir then
            if not is_image(e.name) then
                local dst = extra_path .. "/" .. e.name
                local ok, err = move_file(e.path, dst)
                if ok then
                    table.insert(moved, {src = e.path, dst = dst})
                end
            end
        end
    end
    return moved
end

-- Move non-image files from a specific subdirectory to extra_file_path
local function move_non_images_from_dir(dir_path, extra_path, moved)
    moved = moved or {}
    local entries = list_dir(dir_path)
    if not entries then return moved end

    for _, e in ipairs(entries) do
        if not e.is_dir then
            if not is_image(e.name) then
                local dst = extra_path .. "/" .. e.name
                local ok, err = move_file(e.path, dst)
                if ok then
                    table.insert(moved, {src = e.path, dst = dst})
                end
            end
        end
    end
    return moved
end

-- Recursively move all files from nested subdirectories to the target directory
-- extra_path: where to move non-image files (optional)
-- moved_files: table to track moved non-image files
local function flatten_subdir_contents(target_dir, extra_path, moved_files)
    local entries = list_dir(target_dir)
    if not entries then return end

    for _, e in ipairs(entries) do
        if e.is_dir then
            -- Recursively process nested directory first
            flatten_subdir_contents(e.path, extra_path, moved_files)

            -- Move all files from this nested dir to target
            local sub_entries = list_dir(e.path)
            if sub_entries then
                for _, se in ipairs(sub_entries) do
                    if not se.is_dir then
                        -- Check if it's an image or non-image
                        if is_image(se.name) then
                            -- Move image to target dir
                            local dst = target_dir .. "/" .. se.name
                            -- Handle name collision
                            local counter = 1
                            local base_name = se.name:match("^(.+)%.[^.]+$") or se.name
                            local ext = get_ext(se.name)
                            local st = stat_ffi.new()
                            while stat_ffi.lstat(dst, st) == 0 do
                                dst = target_dir .. "/" .. base_name .. "_" .. counter .. "." .. ext
                                counter = counter + 1
                            end
                            move_file(se.path, dst)
                        elseif extra_path then
                            -- Move non-image to extra_path
                            local dst = extra_path .. "/" .. se.name
                            local ok, err = move_file(se.path, dst)
                            if ok then
                                table.insert(moved_files, {src = se.path, dst = dst})
                            end
                        end
                    end
                end
            end

            -- Remove empty nested directory
            rmdir_if_empty(e.path)
        end
    end
end

-- Step 2: Flatten subdirectories — move files from level-2+ to level-1, keep level-1 dirs
-- This preserves first-level subdirectories (galleries) but flattens their contents
-- Returns: list of first-level directory names, count of moved non-image files
local function flatten_directories(root_path, extra_path)
    local first_level_dirs = {}
    local moved_non_images = {}
    local entries = list_dir(root_path)
    if not entries then return first_level_dirs, moved_non_images end

    for _, e in ipairs(entries) do
        if e.is_dir then
            -- This is a first-level subdirectory (gallery)
            table.insert(first_level_dirs, e.name)
            -- Flatten its contents (move files from nested dirs to this dir)
            -- Also move non-image files to extra_path if provided
            flatten_subdir_contents(e.path, extra_path, moved_non_images)
        end
    end
    return first_level_dirs, moved_non_images
end

-- Step 3: If only one subdirectory, promote its contents
local function promote_single_subdir(root_path)
    local entries = list_dir(root_path)
    if not entries then return false end

    local subdirs = {}
    for _, e in ipairs(entries) do
        if e.is_dir then
            table.insert(subdirs, e)
        end
    end

    if #subdirs == 1 then
        local subdir = subdirs[1]
        local sub_entries = list_dir(subdir.path)
        if sub_entries then
            for _, se in ipairs(sub_entries) do
                local dst = root_path .. "/" .. se.name
                move_file(se.path, dst)
            end
        end
        rmdir_if_empty(subdir.path)
        return true, subdir.name
    end
    return false
end

-- Step 4: Validate directory names
local function validate_dir_names(root_path)
    local entries = list_dir(root_path)
    if not entries then return true end

    for _, e in ipairs(entries) do
        if e.is_dir then
            local ok, err = is_valid_dir_name(e.name)
            if not ok then
                return false, e.name .. ": " .. err
            end
        end
    end
    return true
end

-- Step 6: Generate cover image for a specific directory
local function generate_cover_for_dir(dir_path)
    local entries = list_dir(dir_path)
    if not entries then return false, "cannot list directory" end

    -- Check if cover already exists
    local cover_exists = false
    for _, e in ipairs(entries) do
        if e.name == COVER_FILENAME then
            cover_exists = true
            break
        end
    end

    if cover_exists then
        return true, {skipped = true, reason = "cover already exists"}
    end

    -- Find first image file (sorted by filename)
    local images = {}
    for _, e in ipairs(entries) do
        if not e.is_dir and is_image(e.name) then
            table.insert(images, e)
        end
    end

    if #images == 0 then
        return false, "no images found"
    end

    table.sort(images, function(a, b) return a.name < b.name end)
    local first_img = images[1]

    local cover_path = dir_path .. "/" .. COVER_FILENAME
    local params = {
        w = COVER_WIDTH,
        h = COVER_HEIGHT,
        fit = COVER_FIT,
        fmt = COVER_FMT,
        q = COVER_Q,
    }

    local ok, result = process_image(first_img.path, cover_path, params)
    if not ok then
        return false, result
    end

    return true, {
        source = first_img.name,
        cover = COVER_FILENAME,
        width = result.width,
        height = result.height,
    }
end

-- Generate covers for all first-level subdirectories
local function generate_covers(root_path, results)
    results = results or {}
    local entries = list_dir(root_path)
    if not entries then return results end

    for _, e in ipairs(entries) do
        if e.is_dir then
            local ok, result = generate_cover_for_dir(e.path)
            results[e.name] = {generated = ok, details = result}
        end
    end
    return results
end

-- Step 7: Convert all images in a directory
local function convert_images_in_dir(dir_path, params, stats)
    stats = stats or {processed = 0, skipped = 0, errors = {}}
    local entries = list_dir(dir_path)
    if not entries then return stats end

    for _, e in ipairs(entries) do
        if not e.is_dir then
            local ext = get_ext(e.name)
            if is_image(e.name) and not is_jiff(e.name) and e.name ~= COVER_FILENAME then
                local dst_name = e.name:gsub("%.[^./]+$", "") .. "." .. DEFAULT_OUT_EXT
                local dst_path = dir_path .. "/" .. dst_name

                local ok, result = process_image(e.path, dst_path, params)
                if ok then
                    if result.skipped then
                        stats.skipped = stats.skipped + 1
                    else
                        stats.processed = stats.processed + 1
                        -- Remove original after successful conversion
                        C.unlink(e.path)
                    end
                else
                    table.insert(stats.errors, {file = e.name, error = result})
                end
            end
        end
    end
    return stats
end

-- Convert images in root and all first-level subdirectories
local function convert_all_images(root_path, params, stats)
    stats = stats or {processed = 0, skipped = 0, errors = {}}

    -- Convert images in root
    convert_images_in_dir(root_path, params, stats)

    -- Convert images in each first-level subdirectory
    local entries = list_dir(root_path)
    if entries then
        for _, e in ipairs(entries) do
            if e.is_dir then
                convert_images_in_dir(e.path, params, stats)
            end
        end
    end

    return stats
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Main handler
-- ─────────────────────────────────────────────────────────────────────────────
function _M.handle(webdav_root)
    webdav_root = (webdav_root or "/webdav"):gsub("/+$", "")

    -- Only POST allowed
    if ngx.req.get_method() ~= "POST" then
        return send_json(405, err_response("method_not_allowed", "use POST"))
    end

    -- Parse JSON body
    ngx.req.read_body()
    local body = ngx.req.get_body_data() or ""
    if body == "" then
        return send_json(400, err_response("bad_request", "request body is empty"))
    end

    -- Simple JSON parsing
    local path = body:match('"path"%s*:%s*"([^"]+)"')
    local gtype = body:match('"type"%s*:%s*"([^"]+)"')
    local extra_file_path = body:match('"extra_file_path"%s*:%s*"([^"]+)"')

    -- Extract optional image params with defaults
    local w = tonumber(body:match('"w"%s*:%s*(%d+)')) or DEFAULT_WIDTH
    local h = tonumber(body:match('"h"%s*:%s*(%d+)')) or DEFAULT_HEIGHT
    local fit = body:match('"fit"%s*:%s*"([^"]+)"') or DEFAULT_FIT
    local q = tonumber(body:match('"q"%s*:%s*(%d+)')) or DEFAULT_Q

    -- Validate required fields
    if not path then
        return send_json(400, err_response("bad_request", "missing 'path' field"))
    end
    if not gtype then
        return send_json(400, err_response("bad_request", "missing 'type' field"))
    end

    -- Validate type (only v1 and v2 allowed)
    if gtype ~= "v1" and gtype ~= "v2" then
        return send_json(403, err_response("forbidden", "type must be 'v1' or 'v2'"))
    end

    -- Resolve and validate path
    if path:find("%.%.") then
        return send_json(400, err_response("bad_request", "path traversal not allowed"))
    end

    local abs_path = webdav_root .. path
    if not is_safe_path(webdav_root, abs_path) then
        return send_json(403, err_response("forbidden", "path outside webdav root"))
    end

    -- Check if directory exists
    local st = stat_ffi.new()
    if stat_ffi.lstat(abs_path, st) ~= 0 or not stat_ffi.is_dir(st) then
        return send_json(404, err_response("not_found", "directory not found: " .. path))
    end

    -- Resolve extra_file_path if provided
    local abs_extra_path = nil
    if extra_file_path then
        if extra_file_path:find("%.%.") then
            return send_json(400, err_response("bad_request", "extra_file_path traversal not allowed"))
        end
        -- Handle both absolute and relative paths
        if extra_file_path:sub(1, 1) == "/" then
            abs_extra_path = webdav_root .. extra_file_path
        else
            abs_extra_path = abs_path .. "/" .. extra_file_path
        end
        if not is_safe_path(webdav_root, abs_extra_path) then
            return send_json(403, err_response("forbidden", "extra_file_path outside webdav root"))
        end
        mkdir_p(abs_extra_path)
    end

    -- ─────────────────────────────────────────────────────────────────────────
    -- Type v1 processing
    -- ─────────────────────────────────────────────────────────────────────────
    if gtype == "v1" then
        -- Step 5: Check if already processed
        if is_already_processed(abs_path) then
            return send_json(200, success_response({
                skipped = true,
                reason = "gallery already processed"
            }))
        end

        local result = {
            path = path,
            type = gtype,
            steps = {},
        }

        -- Step 1 & 2: Flatten subdirectories (also moves non-images to extra_path if provided)
        local flattened, moved_from_subdirs = flatten_directories(abs_path, abs_extra_path)

        -- Step 1 cont: Move non-image files from root
        local moved_root = {}
        if abs_extra_path then
            moved_root = move_non_images_root(abs_path, abs_extra_path)
        end

        -- Combine moved files count
        local total_moved = #moved_root + #moved_from_subdirs
        result.steps.move_non_images = {count = total_moved}
        result.steps.flatten = {dirs = flattened}

        -- Step 3: Promote single subdirectory
        local promoted, promoted_name = promote_single_subdir(abs_path)
        result.steps.promote = {performed = promoted, dir = promoted_name}

        -- Step 4: Validate directory names
        local valid, val_err = validate_dir_names(abs_path)
        if not valid then
            return send_json(400, err_response("bad_request", "invalid directory name: " .. val_err))
        end

        -- Step 6: Generate covers for all first-level subdirectories and root
        -- After promote, we need to check if root has images (single subdir case)
        local cover_results = {}
        local root_entries = list_dir(abs_path)
        local has_subdirs = false
        if root_entries then
            for _, e in ipairs(root_entries) do
                if e.is_dir then
                    has_subdirs = true
                    break
                end
            end
        end

        if has_subdirs then
            -- Multiple subdirectories - generate cover for each
            cover_results = generate_covers(abs_path)
        else
            -- No subdirectories (single gallery promoted to root) - generate cover in root
            local ok, details = generate_cover_for_dir(abs_path)
            cover_results["."] = {generated = ok, details = details}
        end
        result.steps.covers = cover_results

        -- Step 7: Convert images in all directories
        local img_params = {
            w = w,
            h = h,
            fit = fit,
            fmt = DEFAULT_FMT,
            q = q,
        }
        local stats = convert_all_images(abs_path, img_params)
        result.steps.convert = stats

        return send_json(200, success_response(result))
    end

    -- ─────────────────────────────────────────────────────────────────────────
    -- Type v2 processing (placeholder for future)
    -- ─────────────────────────────────────────────────────────────────────────
    if gtype == "v2" then
        return send_json(200, success_response({
            path = path,
            type = gtype,
            message = "v2 processing not yet implemented"
        }))
    end
end

return _M
