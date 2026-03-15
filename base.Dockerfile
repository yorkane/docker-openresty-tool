# Dockerfile - alpine (custom build with extra modules)
# Based on openresty/docker-openresty alpine build
# https://github.com/openresty/docker-openresty

# Build arguments with latest versions
ARG RESTY_IMAGE_BASE="alpine"
ARG RESTY_IMAGE_TAG="3.22"

# USE_CN_MIRROR=1 to switch to USTC mirror (useful for local builds in China).
# Leave empty (default) for CI / international environments.
ARG USE_CN_MIRROR=""

# OpenResty version
ARG RESTY_VERSION="1.29.2.1"

# OpenSSL 3.x (newer versions)
ARG RESTY_OPENSSL_VERSION="3.5.0"
ARG RESTY_OPENSSL_PATCH_VERSION="3.0.17"
ARG RESTY_OPENSSL_URL_BASE="https://www.openssl.org/source"

# PCRE2 (modern version)
ARG RESTY_PCRE_VERSION="10.47"
ARG RESTY_PCRE_BUILD_OPTIONS="--enable-jit"

# Parallel build
ARG RESTY_J="8"

# Custom modules
ARG NGINX_DAV_EXT_VER="4.0.1"
ARG NGINX_FANCYINDEX_VER="0.5.2"

# Export as ENV to ensure availability in RUN commands
ENV NGINX_DAV_EXT_VER=${NGINX_DAV_EXT_VER}
ENV NGINX_FANCYINDEX_VER=${NGINX_FANCYINDEX_VER}

FROM ${RESTY_IMAGE_BASE}:${RESTY_IMAGE_TAG}

# ===== Custom preconfig =====
LABEL maintainer="yorkane"
LABEL resty_version="${RESTY_VERSION}"
LABEL resty_openssl_version="${RESTY_OPENSSL_VERSION}"
LABEL resty_pcre_version="${RESTY_PCRE_VERSION}"

WORKDIR /usr/local/openresty/nginx
ENV TZ=Asia/Shanghai

# Setup timezone and basic config
RUN ln -snf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo Asia/Shanghai > /etc/timezone && \
    echo 'ls -lta "$@"' > /usr/bin/ll && chmod 755 /usr/bin/ll && \
    mkdir -p /data/cache/stale_cache/ && chmod a+rwx /data/ -R && \
    # Switch to Chinese mirror if requested
    if [ -n "${USE_CN_MIRROR}" ]; then \
        sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories; \
    fi

# ===== Build dependencies =====
# Install build tools and development libraries
RUN apk add --no-cache --virtual .build-deps \
        build-base \
        binutils \
        coreutils \
        curl \
        gd-dev \
        geoip-dev \
        libxml2-dev \
        libxslt-dev \
        linux-headers \
        make \
        perl-dev \
        readline-dev \
        zlib-dev \
        lua5.1-dev \
        gcc \
        libc-dev \
        git \
    && apk add --no-cache \
        gd \
        geoip \
        libgcc \
        libxml2 \
        libxslt \
        zlib \
        luarocks5.1 \
        tree \
        curl \
        tzdata \
        libstdc++ \
        gnu-libiconv \
        zziplib-dev \
        libarchive-tools \
        envsubst \
        vips \
        vips-dev

# Copy local lua-resty-ctxvar to build location
COPY nginx/lua/resty/ctxvar.lua /tmp/lua-resty-ctxvar/

# ===== Download and build custom nginx modules =====
WORKDIR /tmp

# Download nginx-dav-ext-module
RUN curl -fSL https://github.com/mid1221213/nginx-dav-ext-module/archive/v${NGINX_DAV_EXT_VER}.tar.gz \
    -o nginx-dav-ext-module-v${NGINX_DAV_EXT_VER}.tar.gz && \
    tar xzf nginx-dav-ext-module-v${NGINX_DAV_EXT_VER}.tar.gz

# Download ngx-fancyindex
RUN curl -fSL https://github.com/aperezdc/ngx-fancyindex/archive/v${NGINX_FANCYINDEX_VER}.tar.gz \
    -o ngx-fancyindex-v${NGINX_FANCYINDEX_VER}.tar.gz && \
    tar xzf ngx-fancyindex-v${NGINX_FANCYINDEX_VER}.tar.gz

