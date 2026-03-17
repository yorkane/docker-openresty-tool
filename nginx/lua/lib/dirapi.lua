-- lib/dirapi.lua
-- Directory listing JSON API for OpenResty
--
-- Route:  GET /api/ls/<path>
--
-- The path may point to:
--   a) A real filesystem directory         → lists its direct children
--   b) A path that crosses a ZIP boundary  → lists the ZIP's internal directory
--      e.g. /api/ls/archives/book.cbz/      lists the ZIP root
--           /api/ls/archives/book.cbz/ch1/  lists the "ch1/" directory inside the ZIP
--
-- Query params:
--   page      (int ≥1, default 1)      — page number, 1-based
--   page_size (int ≥1, default 50)     — items per page, capped at OR_API_PAGE_SIZE_MAX (default 200)
--   sort      (string, default "name") — sort field: name | size | mtime | ctime | type
--   order     (string, default "asc")  — sort direction: asc | desc
--
-- Response 200 application/json:
--   {
--     "path":      "/archives",
--     "page":      1,
--     "page_size": 50,
--     "total":     123,
--     "items": [
--       { "name":"subdir",  "type":"dir",  "size":0,    "mtime":"2026-03-14T12:00:00Z", "ctime":"2026-03-14T12:00:00Z" },
--       { "name":"book.cbz","type":"zip",  "size":10240,"mtime":"2026-03-14T12:00:00Z", "ctime":"2026-03-14T12:00:00Z" },
--       { "name":"file.txt","type":"file", "size":512,  "mtime":"2026-03-14T12:00:00Z", "ctime":"2026-03-14T12:00:00Z" }
--     ]
--   }
--
-- Item "type" values:
--   "dir"  — real filesystem directory (or virtual directory inside a ZIP)
--   "zip"  — ZIP-like file (ext in OR_ZIP_EXTS) when OR_ZIPFS_TRANSPARENT is enabled
--   "file" — regular file (or zip-like when transparent is disabled)
--
-- ZIP behaviour:
--   When the request path crosses a ZIP file boundary, the ZIP's internal
--   directory is listed transparently — regardless of OR_ZIPFS_TRANSPARENT.
--   (OR_ZIPFS_TRANSPARENT only affects whether a .zip *file* shows as "zip"
--    vs "file" in a normal directory listing; once you're *inside* a ZIP the
--    API always serves the inner structure.)
--
-- Error responses: 400 | 404 | 500
--   { "error": "<code>", "message": "<detail>" }
--
-- Env vars:
--   OR_API_PAGE_SIZE_MAX  — max allowed page_size (default 200)
--   OR_ZIPFS_TRANSPARENT  — controls whether zip-exts show as "zip" (default true)
--   OR_ZIP_EXTS           — which extensions count as zip (default zip,cbz)

local _M = {}

-- ──────────────────────────────────────────────────────────
-- Cache layer (lua-resty-mlcache, stale-while-revalidate)
-- Gracefully degrades to no-cache if lscache is unavailable.
-- ──────────────────────────────────────────────────────────
local _lscache_ok, lscache = pcall(require, "lib.lscache")
if not _lscache_ok then
    ngx.log(ngx.WARN, "[dirapi] lscache unavailable: ", lscache, " — caching disabled")
    lscache = nil
end

-- ──────────────────────────────────────────────────────────
-- ZIP extension set (mirrors zipfs.lua logic, cached per worker)
-- ──────────────────────────────────────────────────────────
local _zip_exts_cache

local function get_zip_exts()
    if _zip_exts_cache then return _zip_exts_cache end
    local raw = "zip,cbz"
    local ok, env = pcall(require, "env")
    if ok and env and env.OR_ZIP_EXTS and env.OR_ZIP_EXTS ~= "" then
        raw = env.OR_ZIP_EXTS
    end
    _zip_exts_cache = {}
    for ext in raw:gmatch("[^,;%s]+") do
        _zip_exts_cache[ext:lower()] = true
    end
    return _zip_exts_cache
end

