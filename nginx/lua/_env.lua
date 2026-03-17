-- use this to overcome env.lua settings
return {
	auth_conf = {
        user = { 
            -- user name and password, will be override by env.OR_AUTH_USER
            -- admin2 = "admin2password", 
            -- root1 = "root1password" 
        }, 
        ip = {
            -- will be override by env.OR_AUTH_IP
            -- ["192.168.1.3"] = 1, -- auth free to access
            -- ["FE60:0:0:07C:FE:0:0:5CA8"] = 0, -- forbid to access
        },
        ua = {
            -- ['curl/8.4.0'] = 1
        }
    },

    -- ── Directory-listing cache (lua-resty-mlcache) ────────────────────────
    -- OR_LS_CACHE_TTL  : seconds a directory listing is "hot" (default 5)
    --                    Within this window all workers serve from L1/L2 memory.
    -- OR_LS_STALE_TTL  : extra seconds to keep stale data after hot TTL expires
    --                    (default 60). Stale hits return immediately and trigger
    --                    an async background refresh — zero latency for clients.
    -- OR_LS_LRU_SIZE   : max entries in each worker's L1 LRU cache (default 500)
    --                    Increase for deployments with many distinct directories.
    --
    -- Example overrides (uncomment to activate):
    -- OR_LS_CACHE_TTL = 10,    -- cache hot for 10 s instead of 5 s
    -- OR_LS_STALE_TTL = 120,   -- keep stale for 2 min instead of 1 min
    -- OR_LS_LRU_SIZE  = 1000,  -- larger per-worker LRU
    -- ──────────────────────────────────────────────────────────────────────

	_VERSION = 0.1
}