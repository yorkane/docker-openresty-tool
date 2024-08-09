# Dockerfile - alpine
# https://github.com/openresty/docker-openresty

ARG RESTY_IMAGE_BASE="alpine"
ARG RESTY_IMAGE_TAG="3.20"

FROM ${RESTY_IMAGE_BASE}:${RESTY_IMAGE_TAG}

# Custom preconfig Start
WORKDIR /usr/local/openresty/nginx
ENV TZ=Asia/Shanghai
ARG NGINX_DAV_EXT_VER="4.0.1"
ARG NGINX_FANCYINDEX_VER="0.5.2"
RUN ln -snf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && echo Asia/Shanghai > /etc/timezone &&\
	echo 'ls -lta "$@"' > /usr/bin/ll && chmod 755 /usr/bin/ll &&\
	mkdir -p /data/cache/stale_cache/ && chmod a+rwx /data/ -R &&\
	sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories
# Custom preconfig End

# Docker Build Arguments
ARG RESTY_IMAGE_BASE="alpine"
ARG RESTY_IMAGE_TAG="3.20"
ARG RESTY_VERSION="1.25.3.2"
ARG RESTY_OPENSSL_VERSION="1.1.1w"
ARG RESTY_OPENSSL_PATCH_VERSION="1.1.1f"
ARG RESTY_OPENSSL_URL_BASE="https://www.openssl.org/source/old/1.1.1"
ARG RESTY_PCRE_VERSION="8.45"
ARG RESTY_PCRE_BUILD_OPTIONS="--enable-jit"
ARG RESTY_PCRE_SHA256="4e6ce03e0336e8b4a3d6c2b70b1c5e18590a5673a98186da90d4f33c23defc09"
ARG RESTY_J="8"
ARG RESTY_CONFIG_OPTIONS="\
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
    "

# Custom config Start
ARG RESTY_CONFIG_OPTIONS_MORE=" --add-module=/tmp/nginx-dav-ext-module-${NGINX_DAV_EXT_VER} \
  --add-module=/tmp/ngx-fancyindex-${NGINX_FANCYINDEX_VER}"
ARG RESTY_LUAJIT_OPTIONS="--with-luajit-xcflags='-DLUAJIT_NUMMODE=2 -DLUAJIT_ENABLE_LUA52COMPAT'"
ARG RESTY_PCRE_OPTIONS="--with-pcre-jit"

ARG RESTY_ADD_PACKAGE_BUILDDEPS="lua5.1-dev gcc libc-dev make"
ARG RESTY_ADD_PACKAGE_RUNDEPS="luarocks5.1 tree curl tzdata libstdc++ gnu-libiconv zziplib-dev libarchive-tools envsubst"
ARG RESTY_EVAL_PRE_CONFIGURE="mv /usr/bin/luarocks-5.1  /usr/bin/luarocks && \
export LUAJIT_DIR=/usr/local/openresty/luajit  && \
luarocks install luasocket && \
luarocks install luazip && \
cd /tmp/ && wget https://github.com/mid1221213/nginx-dav-ext-module/archive/v${NGINX_DAV_EXT_VER}.tar.gz \
    -O /tmp/nginx-dav-ext-module-v${NGINX_DAV_EXT_VER}.tar.gz && \
  wget https://github.com/aperezdc/ngx-fancyindex/archive/v${NGINX_FANCYINDEX_VER}.tar.gz \
    -O /tmp/ngx-fancyindex-v${NGINX_FANCYINDEX_VER}.tar.gz && ls *.gz | xargs -n1 tar -xzf"
