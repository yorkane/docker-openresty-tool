-- lib/lscache.lua
-- Directory-listing cache built on lua-resty-mlcache.
--
-- Strategy: Stale-While-Revalidate (SWR)
-- ─────────────────────────────────────
--   Each cached entry contains the directory items PLUS a `_born` timestamp.
--
--   mlcache TTL is set to  hot_ttl + stale_ttl  (e.g. 5 + 60 = 65 s).
--   The entry therefore stays in L2 (shared dict) for the full 65 s window.
--
--   On every get():
--     age = now - entry._born
--     if age <= hot_ttl  → fresh hit, return immediately
--     if age <= hot_ttl + stale_ttl → stale hit:
--         1. Return the stale data immediately (zero client latency)
--         2. Schedule a one-shot timer (ngx.timer.at(0, ...)) that:
--            a. calls mlcache:delete(key) to evict the old entry
--            b. calls mlcache:get(key, ...) to reload from disk
--            This reload is protected by mlcache's built-in shm-level lock
--            so only ONE worker runs the loader even with 4+ workers racing.
--
-- Multi-worker safety:
--   • L2 (lua_shared_dict ls_cache) is shared across all workers.
--   • mlcache's shm lock prevents parallel disk reads for the same key.
--   • The per-worker `_refreshing` table prevents the same worker from
--     scheduling duplicate background timers for the same key.
--   • ipc_shm (ls_cache_ipc) lets delete() / set() broadcast L1 evictions
--     to all other workers so their LRU caches stay consistent.
--
-- Required lua_shared_dict declarations (nginx.conf / tpl.nginx.conf):
--   lua_shared_dict ls_cache      20m;   -- L2 hot + stale data
--   lua_shared_dict ls_cache_ipc   1m;   -- cross-worker IPC events
--
-- Public API:
--   lscache.init()               — call once per worker in init_worker_by_lua_block
--   lscache.get(key, loader_fn)  — returns value, err, is_stale
--   lscache.delete(key)          — invalidate one key (call after write ops)
--   lscache.flush_all()          — purge everything
--   lscache.update()             — process cross-worker IPC events (called by timer)

local mlcache = require("resty.mlcache")

local ngx        = ngx
local ngx_log    = ngx.log
local ngx_WARN   = ngx.WARN
local ngx_ERR    = ngx.ERR
local ngx_timer  = ngx.timer.at
local ngx_now    = ngx.now

local _M = { _VERSION = "1.1" }

-- ──────────────────────────────────────────────────────────────────────────────
-- Configuration  (resolved once at first use, cached per worker)
-- ──────────────────────────────────────────────────────────────────────────────
local _cfg

local function get_cfg()
    if _cfg then return _cfg end
    local ok, env = pcall(require, "env")
    env = (ok and env) or {}

    local hot_ttl   = tonumber(env.OR_LS_CACHE_TTL) or 5    -- fresh window (s)
    local stale_ttl = tonumber(env.OR_LS_STALE_TTL) or 60   -- stale window (s)
    if hot_ttl   < 1 then hot_ttl   = 1  end
    if stale_ttl < 0 then stale_ttl = 0  end

    _cfg = {
        hot_ttl    = hot_ttl,
        stale_ttl  = stale_ttl,
        total_ttl  = hot_ttl + stale_ttl,   -- mlcache TTL
        lru_size   = tonumber(env.OR_LS_LRU_SIZE) or 500,
        shm        = "ls_cache",
        shm_ipc    = "ls_cache_ipc",
    }
    return _cfg
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Module-level state (one mlcache instance per worker, plus in-flight guard)
-- ──────────────────────────────────────────────────────────────────────────────
local _cache      -- mlcache instance
local _refreshing = {}   -- keys currently being refreshed by a bg timer

-- ──────────────────────────────────────────────────────────────────────────────
-- Public: init()   — call from init_worker_by_lua_block
-- ──────────────────────────────────────────────────────────────────────────────
function _M.init()
    local c = get_cfg()

    local cache, err = mlcache.new("ls_cache", c.shm, {
        lru_size      = c.lru_size,
        ttl           = c.total_ttl,   -- entry lives for hot_ttl + stale_ttl
        neg_ttl       = 2,             -- cache nil/not-found for 2 s
        resurrect_ttl = c.hot_ttl,     -- if L3 errors, serve stale for hot_ttl s
        ipc_shm       = c.shm_ipc,
    })
    if not cache then
        ngx_log(ngx_ERR, "[lscache] mlcache.new() failed: ", err)
        return nil, err
    end

    _cache = cache
    return true
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Internal: wrap a user loader so the returned value carries a _born timestamp.
-- The timestamp is used later to decide fresh vs stale without extra shm round-trips.
-- ──────────────────────────────────────────────────────────────────────────────
local function wrap_loader(loader_fn)
    return function()
        local items, err = loader_fn()
        if err then
            return nil, err
        end
        if items == nil then
            return nil   -- mlcache will cache nil with neg_ttl
        end
        -- Embed birth time so we can age-check without querying the shm TTL
        return { _born = ngx_now(), items = items }
    end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Internal: background refresh timer
