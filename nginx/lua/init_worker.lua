-- worker init here
-- require("resty.acme.autossl").init_worker()

-- ── Image cache GC (lib/imgcache) ────────────────────────────────────────────
-- Run purge() periodically to:
--   1. Delete expired cache files (TTL based on filename-encoded expiry epoch)
--   2. Evict LRU files when total size exceeds NGX_IMG_CACHE_MAX
-- Only run in worker 0 to avoid multiple workers competing on the same files.
-- Interval: 10 minutes (600 s) — fast enough to reclaim space, cheap enough always.
do
    local worker_id = ngx.worker.id and ngx.worker.id() or 0
    if worker_id == 0 then
        local function run_imgcache_gc(premature)
            if premature then return end
            local ok, imgcache = pcall(require, "lib.imgcache")
            if ok and imgcache then
                local pok, err = pcall(imgcache.purge)
                if not pok then
                    ngx.log(ngx.WARN, "[init_worker] imgcache.purge() error: ", err)
                end
            end
            -- Reschedule every 10 minutes
            local tok, terr = ngx.timer.at(600, run_imgcache_gc)
            if not tok then
                ngx.log(ngx.WARN, "[init_worker] imgcache GC reschedule failed: ", terr)
            end
        end
        -- First run after 60 s (let nginx warm up first)
        local tok, terr = ngx.timer.at(60, run_imgcache_gc)
        if not tok then
            ngx.log(ngx.WARN, "[init_worker] imgcache GC start failed: ", terr)
        end
    end
end

-- ── Directory-listing cache (lua-resty-mlcache) ───────────────────────────
-- Each worker must call lscache.init() to create its own mlcache instance
-- (L1 LRU is per-worker; L2 shared dict is shared across all workers).
local ok, lscache = pcall(require, "lib.lscache")
if ok and lscache then
    local init_ok, err = lscache.init()
    if not init_ok then
        ngx.log(ngx.ERR, "[init_worker] lscache.init() failed: ", err)
    end

    -- Periodically process cross-worker IPC events (set/delete broadcasts).
    -- This keeps each worker's L1 LRU in sync when another worker invalidates
    -- a cache entry (e.g. after a file upload, move, or delete).
    -- Interval: 1 second — fast enough for consistency, cheap enough to run always.
    local function run_update(premature)
        if premature then return end
        lscache.update()
        -- Reschedule
        local ok2, err2 = ngx.timer.at(1, run_update)
        if not ok2 then
            ngx.log(ngx.WARN, "[init_worker] lscache update timer reschedule failed: ", err2)
        end
    end

    local timer_ok, timer_err = ngx.timer.at(1, run_update)
    if not timer_ok then
        ngx.log(ngx.WARN, "[init_worker] lscache update timer start failed: ", timer_err)
    end
else
    ngx.log(ngx.WARN, "[init_worker] lscache module not available: ", lscache)
end
