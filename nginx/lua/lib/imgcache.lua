-- lib/imgcache.lua
-- Disk-based image cache for /img/ processed thumbnails.
--
-- Design goals:
--   1. Source-file invalidation  — cache key includes src mtime, so any
--      change to the original image automatically bypasses the old cache.
--   2. TTL-based expiry          — cache filename encodes the expiry epoch;
--      validity check is a string comparison, no extra stat needed.
--   3. Bounded disk usage        — a periodic timer purges expired files first,
--      then evicts by atime (LRU) until total size is below the configured max.
--   4. Atomic writes             — files are written to <name>.tmp then renamed,
--      preventing torn reads by concurrent workers.
--
-- Cache file naming:
--   <cache_dir>/<md5key>_<src_mtime>_<expire_epoch>.<ext>
--   e.g.  a3f8...c1_1710000000_1710172800.webp
--         ^^^^^^^^^ ^^^^^^^^^^ ^^^^^^^^^^
--         args key  src mtime  expiry (unix epoch)
--
-- Public API:
--   imgcache.get(src_path, uri, args, out_ext)
--     → data, cache_path   on HIT  (data = file bytes, cache_path for logging)
--     → nil,  nil          on MISS
--
--   imgcache.put(cache_path, data)
--     → true on success, false on error
--
--   imgcache.make_path(src_path, uri, args, out_ext)
--     → cache_path string  (the path to write to on MISS)
--
--   imgcache.purge()
--     → deletes expired files, then LRU-evicts until under max_size
--     → designed to be called from a periodic ngx.timer
--
-- Configuration (via env module):
--   NGX_IMG_CACHE_PATH     cache root dir  (default /usr/local/openresty/nginx/cache)
--   NGX_IMG_CACHE_TTL      TTL string      (default "2d",  supports Nd/Nh/Nm/N)
--   NGX_IMG_CACHE_MAX      max bytes       (default "2g",  supports Ng/Nm/Nk/N)
--   NGX_IMG_CACHE_INACTIVE inactive purge  (informational, same as TTL if unset)

local _M = { _VERSION = "1.0" }

local ngx_log  = ngx.log
local ngx_ERR  = ngx.ERR
local ngx_WARN = ngx.WARN
local ngx_INFO = ngx.INFO

-- ── Config helpers ─────────────────────────────────────────────────────────────

-- Parse "2d" / "12h" / "30m" / "3600" → seconds
local function parse_seconds(s, default)
    if not s then return default end
    s = tostring(s):lower()
    local n, unit = s:match("^(%d+%.?%d*)([dhms]?)$")
    n = tonumber(n)
    if not n then return default end
    if     unit == "d" then return math.floor(n * 86400)
    elseif unit == "h" then return math.floor(n * 3600)
    elseif unit == "m" then return math.floor(n * 60)
    else                     return math.floor(n)
    end
end

-- Parse "2g" / "500m" / "100k" / "1073741824" → bytes
local function parse_bytes(s, default)
    if not s then return default end
    s = tostring(s):lower()
    local n, unit = s:match("^(%d+%.?%d*)([gmk]?)$")
    n = tonumber(n)
    if not n then return default end
    if     unit == "g" then return math.floor(n * 1073741824)
    elseif unit == "m" then return math.floor(n * 1048576)
    elseif unit == "k" then return math.floor(n * 1024)
    else                     return math.floor(n)
    end
end

local _cfg  -- lazily initialised once per worker

local function cfg()
    if _cfg then return _cfg end
    local ok, env = pcall(require, "env")
    env = (ok and env) or {}
    local base = env.NGX_IMG_CACHE_PATH or "/usr/local/openresty/nginx/cache"
    _cfg = {
        dir      = base .. "/img",
        ttl      = parse_seconds(env.NGX_IMG_CACHE_TTL,  172800),  -- 2d
        max_size = parse_bytes  (env.NGX_IMG_CACHE_MAX,   2*1024*1024*1024),  -- 2g
    }
    return _cfg
end

-- ── Low-level file helpers ─────────────────────────────────────────────────────