# ===== Build OpenSSL =====
WORKDIR /tmp
RUN curl -fSL "${RESTY_OPENSSL_URL_BASE}/openssl-${RESTY_OPENSSL_VERSION}.tar.gz" -o openssl-${RESTY_OPENSSL_VERSION}.tar.gz && \
    tar xzf openssl-${RESTY_OPENSSL_VERSION}.tar.gz && \
    cd openssl-${RESTY_OPENSSL_VERSION} && \
    # Apply OpenResty patches for OpenSSL 3.x
    if [ -n "$(curl -s https://raw.githubusercontent.com/openresty/openresty/master/patches/openssl-${RESTY_OPENSSL_PATCH_VERSION}-sess_set_get_cb_yield.patch)" ]; then \
        curl -s https://raw.githubusercontent.com/openresty/openresty/master/patches/openssl-${RESTY_OPENSSL_PATCH_VERSION}-sess_set_get_cb_yield.patch | patch -p1; \
    fi && \
    ./config shared zlib -g --prefix=/usr/local/openresty/openssl3 --libdir=lib && \
    make -j${RESTY_J} && \
    make -j${RESTY_J} install_sw && \
    make clean || true

# ===== Build PCRE2 =====
WORKDIR /tmp
RUN curl -fSL "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${RESTY_PCRE_VERSION}/pcre2-${RESTY_PCRE_VERSION}.tar.gz" -o pcre2-${RESTY_PCRE_VERSION}.tar.gz && \
    tar xzf pcre2-${RESTY_PCRE_VERSION}.tar.gz && \
    cd pcre2-${RESTY_PCRE_VERSION} && \
    CFLAGS="-g -O3" ./configure --prefix=/usr/local/openresty/pcre2 --enable-utf --enable-unicode-properties --enable-jit && \
    make -j${RESTY_J} && \
    make -j${RESTY_J} install

# ===== Build OpenResty with custom modules =====
WORKDIR /tmp
RUN curl -fSL https://openresty.org/download/openresty-${RESTY_VERSION}.tar.gz -o openresty-${RESTY_VERSION}.tar.gz && \
    tar xzf openresty-${RESTY_VERSION}.tar.gz && \
    cd openresty-${RESTY_VERSION}

WORKDIR /tmp/openresty-${RESTY_VERSION}

# Configure with custom modules
RUN eval ./configure -j${RESTY_J} \
    --with-pcre=/usr/local/openresty/pcre2 \
    --with-cc-opt='-DNGX_LUA_ABORT_AT_PANIC -I/usr/local/openresty/pcre2/include -I/usr/local/openresty/openssl3/include' \
    --with-ld-opt='-L/usr/local/openresty/pcre2/lib -L/usr/local/openresty/openssl3/lib -Wl,-rpath,/usr/local/openresty/pcre2/lib:/usr/local/openresty/openssl3/lib' \
    --with-compat \
    --with-file-aio \
    --with-http_addition_module \
    --with-http_auth_request_module \
    --with-http_dav_module \
    --with-http_flv_module \
    --with-http_geoip_module=dynamic \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_image_filter_module=dynamic \
    --with-http_mp4_module \
    --with-http_random_index_module \
    --with-http_realip_module \
    --with-http_secure_link_module \
    --with-http_slice_module \
    --with-http_ssl_module \
    --with-http_stub_status_module \
    --with-http_sub_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-http_xslt_module=dynamic \
    --with-ipv6 \
    --with-mail \
    --with-mail_ssl_module \
    --with-md5-asm \
    --with-sha1-asm \
    --with-stream \
    --with-stream_ssl_module \
    --with-threads \
    --with-luajit-xcflags='-DLUAJIT_NUMMODE=2 -DLUAJIT_ENABLE_LUA52COMPAT' \
    --with-pcre-jit \
    --add-module=/tmp/nginx-dav-ext-module-${NGINX_DAV_EXT_VER} \
    --add-module=/tmp/ngx-fancyindex-${NGINX_FANCYINDEX_VER} && \
    make -j${RESTY_J} && \
    make -j${RESTY_J} install

# ===== Post-install: install LuaRocks packages =====
WORKDIR /tmp

