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
-- FFI: opendir / readdir / closedir / stat (musl libc, aarch64/x86_64)
-- ──────────────────────────────────────────────────────────
local ffi = require("ffi")

-- Avoid duplicate cdef across hot-reloads
if not pcall(function() return ffi.sizeof("dirent_t") end) then
    ffi.cdef[[
    typedef void DIR;
    typedef struct {
        unsigned long  d_ino;
        long           d_off;
        unsigned short d_reclen;
        unsigned char  d_type;
        char           d_name[256];
    } dirent_t;
    DIR*      opendir(const char *name);
    dirent_t *readdir(DIR *dp);
    int       closedir(DIR *dp);

    /* Linux asm-generic/stat.h (aarch64) — kernel stat struct
       struct stat {
         ulong dev; ulong ino; uint mode; uint nlink; uint uid; uint gid;
         ulong rdev; ulong __pad1; long size; int blksize; int __pad2;
         long blocks; long atime; ulong atime_nsec;
         long mtime; ulong mtime_nsec; long ctime; ulong ctime_nsec; uint[2] __unused;
       }
       Offsets: rdev=32 __pad1=40 size=48 blksize=56 __pad2=60 blocks=64
                atime=72 atime_ns=80 mtime=88 mtime_ns=96 ctime=104 ctime_ns=112
    */
    struct stat_t {
        unsigned long  st_dev;        /* 0  */
        unsigned long  st_ino;        /* 8  */
        unsigned int   st_mode;       /* 16 */
        unsigned int   st_nlink;      /* 20 */
        unsigned int   st_uid;        /* 24 */
        unsigned int   st_gid;        /* 28 */
        unsigned long  st_rdev;       /* 32 */
        unsigned long  __pad1;        /* 40 */
        long           st_size;       /* 48 */
        int            st_blksize;    /* 56 */
        int            __pad2;        /* 60 */
        long           st_blocks;     /* 64 */
        long           st_atime;      /* 72 */
        unsigned long  st_atime_nsec; /* 80 */
        long           st_mtime;      /* 88 */
        unsigned long  st_mtime_nsec; /* 96 */
        long           st_ctime;      /* 104 */
        unsigned long  st_ctime_nsec; /* 112 */
        unsigned int   __unused[2];   /* 120 */
    };
    int stat(const char *path, struct stat_t *buf);
    ]]
end

local C        = ffi.C
local DT_REG   = 8   -- dirent d_type: regular file
local DT_DIR   = 4   -- dirent d_type: directory
local DT_LNK   = 10  -- symlink — call stat to resolve
local S_IFMT   = 0xF000
local S_IFDIR  = 0x4000

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
-- ──────────────────────────────────────────────────────────
local function do_stat(path)
    local st = ffi.new("struct stat_t")
    if C.stat(path, st) ~= 0 then return nil end
    return {
        size  = tonumber(st.st_size),
        mtime = tonumber(st.st_mtime),
        ctime = tonumber(st.st_ctime),
        mode  = tonumber(st.st_mode),
        is_dir = bit.band(tonumber(st.st_mode), S_IFMT) == S_IFDIR,
    }
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
-- Main handler
-- ──────────────────────────────────────────────────────────
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
    -- e.g. bare = "archives/book.cbz/ch1/page01.html"
    --      zip_end = position of the last char of ".cbz"
    --      zip_rel = "archives/book.cbz"
    --      inner   = "ch1/page01.html"
    local zip_end = find_zip_boundary(bare)

    if zip_end then
        -- Path contains a zip-like extension.
        -- Split into: filesystem part up to & including the zip file,
        -- and the inner path inside the ZIP.
        local zip_rel = bare:sub(1, zip_end)        -- e.g. "archives/book.cbz"
        local inner   = bare:sub(zip_end + 1):gsub("^/+", ""):gsub("/+$", "")
        -- inner: "" means ZIP root, "ch1" means subdir "ch1/"

        local zip_path = webdav_root .. "/" .. zip_rel

        -- Verify the ZIP file actually exists on disk
        local zip_attr = do_stat(zip_path)
        if not zip_attr then
            return send_json(404, encode_err("not_found", "zip not found"))
        end
        if zip_attr.is_dir then
            -- The extension matched something that turned out to be a directory
            -- (e.g. a folder literally named "foo.zip" — unlikely, fall through)
            return send_json(404, encode_err("not_found", "path is a directory, not a zip file"))
        end

        -- List the ZIP's inner directory
        local all_items, err = list_zip_dir(zip_path, inner)
        if not all_items then
            return send_json(500, encode_err("internal", err or "zip listing failed"))
        end

        -- Display path: /archives/book.cbz[/inner]
        local display_zip = "/" .. zip_rel
        local display = (inner == "" and display_zip or (display_zip .. "/" .. inner))

        sort_items(all_items, sort_by, order)
        local page_items, total = paginate(all_items, page, page_size)
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

    -- verify it's a directory
    local attr = do_stat(fs_path)
    if not attr then
        return send_json(404, encode_err("not_found", "path not found"))
    end
    if not attr.is_dir then
        return send_json(404, encode_err("not_found", "path is not a directory"))
    end

    -- check transparent flag
    local ok_zf, zipfs   = pcall(require, "lib.zipfs")
    local zip_transparent = ok_zf and zipfs and zipfs.is_transparent_enabled()

    -- list directory
    local all_items, err = list_fs_dir(fs_path, zip_transparent)
    if not all_items then
        return send_json(500, encode_err("internal", err or "listing failed"))
    end

    -- sort, then paginate
    sort_items(all_items, sort_by, order)
    local page_items, total = paginate(all_items, page, page_size)

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

return _M
