local _M = {
OR_ZIPFS_TRANSPARENT=true,
SYSTEM_DNS = "127.0.0.11", NGX_CUSTOM_DNS=false,
NGX_LOG_FILE=false,
NGX_PID="b3f7e7094a49.pid",
NGX_APP="default_app",
NGX_LOG_LEVEL="warn",
NGX_DNS="local=on valid=60s",
NGX_OVERWRITE_CONFIG=true,
NGX_WORKER="auto",
NGX_HOST="_",
NGX_CACHE_SIZE="10m",
NGX_PORT=80,
NGX_DNS_TIMEOUT=5,
INIT_AT_UTC = ngx.utctime(),
generated = 'Sat Mar 14 21:14:28 CST 2026'
}


local ok, patch = pcall(require, "_env") -- env.lua will be always rewrite by entrypoint.sh, using _env to overcome settings
if ok then
    for key, val in pairs(patch) do
        _M[key] = val
    end
end
return _M