local function read_file(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local data = fh:read("*a")
    fh:close()
    return data
end

-- Atomic write: write to .tmp then rename
local function write_file(path, data)
    local tmp = path .. ".tmp"
    local fh = io.open(tmp, "wb")
    if not fh then return false end
    local ok = pcall(function() fh:write(data) end)
    fh:close()
    if not ok then os.remove(tmp); return false end
    local rok = os.rename(tmp, path)
    return rok ~= nil
end

-- lfs_ffi attributes (mtime, size), returns nil on error
local _lfs
local function lfs()
    if _lfs == false then return nil end
    if _lfs then return _lfs end
    local ok, m = pcall(require, "lfs_ffi")
    if ok and m then _lfs = m; return m end
    _lfs = false
    return nil
end

local function file_attr(path, field)
    local m = lfs()
    if m then
        local v = m.attributes(path, field)
        return v
    end
    -- Fallback: existence only
    local fh = io.open(path, "rb")
    if fh then fh:close(); return (field == "modification") and os.time() or 0 end
    return nil
end

-- src file mtime as integer string; returns "0" on error (always MISS)
local function src_mtime(src_path)
    local mt = file_attr(src_path, "modification")
    return mt and tostring(math.floor(mt)) or "0"
end

-- mkdir -p (best-effort)
local function mkdir_p(path)
    os.execute("mkdir -p " .. path)
end

-- ── Cache path construction ────────────────────────────────────────────────────

-- Canonical sorted arg string for stable key
local function canonical_args(args)
    local parts = {}
    for k, v in pairs(args) do
        table.insert(parts, tostring(k) .. "=" .. tostring(v))
    end
    table.sort(parts)
    return table.concat(parts, "&")
end

-- Build the full cache file path for a given request + source file state
-- Format: <dir>/<md5>_<src_mtime>_<expire>.<ext>
function _M.make_path(src_path, uri, args, out_ext)
    local c       = cfg()
    local key     = ngx.md5(uri .. "?" .. canonical_args(args))
    local smtime  = src_mtime(src_path)
    local expire  = tostring(os.time() + c.ttl)
    local ext     = (out_ext and #out_ext > 0) and out_ext or "bin"
    -- We use a placeholder expire here; the real expire is set at write time.
    -- The caller should call make_path *after* processing (so expire is accurate),
    -- but for the HIT lookup we scan existing files by key+mtime prefix instead.
    return c.dir .. "/" .. key .. "_" .. smtime .. "_" .. expire .. "." .. ext,
           key, smtime
end

-- ── HIT lookup ────────────────────────────────────────────────────────────────
-- Scan cache_dir for files matching <key>_<smtime>_*.ext
-- Returns (data, cache_path) on HIT, (nil, nil) on MISS/expired

function _M.get(src_path, uri, args, out_ext)
    local c      = cfg()
    local key    = ngx.md5(uri .. "?" .. canonical_args(args))
    local smtime = src_mtime(src_path)
    local ext    = (out_ext and #out_ext > 0) and out_ext or "bin"
    local prefix = key .. "_" .. smtime .. "_"
    local now    = os.time()

    -- Use io.popen to list matching files (no luaposix needed)
    -- Pattern: <dir>/<prefix>*.<ext>
    local glob = c.dir .. "/" .. prefix .. "*." .. ext
    local cmd  = "ls -- " .. glob .. " 2>/dev/null"
    local fh   = io.popen(cmd, "r")
    if not fh then return nil, nil end

    local found_path = nil
    local found_expire = 0
    for line in fh:lines() do
        line = line:gsub("%s+$", "")  -- trim trailing whitespace/CR
        -- Extract expire from filename: <dir>/<key>_<mtime>_<expire>.<ext>
        local expire_s = line:match("_(%d+)%.[^/]+$")
        local expire   = tonumber(expire_s) or 0
        if expire > now then
            -- Valid (not expired yet), pick the newest expiry in case of duplicates
            if expire > found_expire then
                found_expire = expire
                found_path   = line
            end
        else
            -- Expired — delete lazily
            os.remove(line)
        end
    end
    fh:close()

    if not found_path then return nil, nil end

    local data = read_file(found_path)
    if not data then return nil, nil end

    return data, found_path
end

-- ── Write to cache ─────────────────────────────────────────────────────────────

function _M.put(src_path, uri, args, out_ext, data)
    local c      = cfg()
    local key    = ngx.md5(uri .. "?" .. canonical_args(args))
    local smtime = src_mtime(src_path)
    local expire = tostring(os.time() + c.ttl)
    local ext    = (out_ext and #out_ext > 0) and out_ext or "bin"

    mkdir_p(c.dir)

    -- Remove any old files for the same key+mtime (stale duplicates)
    local old_glob = c.dir .. "/" .. key .. "_" .. smtime .. "_*." .. ext
    local rm_fh = io.popen("ls -- " .. old_glob .. " 2>/dev/null", "r")
    if rm_fh then
        for old in rm_fh:lines() do
            old = old:gsub("%s+$", "")
            os.remove(old)
        end
        rm_fh:close()
    end

    local cache_path = c.dir .. "/" .. key .. "_" .. smtime .. "_" .. expire .. "." .. ext
    local ok = write_file(cache_path, data)
    if not ok then
        ngx_log(ngx_WARN, "[imgcache] write failed: ", cache_path)
    end
    return ok, cache_path
end

-- ── Purge / GC ────────────────────────────────────────────────────────────────
-- Called from a periodic ngx.timer (see init_worker.lua).
-- Steps:
--   1. Delete all expired files.
--   2. If total size still > max_size, delete LRU files (oldest atime first)
--      until we're back under the limit.

function _M.purge()
    local c   = cfg()
    local now = os.time()
    local dir = c.dir

    -- List all cache files
    local fh = io.popen("ls -1 " .. dir .. "/ 2>/dev/null", "r")
    if not fh then return end

    local files = {}  -- { path, size, atime, expire }
    local total_size = 0

    for name in fh:lines() do
        name = name:gsub("%s+$", "")
        -- skip .tmp files
        if not name:match("%.tmp$") then
            local path   = dir .. "/" .. name
            local expire_s = name:match("_(%d+)%.[^.]+$")
            local expire  = tonumber(expire_s) or 0
            local size    = file_attr(path, "size") or 0
            local atime   = file_attr(path, "access") or 0

            if expire > 0 and expire <= now then
                -- Expired: delete immediately
                os.remove(path)
                ngx_log(ngx_INFO, "[imgcache] purge expired: ", name)
            else
                total_size = total_size + size
                table.insert(files, { path = path, size = size, atime = atime, expire = expire })
            end
        end
    end
    fh:close()

    -- If still over limit, sort by atime ASC (oldest first) and evict
    if total_size > c.max_size then
        table.sort(files, function(a, b) return a.atime < b.atime end)
        for _, f in ipairs(files) do
            if total_size <= c.max_size then break end
            os.remove(f.path)
            total_size = total_size - f.size
            ngx_log(ngx_INFO, "[imgcache] purge LRU: ", f.path,
                    " (size=", f.size, " atime=", f.atime, ")")
        end
    end

    ngx_log(ngx_INFO, "[imgcache] purge done, remaining size=", total_size)
end

return _M
