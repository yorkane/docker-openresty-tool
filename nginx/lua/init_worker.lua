-- worker init here
-- require("resty.acme.autossl").init_worker()

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