-- Find position (end index) of first zip-ext occurrence in s (case-insensitive)
-- Returns: end_pos (1-based, inclusive), or nil
local function find_zip_boundary(s)
    local exts = get_zip_exts()
    local best = nil
    for ext in pairs(exts) do
        local pat = "%." .. ext  -- simple pattern, ext has no specials
        local i, j = s:lower():find(pat)
        if i and (not best or i < best) then
            best = j
        end
    end
    return best
end

-- ──────────────────────────────────────────────────────────
-- FFI: delegate to shared stat_ffi module (arch-aware, x86_64 / aarch64).
-- stat_ffi handles dirent/opendir/closedir/stat cdef and exports helpers.
-- ──────────────────────────────────────────────────────────
local ffi      = require("ffi")
local stat_ffi = require("lib.stat_ffi")

local C        = ffi.C
local DT_REG   = 8   -- dirent d_type: regular file
local DT_DIR   = 4   -- dirent d_type: directory
local DT_LNK   = 10  -- symlink — call stat to resolve

-- ──────────────────────────────────────────────────────────
-- Config (cached per worker)
-- ──────────────────────────────────────────────────────────
local _cfg

local function cfg()
    if _cfg then return _cfg end
    local ok, env = pcall(require, "env")
    env = ok and env or {}
    local max_ps = tonumber(env.OR_API_PAGE_SIZE_MAX) or 200
    if max_ps < 1    then max_ps = 1    end
    if max_ps > 5000 then max_ps = 5000 end
    _cfg = { page_size_max = max_ps, default_page_size = 50 }
    return _cfg
end

-- ──────────────────────────────────────────────────────────
-- Tiny JSON encoder (no external deps)
-- ──────────────────────────────────────────────────────────
local function json_str(s)
    s = tostring(s or "")
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"')
           :gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t')
    return '"' .. s .. '"'
end

local function encode_items(items)
    local parts = {}
    for _, it in ipairs(items) do
        parts[#parts+1] = string.format(
            '{"name":%s,"type":%s,"size":%d,"mtime":%s,"ctime":%s}',
            json_str(it.name), json_str(it.type), it.size or 0,
            json_str(it.mtime or ""), json_str(it.ctime or "")
        )
    end
    return '[' .. table.concat(parts, ',') .. ']'
end

local function encode_ok(resp)
    return string.format(
        '{"path":%s,"page":%d,"page_size":%d,"total":%d,"sort":%s,"order":%s,"items":%s}',
        json_str(resp.path), resp.page, resp.page_size, resp.total,
        json_str(resp.sort or "name"), json_str(resp.order or "asc"),
        encode_items(resp.items)
    )
end

local function encode_err(code, msg)
    return string.format('{"error":%s,"message":%s}', json_str(code), json_str(msg))
end

-- ──────────────────────────────────────────────────────────
-- Time formatter  epoch (int) → ISO-8601 UTC string
-- ──────────────────────────────────────────────────────────
local function fmt_time(epoch)
    if not epoch or epoch == 0 then return "" end
    return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
end

-- ──────────────────────────────────────────────────────────
-- stat a single path; returns table or nil
-- Uses shared stat_ffi module (arch-aware x86_64 / aarch64)
-- ──────────────────────────────────────────────────────────
local function do_stat(path)
    return stat_ffi.stat_path(path)
end

