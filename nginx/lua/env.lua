local _M = {hostname='22f9b81339e1',
SYSTEM_DNS = "127.0.0.11", NGX_CUSTOM_DNS=false,
NGX_IMG_CACHE_TTL="2d",
NGX_IMG_CACHE_INACTIVE="60d",
NGX_LOG_FILE=false,
NGX_PID="22f9b81339e1.pid",
NGX_LS_STALE_SIZE="20m",
NGX_LS_CACHE_SIZE="20m",
NGX_APP="default_app",
NGX_LOG_LEVEL="warn",
NGX_DNS="local=on valid=60s",
NGX_OVERWRITE_CONFIG=true,
NGX_IMG_CACHE_PATH="/usr/local/openresty/nginx/cache",
NGX_WORKER="auto",
NGX_HOST="_",
NGX_IMG_CACHE_MAX="2g",
NGX_CACHE_SIZE="10m",
NGX_PORT=80,
NGX_DNS_TIMEOUT=5,
INIT_AT_UTC = ngx.utctime(),
generated = 'Wed Mar 18 09:41:07 CST 2026'
}


local ok, patch = pcall(require, "_env") -- env.lua will be always rewrite by entrypoint.sh, using _env to overcome settings
if ok then
    for key, val in pairs(patch) do
        _M[key] = val
    end
end
return _M