ARG RESTY_EVAL_POST_DOWNLOAD_PRE_CONFIGURE=""
ARG RESTY_EVAL_POST_MAKE="rm -rf /tmp/* && \
luarocks install lua-resty-http && luarocks install lua-resty-redis-connector && luarocks install lua-resty-template && luarocks install lua-ffi-zlib &&\
    cd /usr/local/share/lua/5.1/ && mkdir resty -p && \
	wget 'https://raw.githubusercontent.com/semyon422/luajit-iconv/master/init.lua' -O libiconv.lua && \
	wget 'https://raw.githubusercontent.com/spacewander/luafilesystem/master/lfs_ffi.lua' && \
	cd resty && \
	wget 'https://raw.githubusercontent.com/cloudflare/lua-resty-cookie/master/lib/resty/cookie.lua' && \
	wget 'https://raw.githubusercontent.com/jkeys089/lua-resty-hmac/master/lib/resty/hmac.lua'  && \
	wget 'https://raw.githubusercontent.com/openresty/lua-resty-shell/master/lib/resty/shell.lua' && \
	wget 'https://raw.githubusercontent.com/yorkane/lua-resty-ctxvar/main/lib/resty/ctxvar.lua' && \
    cd /tmp/ && rm _tmp_ -rf && mkdir _tmp_ && curl -Lk 'https://github.com/yorkane/lua-resty-klib/archive/refs/heads/main.zip' | bsdtar -xkf- -C _tmp_ && tree && mv _tmp_/*main/lib/* /usr/local/share/lua/5.1/ &&\
    cd /tmp/ && rm _tmp_ -rf && mkdir _tmp_ && curl -Lk 'https://github.com/openresty/lua-resty-lrucache/archive/refs/heads/master.zip' | bsdtar -xkf- -C _tmp_ && tree && mv _tmp_/*master/lib/resty/* /usr/local/share/lua/5.1/ &&\
    cd /tmp/ && rm _tmp_ -rf && mkdir _tmp_ && curl -Lk 'https://github.com/openresty/lua-resty-string/archive/refs/heads/master.zip' | bsdtar -xkf- -C _tmp_ && tree && mv _tmp_/*master/lib/resty/* /usr/local/share/lua/5.1/ &&\
cd /usr/local/openresty/ && rm -rf luajit/lib/*.a openssl/include openssl/lib/*.a pcre/lib/*.a pcre/share resty.index pod nginx/conf/*.default &&\
mv /usr/local/openresty/nginx/sbin/nginx /usr/local/bin/ &&\
sed -i 's@/usr/local/openresty/nginx/sbin/nginx@/usr/local/bin/nginx@' /usr/local/openresty/bin/resty &&\
mkdir /usr/include/ -p && cp /usr/local/openresty/luajit/include/luajit-2.1/*.* /usr/include/ &&\
ln -sf /usr/local/bin/nginx /usr/local/openresty/bin/openresty &&\
ln -sf /usr/local/share/lua/5.1 /usr/local/openresty/site/lua &&\
rm -rf /tmp/* /var/cache/luarocks &&\
echo 'Custom module installed'"
# Custom config End


# These are not intended to be user-specified
ARG _RESTY_CONFIG_DEPS="--with-pcre \
    --with-cc-opt='-DNGX_LUA_ABORT_AT_PANIC -I/usr/local/openresty/pcre/include -I/usr/local/openresty/openssl/include' \
    --with-ld-opt='-L/usr/local/openresty/pcre/lib -L/usr/local/openresty/openssl/lib -Wl,-rpath,/usr/local/openresty/pcre/lib:/usr/local/openresty/openssl/lib' \
    "