-- ──────────────────────────────────────────────────────────
-- List the contents of a virtual directory inside a ZIP file.
--
-- zip_path : absolute filesystem path to the .zip / .cbz file
-- inner    : path inside the ZIP, "" or "subdir/nested/" (always ends with /
--            unless it is the root "")
-- Returns  : items_all (sorted), or nil + err_string
-- ──────────────────────────────────────────────────────────
local function list_zip_dir(zip_path, inner)
    -- Normalise inner prefix: must end with "/" (except for root = "")
    local prefix = inner
    if prefix ~= "" and prefix:sub(-1) ~= "/" then
        prefix = prefix .. "/"
    end

    -- Open the ZIP archive via luazip
    local ok, zf = pcall(require("zip").open, zip_path)
    if not ok or not zf then
        return nil, "cannot open zip: " .. zip_path
    end

    -- Collect all entries (flat list of full paths inside the ZIP)
    local all_entries = {}
    for e in zf:files() do
        local name = e.filename or ""
        all_entries[#all_entries+1] = {
            name = name,
            size = e.uncompressed_size or 0,
            is_dir = name:sub(-1) == "/",
        }
    end
    zf:close()

    -- Extract direct children of `prefix`
    local items = {}
    local seen  = {}
    for _, e in ipairs(all_entries) do
        local name = e.name
        -- must start with our prefix
        if name:sub(1, #prefix) == prefix then
            local rel = name:sub(#prefix + 1)
            if rel ~= "" then
                local slash = rel:find("/")
                if slash then
                    -- sub-directory (first path component before /)
                    local dname = rel:sub(1, slash - 1)
                    if dname ~= "" and not seen[dname] then
                        seen[dname] = true
                        items[#items+1] = {
                            name  = dname,
                            type  = "dir",
                            size  = 0,
                            mtime = "",
                            ctime = "",
                        }
                    end
                else
                    -- direct file inside this directory
                    items[#items+1] = {
                        name  = rel,
                        type  = "file",
                        size  = e.size,
                        mtime = "",
                        ctime = "",
                    }
                end
            end
        end
    end

    return items, nil
end

-- ──────────────────────────────────────────────────────────
-- List a real filesystem directory via FFI
-- Returns: items_all (sorted), or nil + err_string
-- ──────────────────────────────────────────────────────────
local function list_fs_dir(dir_path, zip_transparent)
    local dp = C.opendir(dir_path)
    if dp == nil then
        return nil, "cannot open directory: " .. dir_path
    end

    local ok_zf, zipfs = pcall(require, "lib.zipfs")
    local check_zip = zip_transparent and ok_zf and zipfs

    local items = {}
    local entry = C.readdir(dp)
    while entry ~= nil do
        local name = ffi.string(entry.d_name)
        if name ~= "." and name ~= ".." then
            local full = dir_path .. "/" .. name
            local attr = do_stat(full)
            if attr then
                local itype
                if attr.is_dir then
                    itype = "dir"
                elseif check_zip and zipfs.is_zip_request("/" .. name) then
                    itype = "zip"
                else
                    itype = "file"
                end
                items[#items+1] = {
                    name  = name,
                    type  = itype,
                    size  = attr.size,
                    mtime = fmt_time(attr.mtime),
                    ctime = fmt_time(attr.ctime),
                }
            end
        end
        entry = C.readdir(dp)
    end
    C.closedir(dp)

    return items, nil
end

-- ──────────────────────────────────────────────────────────
-- Sort a flat list of items.
--
-- sort  : field to sort by — "name" | "size" | "mtime" | "ctime" | "type"
--         Any unrecognised value falls back to "name".
-- order : "asc" (default) or "desc"
--
-- For the "type" field, the canonical priority order is:
--   dir < zip < file   (so dirs appear first in "asc")
-- String comparisons are case-insensitive.
-- mtime / ctime are ISO-8601 strings — lexicographic order equals time order.
-- ──────────────────────────────────────────────────────────
local _type_rank = { dir = 0, zip = 1, file = 2 }

local function sort_items(items, sort_by, order)
    -- Validate / default parameters
    local valid_fields = { name=true, size=true, mtime=true, ctime=true, type=true }
    if not valid_fields[sort_by] then sort_by = "name" end
    local descending = (order == "desc")

    table.sort(items, function(a, b)
        local less
        if sort_by == "name" then
            less = (a.name:lower() < b.name:lower())
        elseif sort_by == "size" then
            local sa = a.size or 0
            local sb = b.size or 0
            if sa ~= sb then less = (sa < sb)
            else less = (a.name:lower() < b.name:lower()) end
        elseif sort_by == "mtime" then
            local ma = a.mtime or ""
            local mb = b.mtime or ""
            if ma ~= mb then less = (ma < mb)
            else less = (a.name:lower() < b.name:lower()) end
        elseif sort_by == "ctime" then
            local ca = a.ctime or ""
            local cb = b.ctime or ""
            if ca ~= cb then less = (ca < cb)
            else less = (a.name:lower() < b.name:lower()) end
        elseif sort_by == "type" then
            local ra = _type_rank[a.type] or 2
            local rb = _type_rank[b.type] or 2
            if ra ~= rb then less = (ra < rb)
            else less = (a.name:lower() < b.name:lower()) end
        else
            less = (a.name:lower() < b.name:lower())
        end
        return descending and not less or (not descending and less)
    end)
end

-- ──────────────────────────────────────────────────────────
-- Paginate a flat list
-- ──────────────────────────────────────────────────────────
local function paginate(items, page, page_size)
    local total = #items
    local s = (page - 1) * page_size + 1
    local e = math.min(page * page_size, total)
    local slice = {}
    for i = s, e do slice[#slice+1] = items[i] end
    return slice, total
end

-- ──────────────────────────────────────────────────────────
-- HTTP helpers
-- ──────────────────────────────────────────────────────────
local function send_json(status, body)
    ngx.status = status
    ngx.header["Content-Type"]           = "application/json; charset=utf-8"
    ngx.header["Cache-Control"]          = "no-store"
    ngx.header["X-Content-Type-Options"] = "nosniff"
    ngx.print(body)
    ngx.exit(status)
end

-- ──────────────────────────────────────────────────────────
-- ──────────────────────────────────────────────────────────────────────────────
-- Cache key builder
-- Key covers: webdav_root + logical path (fs or zip+inner).
-- page / sort / order are NOT part of the key because we cache the full
-- unsorted item list and apply sorting + pagination in memory.
-- ──────────────────────────────────────────────────────────────────────────────
local function make_cache_key(webdav_root, kind, path, extra)
    -- kind: "fs" or "zip"
    -- path: absolute fs path (fs mode) or zip_path (zip mode)
    -- extra: inner zip path (zip mode) or nil
    if kind == "zip" then
        return "zip:" .. webdav_root .. ":" .. path .. ":" .. (extra or "")
    else
        return "fs:" .. path
    end
end

function _M.handle(webdav_root)
    webdav_root = (webdav_root or "/webdav"):gsub("/+$", "")

    -- parse query params
    local args      = ngx.req.get_uri_args()
    local c         = cfg()
    local page      = math.max(1, tonumber(args.page) or 1)
    local page_size = math.max(1, tonumber(args.page_size) or c.default_page_size)
    if page_size > c.page_size_max then page_size = c.page_size_max end
    local sort_by   = args.sort  or "name"
    local order     = args.order or "asc"
    if order ~= "asc" and order ~= "desc" then order = "asc" end

    -- extract relative path (strip /api/ls prefix)
    local uri      = ngx.var.uri
    local rel_path = uri:match("^/api/ls(/?.*)$") or "/"
    if rel_path == "" then rel_path = "/" end

    -- sanitise
    rel_path = rel_path:gsub("//+", "/")
    if rel_path:find("%.%.") then
        return send_json(400, encode_err("bad_request", "path traversal not allowed"))
    end

    -- strip leading slash for boundary detection (work on the bare relative path)
    local bare = rel_path:gsub("^/+", "")

    -- ── Check whether the path crosses a ZIP boundary ──────────────────────
    local zip_end = find_zip_boundary(bare)

    if zip_end then
        -- Path contains a zip-like extension.
        local zip_rel = bare:sub(1, zip_end)        -- e.g. "archives/book.cbz"
        local inner   = bare:sub(zip_end + 1):gsub("^/+", ""):gsub("/+$", "")
        local zip_path = webdav_root .. "/" .. zip_rel

        -- Verify the ZIP file actually exists on disk (stat is cheap, skip cache)
        local zip_attr = do_stat(zip_path)
        if not zip_attr then
            return send_json(404, encode_err("not_found", "zip not found"))
        end
        if zip_attr.is_dir then
            return send_json(404, encode_err("not_found", "path is a directory, not a zip file"))
        end

        -- ── Cached ZIP directory listing ────────────────────────────────────
        local cache_key = make_cache_key(webdav_root, "zip", zip_path, inner)

        local function zip_loader()
            local items, load_err = list_zip_dir(zip_path, inner)
            if not items then
                return nil, load_err or "zip listing failed"
            end
            return items
        end

        local all_items, load_err, is_stale
        if lscache then
            all_items, load_err, is_stale = lscache.get(cache_key, zip_loader)
        else
            all_items, load_err = zip_loader()
        end

        if not all_items then
            return send_json(500, encode_err("internal", load_err or "zip listing failed"))
        end

        -- Display path: /archives/book.cbz[/inner]
        local display_zip = "/" .. zip_rel
        local display = (inner == "" and display_zip or (display_zip .. "/" .. inner))

        -- Sort and paginate operate on a copy so the cached table is not mutated
        local items_copy = {}
        for i, v in ipairs(all_items) do items_copy[i] = v end
        sort_items(items_copy, sort_by, order)
        local page_items, total = paginate(items_copy, page, page_size)

        -- Expose stale status via response header (informational, not cached)
        if is_stale then
            ngx.header["X-Cache"] = "STALE"
        else
            ngx.header["X-Cache"] = "HIT"
        end

        return send_json(200, encode_ok({
            path      = display,
            page      = page,
            page_size = page_size,
            total     = total,
            sort      = sort_by,
            order     = order,
            items     = page_items,
        }))
    end

    -- ── Normal filesystem directory ─────────────────────────────────────────
    local fs_path = webdav_root .. rel_path:gsub("/+$", "")
    if fs_path == "" or fs_path == webdav_root then fs_path = webdav_root end

    -- verify it's a directory (stat is cheap, always fresh)
    local attr = do_stat(fs_path)
    if not attr then
        return send_json(404, encode_err("not_found", "path not found"))
    end
    if not attr.is_dir then
        return send_json(404, encode_err("not_found", "path is not a directory"))
    end

    -- check transparent flag (cached per worker via zipfs upvalue — no overhead)
    local ok_zf, zipfs    = pcall(require, "lib.zipfs")
    local zip_transparent = ok_zf and zipfs and zipfs.is_transparent_enabled()

    -- ── Cached filesystem directory listing ─────────────────────────────────
    local cache_key = make_cache_key(webdav_root, "fs", fs_path, nil)

    local function fs_loader()
        local items, load_err = list_fs_dir(fs_path, zip_transparent)
        if not items then
            return nil, load_err or "listing failed"
        end
        return items
    end

    local all_items, load_err, is_stale
    if lscache then
        all_items, load_err, is_stale = lscache.get(cache_key, fs_loader)
    else
        all_items, load_err = fs_loader()
    end

    if not all_items then
        return send_json(500, encode_err("internal", load_err or "listing failed"))
    end

    -- Sort and paginate on a copy (don't mutate the cached table)
    local items_copy = {}
    for i, v in ipairs(all_items) do items_copy[i] = v end
    sort_items(items_copy, sort_by, order)
    local page_items, total = paginate(items_copy, page, page_size)

    -- Expose cache status
    if is_stale then
        ngx.header["X-Cache"] = "STALE"
    elseif lscache then
        ngx.header["X-Cache"] = "HIT"
    else
        ngx.header["X-Cache"] = "MISS"
    end

    -- normalise display path
    local display = rel_path == "/" and "/" or rel_path:gsub("/+$", "")

    return send_json(200, encode_ok({
        path      = display,
        page      = page,
        page_size = page_size,
        total     = total,
        sort      = sort_by,
        order     = order,
        items     = page_items,
    }))
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Cache invalidation helpers (call after any write operation on the directory)
-- ──────────────────────────────────────────────────────────────────────────────

-- Invalidate the FS listing cache for a given directory path.
-- Pass the absolute filesystem path of the directory that changed.
function _M.invalidate_fs(webdav_root, fs_path)
    if not lscache then return end
    webdav_root = (webdav_root or "/webdav"):gsub("/+$", "")
    local key = make_cache_key(webdav_root, "fs", fs_path, nil)
    lscache.delete(key)
end

-- Invalidate a ZIP inner-directory listing.
function _M.invalidate_zip(webdav_root, zip_path, inner)
    if not lscache then return end
    webdav_root = (webdav_root or "/webdav"):gsub("/+$", "")
    local key = make_cache_key(webdav_root, "zip", zip_path, inner)
    lscache.delete(key)
end

return _M
