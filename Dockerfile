# Dockerfile - docker-openresty-tool
# Builds on top of yorkane/openresty-base (pre-compiled OpenResty + LuaRocks)
# Adds: project-specific Lua libraries, nginx config, vips support

ARG BASE_IMAGE="ghcr.io/yorkane/openresty-base:latest"
FROM ${BASE_IMAGE}

LABEL maintainer="yorkane"

# USE_CN_MIRROR=1 to switch to USTC mirror for local builds in China
ARG USE_CN_MIRROR=""

ENV TZ=Asia/Shanghai \
    GID=1000 \
    UID=1000

# Extend LUA_PATH to include project nginx lua dir
ENV LUA_PATH="/usr/local/openresty/nginx/lua/?.lua;/usr/local/openresty/nginx/lua/?/init.lua;${LUA_PATH}" \
    LUA_CPATH="/usr/local/openresty/nginx/lua/?.so;${LUA_CPATH}"

# Copy local ctxvar module for installation
COPY nginx/lua/resty/ctxvar.lua /tmp/lua-resty-ctxvar/

# Install extra Lua libraries and runtime deps on top of the base image
RUN set -eux \
    # Optional: switch to CN mirror
    && if [ -n "${USE_CN_MIRROR}" ]; then \
        sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories; \
    fi \
    # Timezone & convenience alias
    && ln -snf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo Asia/Shanghai > /etc/timezone \
    && echo 'ls -lta "$@"' > /usr/bin/ll && chmod 755 /usr/bin/ll \
    # Data dir
    && mkdir -p /data/cache/stale_cache/ && chmod a+rwx /data/ -R \
    \
    # Runtime packages not in base image
    && apk add --no-cache \
        gnu-libiconv \
        libarchive-tools \
        zziplib-dev \
        vips \
    \
    # Build deps only needed for lua-vips compilation
    && apk add --no-cache --virtual .build-deps \
        vips-dev \
        git \
    \
    # Install LuaRocks packages via base image's luarocks
    && luarocks install luasocket \
    && luarocks install luazip \
    && luarocks install lua-resty-http \
    && luarocks install lua-resty-redis-connector \
    && luarocks install lua-resty-template \
    && luarocks install lua-ffi-zlib \
    && luarocks config rocks_provided.luaffi-tkl "2.1-1" \
    && luarocks install lua-vips \
    \
    # Download raw Lua files
    && cd /usr/local/share/lua/5.1/ \
    && wget -q 'https://raw.githubusercontent.com/semyon422/luajit-iconv/master/init.lua' -O libiconv.lua \
    && wget -q 'https://raw.githubusercontent.com/spacewander/luafilesystem/master/lfs_ffi.lua' \
    && mkdir -p resty && cd resty \
    && wget -q 'https://raw.githubusercontent.com/cloudflare/lua-resty-cookie/master/lib/resty/cookie.lua' \
    && wget -q 'https://raw.githubusercontent.com/jkeys089/lua-resty-hmac/master/lib/resty/hmac.lua' \
    && cp /tmp/lua-resty-ctxvar/ctxvar.lua . \
    \
    # Download lua-resty-klib (yorkane's custom lib)
    && cd /tmp && rm -rf _tmp_ && mkdir _tmp_ \
    && wget -qO- 'https://github.com/yorkane/lua-resty-klib/archive/refs/heads/main.tar.gz' \
        | tar xz -C _tmp_ --strip-components=2 --wildcards '*/lib/*' \
    && cp -r _tmp_/* /usr/local/share/lua/5.1/ \
    \
    # Cleanup
    && apk del .build-deps \
    && rm -rf /tmp/* /var/cache/apk /root/.cache \
    && echo 'docker-openresty-tool layer built successfully'

# Copy nginx config files (overrides base image's default nginx config)
COPY ./nginx/ /usr/local/openresty/nginx/

# Fix permissions
RUN chmod a+x /usr/local/openresty/nginx/lua/ -R \
    && chmod a+x /usr/local/openresty/nginx/bins/ -R \
    && chmod 755 /usr/local/openresty/nginx/conf/*.sh

WORKDIR /usr/local/openresty/nginx

ENTRYPOINT ["/usr/local/openresty/nginx/conf/entrypoint.sh"]

STOPSIGNAL SIGQUIT

# ===== Build usage =====
# Local build (uses ghcr.io/yorkane/openresty-base:latest):
#   docker build -t yorkane/docker-openresty-tool:latest .
#   docker build -t yorkane/docker-openresty-tool:latest . --build-arg USE_CN_MIRROR=1
#
# Point to a specific base image:
#   docker build -t yorkane/docker-openresty-tool:latest . \
#     --build-arg BASE_IMAGE=ghcr.io/yorkane/openresty-base:sha-abc1234
#
# Save/load:
#   docker save yorkane/docker-openresty-tool:latest | xz > yot.tar.xz -v -T4
#   xz -d -k < yot.tar.xz | docker load
#
# Run:
#   docker run --rm -p 8888:80 -it -v /data:/webdav --name dot yorkane/docker-openresty-tool:latest sh
#   docker run --rm -p 8888:80 -e GID=1000 -e UID=1000 -it -v /data:/webdav \
#     -v /code/docker-openresty-tool/nginx:/usr/local/openresty/nginx \
#     --name dot yorkane/docker-openresty-tool:latest sh