LABEL resty_image_base="${RESTY_IMAGE_BASE}"
LABEL resty_image_tag="${RESTY_IMAGE_TAG}"
LABEL resty_version="${RESTY_VERSION}"
LABEL resty_openssl_version="${RESTY_OPENSSL_VERSION}"
LABEL resty_openssl_patch_version="${RESTY_OPENSSL_PATCH_VERSION}"
LABEL resty_openssl_url_base="${RESTY_OPENSSL_URL_BASE}"
LABEL resty_pcre_version="${RESTY_PCRE_VERSION}"
LABEL resty_pcre_build_options="${RESTY_PCRE_BUILD_OPTIONS}"
LABEL resty_pcre_sha256="${RESTY_PCRE_SHA256}"
LABEL resty_config_options="${RESTY_CONFIG_OPTIONS}"
LABEL resty_config_options_more="${RESTY_CONFIG_OPTIONS_MORE}"
LABEL resty_config_deps="${_RESTY_CONFIG_DEPS}"
LABEL resty_add_package_builddeps="${RESTY_ADD_PACKAGE_BUILDDEPS}"
LABEL resty_add_package_rundeps="${RESTY_ADD_PACKAGE_RUNDEPS}"
LABEL resty_eval_pre_configure="${RESTY_EVAL_PRE_CONFIGURE}"
LABEL resty_eval_post_download_pre_configure="${RESTY_EVAL_POST_DOWNLOAD_PRE_CONFIGURE}"
LABEL resty_eval_post_make="${RESTY_EVAL_POST_MAKE}"
LABEL resty_luajit_options="${RESTY_LUAJIT_OPTIONS}"
LABEL resty_pcre_options="${RESTY_PCRE_OPTIONS}"

RUN apk add --no-cache --virtual .build-deps \
        build-base \
        coreutils \
        curl \
        gd-dev \
        geoip-dev \
        libxslt-dev \
        linux-headers \
        make \
        perl-dev \
        readline-dev \
        zlib-dev \
        ${RESTY_ADD_PACKAGE_BUILDDEPS} \
    && apk add --no-cache \
        gd \
        geoip \
        libgcc \
        libxslt \
        zlib \
        ${RESTY_ADD_PACKAGE_RUNDEPS} \
    && cd /tmp \
    && if [ -n "${RESTY_EVAL_PRE_CONFIGURE}" ]; then eval $(echo ${RESTY_EVAL_PRE_CONFIGURE}); fi \
    && cd /tmp \
    && echo curl -fSL "${RESTY_OPENSSL_URL_BASE}/openssl-${RESTY_OPENSSL_VERSION}.tar.gz" -o openssl-${RESTY_OPENSSL_VERSION}.tar.gz \
    && curl -fSL "${RESTY_OPENSSL_URL_BASE}/openssl-${RESTY_OPENSSL_VERSION}.tar.gz" -o openssl-${RESTY_OPENSSL_VERSION}.tar.gz \
    && tar xzf openssl-${RESTY_OPENSSL_VERSION}.tar.gz \
    && cd openssl-${RESTY_OPENSSL_VERSION} \
    && if [ $(echo ${RESTY_OPENSSL_VERSION} | cut -c 1-5) = "1.1.1" ] ; then \
        echo 'patching OpenSSL 1.1.1 for OpenResty' \
        && curl -s https://raw.githubusercontent.com/openresty/openresty/master/patches/openssl-${RESTY_OPENSSL_PATCH_VERSION}-sess_set_get_cb_yield.patch | patch -p1 ; \
    fi \
    && if [ $(echo ${RESTY_OPENSSL_VERSION} | cut -c 1-5) = "1.1.0" ] ; then \
        echo 'patching OpenSSL 1.1.0 for OpenResty' \
        && curl -s https://raw.githubusercontent.com/openresty/openresty/ed328977028c3ec3033bc25873ee360056e247cd/patches/openssl-1.1.0j-parallel_build_fix.patch | patch -p1 \
        && curl -s https://raw.githubusercontent.com/openresty/openresty/master/patches/openssl-${RESTY_OPENSSL_PATCH_VERSION}-sess_set_get_cb_yield.patch | patch -p1 ; \
    fi \
    && ./config \
      no-threads shared zlib -g \
      enable-ssl3 enable-ssl3-method \
      --prefix=/usr/local/openresty/openssl \
      --libdir=lib \
      -Wl,-rpath,/usr/local/openresty/openssl/lib \
    && make -j${RESTY_J} \
    && make -j${RESTY_J} install_sw \
    && cd /tmp \
    && curl -fSL https://downloads.sourceforge.net/project/pcre/pcre/${RESTY_PCRE_VERSION}/pcre-${RESTY_PCRE_VERSION}.tar.gz -o pcre-${RESTY_PCRE_VERSION}.tar.gz \
    && echo "${RESTY_PCRE_SHA256}  pcre-${RESTY_PCRE_VERSION}.tar.gz" | shasum -a 256 --check \
    && tar xzf pcre-${RESTY_PCRE_VERSION}.tar.gz \
    && cd /tmp/pcre-${RESTY_PCRE_VERSION} \
    && ./configure \
        --prefix=/usr/local/openresty/pcre \
        --disable-cpp \
        --enable-utf \
        --enable-unicode-properties \
        ${RESTY_PCRE_BUILD_OPTIONS} \
    && make -j${RESTY_J} \
    && make -j${RESTY_J} install \
    && cd /tmp \
    && curl -fSL https://openresty.org/download/openresty-${RESTY_VERSION}.tar.gz -o openresty-${RESTY_VERSION}.tar.gz \
    && tar xzf openresty-${RESTY_VERSION}.tar.gz \
    && cd /tmp/openresty-${RESTY_VERSION} \
    && if [ -n "${RESTY_EVAL_POST_DOWNLOAD_PRE_CONFIGURE}" ]; then eval $(echo ${RESTY_EVAL_POST_DOWNLOAD_PRE_CONFIGURE}); fi \
    && eval ./configure -j${RESTY_J} ${_RESTY_CONFIG_DEPS} ${RESTY_CONFIG_OPTIONS} ${RESTY_CONFIG_OPTIONS_MORE} ${RESTY_LUAJIT_OPTIONS} ${RESTY_PCRE_OPTIONS} \
    && make -j${RESTY_J} \
    && make -j${RESTY_J} install \
    && cd /tmp \
    && if [ -n "${RESTY_EVAL_POST_MAKE}" ]; then eval $(echo ${RESTY_EVAL_POST_MAKE}); fi \
    && apk del .build-deps \
    && mkdir -p /var/run/openresty \
    && ln -sf /dev/stdout /usr/local/openresty/nginx/logs/access.log \
    && ln -sf /dev/stderr /usr/local/openresty/nginx/logs/error.log

