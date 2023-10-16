#!/bin/sh

echo 'Start initialization!'
export NGX_APP=${NGX_APP:-default_app}
export NGX_PID=${NGX_PID:-$HOSTNAME.pid}
export NGX_PORT=${NGX_PORT:-80}
export NGX_WORKER=${NGX_WORKER:-auto}
export NGX_HOST=${NGX_HOST:-_}
export NGX_LOG_FILE=${NGX_LOG_FILE:-false}
export NGX_LOG_LEVEL=${NGX_LOG_LEVEL:-warn}
export NGX_OVERWRITE_CONFIG=${NGX_OVERWRITE_CONFIG:-true}
export NGX_DNS=${NGX_DNS:-local=on valid=60s}
export NGX_DNS_TIMEOUT=${NGX_DNS_TIMEOUT:-5}
export NGX_CUSTOM_DNS=${NGX_CUSTOM_DNS:-false}
export NGX_CACHE_SIZE=${NGX_CACHE_SIZE:-10m}
export request_uri='$request_uri'
export upstream_host='$upstream_host'
export host='$host'
export uri='$uri'
export is_args='$is_args'
export args='$args'
export DOLLAR='$'

# printenv |grep -E "NGX_|OR_|OPENRESTY_"

if [ "$NGX_LOG_FILE" != "true" ]; then
	echo 'within compose export log into stdout and stderr'
	ln -sf /dev/stdout /usr/local/openresty/nginx/logs/access.log
	ln -sf /dev/stderr /usr/local/openresty/nginx/logs/error.log
fi

if [ $NGX_OVERWRITE_CONFIG == 'true' ] || [ ! -f "/usr/local/openresty/nginx/conf/nginx.conf" ]; then
	echo 'No nginx.conf found, building from environment variables'
	rm /usr/local/openresty/nginx/conf/nginx.conf -f;
	envsubst < /usr/local/openresty/nginx/conf/tpl.nginx.conf > /usr/local/openresty/nginx/conf/nginx.conf
fi



cd /usr/local/openresty/nginx/lua/
echo 'Generating /usr/local/openresty/nginx/env.lua from Environment Variables'
echo -e "local _M = {\nhostname='`hostname`'," > env.lua
echo -n 'SYSTEM_DNS = "'  >> env.lua
cat /etc/resolv.conf |grep -E "nameserver ([0-9\.]+)"|
sed -r 's/nameserver ([0-9\.]+)/\1/'| sed 'N;s/\n/,/' >> env.lua
echo -n '", ' >> env.lua
sed -i 'N;s/\n//' env.lua

printenv | grep -E "^(NGX_|OR_|OPENRESTY_)" \
| sed -r 's/((NGX|OR|OPENRESTY)_[^=]+)=(.+)/\1="\3",/' \
| sed -r 's/="([1-9]+\.?[0-9]+)"/=\1/' \
| sed -r 's/="([1-9]+)"/=\1/' \
| sed -r 's/="(true|false)"/=\1/' \
>> env.lua

echo -e "INIT_AT_UTC = ngx.utctime(),\ngenerated = '`date`'\n}\n" >> env.lua
cat env.lua
echo -e '
local ok, patch = pcall(require, "_env") -- env.lua will be always rewrite by entrypoint.sh, using _env to overcome settings
if ok then
    for key, val in pairs(patch) do
        _M[key] = val
    end
end
return _M
' >> env.lua

if [ ! -n "$1" ]; then
echo 'Starting nginx!'
nginx -g 'daemon off;'
else
exec $@
fi

echo -e 'Start failed please check config !\n====================conf/nginx.conf====================\n'
tail -n 40 /usr/local/openresty/nginx/conf/nginx.conf

exit 0