local _M = {hostname='e2b6819df96b',
SYSTEM_DNS = "192.168.1.8", NGX_CUSTOM_DNS=false,
NGX_LOG_FILE=false,
NGX_PID="e2b6819df96b.pid",
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
generated = 'Thu Aug  8 18:13:03 CST 2024'
}


local ok, patch = pcall(require, "_env") -- env.lua will be always rewrite by entrypoint.sh, using _env to overcome settings
if ok then
    for key, val in pairs(patch) do
        _M[key] = val
    end
end
return _M