-- ──────────────────────────────────────────────────────────────────────────────
local function do_bg_refresh(premature, key, loader_fn)
    if premature then
        _refreshing[key] = nil
        return
    end

    if not _cache then
        _refreshing[key] = nil
        return
    end

    local c = get_cfg()

    -- Delete the stale entry from L2 (+ broadcasts L1 eviction to all workers).
    -- After delete, the next get() will re-run the loader and populate a fresh entry.
    _cache:delete(key)

    -- Re-populate; mlcache lock ensures only this timer (or one winner) does the I/O.
    local wrapped = wrap_loader(loader_fn)
    local entry, load_err = _cache:get(key, { ttl = c.total_ttl }, wrapped)
    if load_err then
        ngx_log(ngx_WARN, "[lscache] bg refresh error for '", key, "': ", load_err)
    elseif not entry then
        ngx_log(ngx_WARN, "[lscache] bg refresh returned nil for '", key, "'")
    end

    _refreshing[key] = nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Public: get(key, loader_fn)
--
-- Returns: value, err, is_stale
--   value    — the raw items table (not the envelope; _born is stripped)
--   err      — error string (nil on success)
--   is_stale — true when the returned data is past its hot TTL
-- ──────────────────────────────────────────────────────────────────────────────
function _M.get(key, loader_fn)
    if not _cache then
        -- Cache not initialised (init_worker wasn't called) — fall through to disk
        ngx_log(ngx_WARN, "[lscache] CACHE NOT INITIALIZED: key=", key)
        local v, e = loader_fn()
        return v, e, false
    end

    local c       = get_cfg()
    local wrapped = wrap_loader(loader_fn)

    local entry, err = _cache:get(key, { ttl = c.total_ttl }, wrapped)

    if err then
        ngx_log(ngx_WARN, "[lscache] get error for '", key, "': ", err)
        return nil, err, false
    end

    if entry == nil then
        -- Loader returned nil (e.g. empty listing or not-found during refresh)
        ngx_log(ngx_WARN, "[lscache] MISS: key=", key)
        return nil, nil, false
    end

    -- Compute entry age
    local age = ngx_now() - (entry._born or 0)

    if age <= c.hot_ttl then
        -- ── Fresh hit ────────────────────────────────────────────────────────
        ngx_log(ngx_WARN, "[lscache] FRESH HIT: key=", key, " age=", age, "s")
        return entry.items, nil, false
    end

    -- ── Stale hit ────────────────────────────────────────────────────────────
    -- Data is past hot_ttl but still within total_ttl (mlcache hasn't evicted it).
    -- Return it immediately and schedule one background refresh.
    ngx_log(ngx_WARN, "[lscache] STALE HIT: key=", key, " age=", age, "s")
    if not _refreshing[key] then
        _refreshing[key] = true
        local tok, terr = ngx_timer(0, do_bg_refresh, key, loader_fn)
        if not tok then
            ngx_log(ngx_WARN, "[lscache] timer spawn failed for '", key, "': ", terr)
            _refreshing[key] = nil
        end
    end

    return entry.items, nil, true
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Public: delete(key) — hard invalidation (e.g. after upload / rm / mkdir)
-- Broadcasts the eviction to all workers via IPC so their L1 LRUs are cleared.
-- ──────────────────────────────────────────────────────────────────────────────
function _M.delete(key)
    if _cache then
        local ok, err = _cache:delete(key)
        if not ok then
            ngx_log(ngx_WARN, "[lscache] delete error for '", key, "': ", err)
        end
    end
    _refreshing[key] = nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Public: flush_all() — nuke everything (e.g. after bulk import / full rescan)
-- ──────────────────────────────────────────────────────────────────────────────
function _M.flush_all()
    if _cache then
        _cache:purge(true)   -- true = broadcast purge to all workers
    end
    _refreshing = {}
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Public: update() — drain the cross-worker IPC event queue.
-- Must be called periodically (e.g. every 1 s from a recurring timer) so that
-- delete() / purge() calls in one worker propagate to L1 caches in all others.
-- ──────────────────────────────────────────────────────────────────────────────
function _M.update()
    if not _cache then return end
    local ok, err = _cache:update()
    if not ok then
        ngx_log(ngx_WARN, "[lscache] update() error: ", err)
    end
end

return _M