# Add additional binaries into PATH for convenience
ENV PATH=$PATH:/usr/local/openresty/luajit/bin:/usr/local/openresty/bin:/usr/local/openresty/nginx/bins \
LUA_PATH="/usr/local/openresty/nginx/lua/?.lua;/usr/local/openresty/nginx/lua/?/init.lua;/usr/local/openresty/site/lua/?.lua;/usr/local/openresty/site/lua/?/init.lua;/usr/local/openresty/site/lualib/?.lua;/usr/local/openresty/site/lualib/?/init.lua;/usr/local/openresty/lualib/?.lua;/usr/local/openresty/lualib/?/init.lua;./?.lua;/usr/local/openresty/site/lualib/?.ljbc;/usr/local/openresty/site/lualib/?/init.ljbc;/usr/local/openresty/lualib/?.ljbc;/usr/local/openresty/lualib/?/init.ljbc;/usr/local/openresty/luajit/share/luajit-2.1/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;/usr/local/openresty/luajit/share/lua/5.1/?.lua;/usr/local/openresty/luajit/share/lua/5.1/?/init.lua;" \
LUA_CPATH="/usr/local/openresty/nginx/lua/?.so/usr/local/openresty/site/lualib/?.so;/usr/local/openresty/lualib/?.so;./?.so;/usr/local/lib/lua/5.1/?.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so;/usr/local/lib/lua/5.1/loadall.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so;" \
GID=1000 \
UID=1000

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]

# Use SIGQUIT instead of default SIGTERM to cleanly drain requests
# See https://github.com/openresty/docker-openresty/blob/master/README.md#tips--pitfalls
STOPSIGNAL SIGQUIT

# docker stop $(docker ps -a | grep "Exited" | awk '{print $1 }')
# docker rm $(docker ps -a | grep "Exited" | awk '{print $1 }')
# docker rmi $(docker images | grep "none" | awk '{print $3}')

# docker image prune
# docker build  -t orabase:1 ./ -f base.Dockerfile --progress=plain 
# docker run --rm -p 8888:80 -it --name orabase orabase:1 sh