RUN mv /usr/bin/luarocks-5.1 /usr/bin/luarocks && \
    export LUAJIT_DIR=/usr/local/openresty/luajit && \
    # Install required Lua packages
    luarocks install luasocket && \
    luarocks install luazip && \
    luarocks install lua-resty-http && \
    luarocks install lua-resty-redis-connector && \
    luarocks install lua-resty-template && \
    luarocks install lua-ffi-zlib && \
    # Download raw Lua files from GitHub
    cd /usr/local/share/lua/5.1/ && mkdir resty -p && \
    wget -q 'https://raw.githubusercontent.com/semyon422/luajit-iconv/master/init.lua' -O libiconv.lua && \
    wget -q 'https://raw.githubusercontent.com/spacewander/luafilesystem/master/lfs_ffi.lua' && \
    cd resty && \
    wget -q 'https://raw.githubusercontent.com/cloudflare/lua-resty-cookie/master/lib/resty/cookie.lua' && \
    wget -q 'https://raw.githubusercontent.com/jkeys089/lua-resty-hmac/master/lib/resty/hmac.lua' && \
    wget -q 'https://raw.githubusercontent.com/openresty/lua-resty-shell/master/lib/resty/shell.lua' && \
    # Copy local ctxvar module
    cp /tmp/lua-resty-ctxvar/ctxvar.lua /usr/local/share/lua/5.1/resty/ && \
    # Download additional Lua libraries from GitHub
    cd /tmp/ && rm -rf _tmp_ && mkdir _tmp_ && \
    curl -sLk 'https://github.com/yorkane/lua-resty-klib/archive/refs/heads/main.zip' | bsdtar -xf- -C _tmp_ && \
    mv _tmp_/*main/lib/* /usr/local/share/lua/5.1/ && \
    cd /tmp/ && rm -rf _tmp_ && mkdir _tmp_ && \
    curl -sLk 'https://github.com/openresty/lua-resty-lrucache/archive/refs/heads/master.zip' | bsdtar -xf- -C _tmp_ && \
    mv _tmp_/*master/lib/resty/* /usr/local/share/lua/5.1/ && \
    cd /tmp/ && rm -rf _tmp_ && mkdir _tmp_ && \
    curl -sLk 'https://github.com/openresty/lua-resty-string/archive/refs/heads/master.zip' | bsdtar -xf- -C _tmp_ && \
    mv _tmp_/*master/lib/resty/* /usr/local/share/lua/5.1/

# ===== Cleanup: remove build artifacts and sources =====
RUN cd /usr/local/openresty/ && rm -rf \
    luajit/lib/*.a \
    openssl3/include \
    openssl3/lib/*.a \
    openssl3/lib/engines-* \
    openssl3/lib/pkgconfig \
    openssl3/share \
    pcre2/lib/*.a \
    pcre2/share \
    pcre2/include \
    resty.index \
    pod \
    nginx/conf/*.default \
    nginx/logs/*.log \
    nginx/temp \
    site/lualib/*.ljbc \
    site/lualib/*/init.ljbc \
    lualib/cached \
    lualib/resty/*.ljbc && \
    mkdir -p /var/run/openresty && \
    # Move nginx binary to PATH
    mv /usr/local/openresty/nginx/sbin/nginx /usr/local/bin/ && \
    sed -i 's|/usr/local/openresty/nginx/sbin/nginx|/usr/local/bin/nginx|g' /usr/local/openresty/bin/resty && \
    # Copy LuaJIT headers
    mkdir -p /usr/include/ && cp /usr/local/openresty/luajit/include/luajit-2.1/*.* /usr/include/ && \
    # Create symlinks
    ln -sf /usr/local/bin/nginx /usr/local/openresty/bin/openresty && \
    ln -sf /usr/local/share/lua/5.1 /usr/local/openresty/site/lua && \
    # Clean all caches
    rm -rf /tmp/* /var/cache/luarocks /var/cache/apk /root/.cache && \
    # Delete build dependencies
    apk del .build-deps && \
    echo 'Custom OpenResty built successfully'

# ===== Environment =====
ENV PATH=$PATH:/usr/local/openresty/luajit/bin:/usr/local/openresty/bin:/usr/local/openresty/nginx/bins
ENV LUA_PATH="/usr/local/openresty/nginx/lua/?.lua;/usr/local/openresty/nginx/lua/?/init.lua;/usr/local/openresty/site/lua/?.lua;/usr/local/openresty/site/lua/?/init.lua;/usr/local/openresty/site/lualib/?.lua;/usr/local/openresty/site/lualib/?/init.lua;/usr/local/openresty/lualib/?.lua;/usr/local/openresty/lualib/?/init.lua;./?.lua;/usr/local/openresty/site/lualib/?.ljbc;/usr/local/openresty/site/lualib/?/init.ljbc;/usr/local/openresty/lualib/?.ljbc;/usr/local/openresty/lualib/?/init.ljbc;/usr/local/openresty/luajit/share/luajit-2.1/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;/usr/local/openresty/luajit/share/lua/5.1/?.lua;/usr/local/openresty/luajit/share/lua/5.1/?/init.lua;"
ENV LUA_CPATH="/usr/local/openresty/nginx/lua/?.so/usr/local/openresty/site/lualib/?.so;/usr/local/openresty/lualib/?.so;./?.so;/usr/local/lib/lua/5.1/?.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so;/usr/local/lib/lua/5.1/loadall.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so;"
ENV GID=1000
ENV UID=1000

# ===== Entrypoint =====
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]

# Use SIGQUIT for graceful shutdown
STOPSIGNAL SIGQUIT

# ===== Build usage =====
# Local build:
#   docker build -t orabase:1 -f base.Dockerfile .
#   docker build -t orabase:1 -f base.Dockerfile . --build-arg USE_CN_MIRROR=1
#
# CI build (latest from GitHub):
#   docker build -t yorkane/openresty-base:latest -f base.Dockerfile . \
#     --build-arg RESTY_VERSION=1.29.2.1 \
#     --build-arg RESTY_OPENSSL_VERSION=3.5.0 \
#     --build-arg RESTY_PCRE_VERSION=10.47
