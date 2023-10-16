# Dockerfile - alpine
# https://github.com/openresty/docker-openresty

ARG RESTY_IMAGE_BASE="alpine"
ARG RESTY_IMAGE_TAG="3.18"

FROM ${RESTY_IMAGE_BASE}:${RESTY_IMAGE_TAG}

LABEL maintainer="Evan Wies <evan@neomantra.net>"

# Docker Build Arguments
ARG RESTY_IMAGE_BASE="alpine"
ARG RESTY_IMAGE_TAG="3.18"
ARG RESTY_VERSION="1.21.4.2"
ARG RESTY_OPENSSL_VERSION="1.1.1w"
ARG RESTY_OPENSSL_PATCH_VERSION="1.1.1f"
ARG RESTY_OPENSSL_URL_BASE="https://www.openssl.org/source"
ARG RESTY_PCRE_VERSION="8.45"
ARG RESTY_PCRE_BUILD_OPTIONS="--enable-jit"
ARG RESTY_PCRE_SHA256="4e6ce03e0336e8b4a3d6c2b70b1c5e18590a5673a98186da90d4f33c23defc09"
ARG RESTY_J="4"
ARG RESTY_CONFIG_OPTIONS="\
    --with-compat \
    --with-file-aio \
    --with-http_addition_module \
    --with-http_auth_request_module \
    --with-http_dav_module \
    --with-http_flv_module \
#    --with-http_geoip_module=dynamic \
#    --with-http_gunzip_module \
#    --with-http_gzip_static_module \
#    --with-http_image_filter_module=dynamic \
    --with-http_mp4_module \
    --with-http_random_index_module \
    --with-http_realip_module \
    --with-http_secure_link_module \
    --with-http_slice_module \
    --with-http_ssl_module \
    --with-http_stub_status_module \
#   --with-http_sub_module \
    --with-http_v2_module \
#    --with-http_xslt_module=dynamic \
    --with-ipv6 \
#    --with-mail \
#    --with-mail_ssl_module \
    --with-md5-asm \
    --with-sha1-asm \
    --with-stream \
    --with-stream_ssl_module \
    --with-threads \
    --add-module=/tmp/nginx-dav-ext-module-master \
    "
ARG RESTY_CONFIG_OPTIONS_MORE=""
ARG RESTY_LUAJIT_OPTIONS="--with-luajit-xcflags='-DLUAJIT_NUMMODE=2 -DLUAJIT_ENABLE_LUA52COMPAT'"
ARG RESTY_PCRE_OPTIONS="--with-pcre-jit"

ARG RESTY_ADD_PACKAGE_BUILDDEPS=""
ARG RESTY_ADD_PACKAGE_RUNDEPS=""
ARG RESTY_EVAL_PRE_CONFIGURE=""
ARG RESTY_EVAL_POST_DOWNLOAD_PRE_CONFIGURE=""
ARG RESTY_EVAL_POST_MAKE=""

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


RUN echo 'ls -la "$@"' > /usr/bin/ll && chmod 755 /usr/bin/ll && \
	sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories && \
    apk add --no-cache --virtual .build-deps \
        build-base \
        coreutils \
        curl \
        gd-dev \
        geoip-dev \
        libxslt-dev \
        linux-headers \
        make \
        cmake \
        perl-dev \
        readline-dev \
        zlib-dev \
        unzip luarocks5.1 lua5.1-dev gcc libc-dev make zziplib-dev \
        ${RESTY_ADD_PACKAGE_BUILDDEPS} &&\
    apk add --no-cache \
        gd \
        geoip \
        libgcc \
        libxslt \
        zlib \
        curl libarchive-tools tree gettext-envsubst \
        ${RESTY_ADD_PACKAGE_RUNDEPS} \
    && cd /tmp \
    && if [ -n "${RESTY_EVAL_PRE_CONFIGURE}" ]; then eval $(echo ${RESTY_EVAL_PRE_CONFIGURE}); fi \
    && cd /tmp \
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
    && echo "pcre installed" \
    && cd /tmp \
    && curl -fSL https://openresty.org/download/openresty-${RESTY_VERSION}.tar.gz -o openresty-${RESTY_VERSION}.tar.gz \
    && tar xzf openresty-${RESTY_VERSION}.tar.gz \
    && echo "openresty download finished" \
    cd /tmp/ && curl -fSL https://github.com/arut/nginx-dav-ext-module/archive/master.zip -o dav-ext-module.zip \
    && unzip dav-ext-module.zip \
    && echo "extend modules download finished" \
    && cd /tmp/openresty-${RESTY_VERSION} \
    && if [ -n "${RESTY_EVAL_POST_DOWNLOAD_PRE_CONFIGURE}" ]; then eval $(echo ${RESTY_EVAL_POST_DOWNLOAD_PRE_CONFIGURE}); fi \
    && eval ./configure -j${RESTY_J} ${_RESTY_CONFIG_DEPS} ${RESTY_CONFIG_OPTIONS} ${RESTY_CONFIG_OPTIONS_MORE} ${RESTY_LUAJIT_OPTIONS} ${RESTY_PCRE_OPTIONS} \
    && make -j${RESTY_J} \
    && make -j${RESTY_J} install \
    && cd /tmp \
    && if [ -n "${RESTY_EVAL_POST_MAKE}" ]; then eval $(echo ${RESTY_EVAL_POST_MAKE}); fi \
    # && apk del .build-deps \
    && mkdir -p /var/run/openresty \
    # && ln -sf /dev/stdout /usr/local/openresty/nginx/logs/access.log \
    # && ln -sf /dev/stderr /usr/local/openresty/nginx/logs/error.log
# ---- Original Builder Ends ----    
    && mv /usr/bin/envsubst /usr/local/bin/ && \
    ln -sf /usr/bin/luarocks-5.1 /usr/bin/luarocks && \
    mkdir -p /usr/local/openresty/lua/ /usr/local/openresty/site/lualib/resty/ && \
    cd /usr/local/openresty/site/lualib/ && mkdir klib -p && \
    LUAJIT_DIR=/usr/local/openresty/luajit && \
    luarocks install luasocket && \
    luarocks install luazip && \
    luarocks install lua-vips && \
    luarocks install rapidjson && \
    luarocks install aspect && \
    luarocks install xml2lua && \
	luarocks install lua-resty-http && \
	luarocks install lua-resty-redis-connector && \
    luarocks install lua-resty-template && \
    luarocks install lua-ffi-zlib && \
    luarocks install lua-resty-acme && \
    luarocks install lua-resty-openssl && \
    cd /usr/local/openresty/site/lualib/ && mkdir klib -p && \
    wget 'https://raw.githubusercontent.com/semyon422/luajit-iconv/master/init.lua' -O libiconv.lua && \
    wget 'https://raw.githubusercontent.com/spacewander/luafilesystem/master/lfs_ffi.lua' && \
    cd /usr/local/openresty/site/lualib/resty/ && \
    wget 'https://raw.githubusercontent.com/cloudflare/lua-resty-cookie/master/lib/resty/cookie.lua' && \
    wget 'https://raw.githubusercontent.com/jkeys089/lua-resty-hmac/master/lib/resty/hmac.lua'  && \
    wget 'https://raw.githubusercontent.com/openresty/lua-resty-shell/master/lib/resty/shell.lua' && \
    wget 'https://raw.githubusercontent.com/yorkane/lua-resty-ctxvar/main/lib/resty/ctxvar.lua' && \
    cd /tmp/ && mkdir _tmp_ && \
    curl -Lk "https://github.com/yorkane/lua-resty-klib/archive/refs/heads/main.zip" | bsdtar -xkf- -C _tmp_ && tree && \
    cd _tmp_/*main/lib/ && mv * /usr/local/openresty/site/lualib/ && \
    rm /tmp/ -rf && mkdir /tmp/ &&\
    rm /usr/local/openresty/pod/ -rf && \
    mv /usr/local/openresty/nginx/sbin/nginx /usr/local/openresty/bin/ && \
    ln -sf /usr/local/openresty/bin/nginx /usr/local/openresty/bin/openresty && \
    # mv /usr/local/openresty/nginx/modules /usr/local/openresty/ -f && \
    rm -rf /usr/local/openresty/nginx/ && \
    # apk  --no-cache add unrar --repository=http://mirrors.ustc.edu.cn/alpine/v3.14/main && \
    sed -i "1iexport PERL5LIB=/usr/local/openresty/nginx/"  /etc/profile &&\
    sed -i "1iexport LUA_PATH='/usr/local/openresty/nginx/lua/?.lua;/usr/local/openresty/nginx/lua/?/init.lua;/usr/local/openresty/site/lualib/?.ljbc;/usr/local/openresty/site/lualib/?/init.ljbc;/usr/local/openresty/lualib/?.ljbc;/usr/local/openresty/lualib/?/init.ljbc;/usr/local/openresty/site/lualib/?.lua;/usr/local/openresty/site/lualib/?/init.lua;/usr/local/openresty/lualib/?.lua;/usr/local/openresty/lualib/?/init.lua;./?.lua;	/usr/local/openresty/luajit/share/luajit-2.1.0-beta3/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;/usr/local/openresty/luajit/share/lua/5.1/?.lua;/usr/local/openresty/luajit/share/lua/5.1/?/init.lua;'" /etc/profile &&\
    sed -i "1iexport LUA_CPATH='/usr/local/openresty/site/lualib/?.so;/usr/local/openresty/lualib/?.so;./?.so;/usr/local/lib/lua/5.1/?.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so;/usr/local/lib/lua/5.1/loadall.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so;'"  /etc/profile &&\
    apk del .build-deps && \
    echo "Openresty install Finished"


ENV PATH=$PATH:/usr/local/openresty/luajit/bin:/usr/local/openresty/nginx/bins:/usr/local/openresty/bin \
NGX_APP=default_app \
NGX_PORT=80 \
NGX_WORKER=auto \
NGX_HOST=_ \
NGX_LOG_LEVEL=warn \
NGX_OVERWRITE_CONFIG=true \
OR_REDIS_URL=redis://passwd@127.0.0.1:6379/0 \
OR_AUTH_USER=xbakey:password \
OR_AUTH_IP=127.0.0.1=1,192.168.0.10=0 \
OR_AUTH_KEY=x-bakey \
OR_AUTH_KEY_SECRET=fookey1,wookey2 \
TZ=Asia/Shanghai




COPY ./nginx /usr/local/openresty/nginx
WORKDIR /usr/local/openresty/nginx/

RUN adduser --disabled-password --gecos "" --home "$(pwd)" --no-create-home --uid 1000 app1000 &&\
    chmod a+rwx /usr/local/openresty/nginx/entrypoint.sh && \
    chmod a+rwx /usr/local/openresty/nginx/bins/* && \
    chown 1000:nobody /usr/local/openresty/nginx/ -R &&\
    mkdir /data/ &&\
    chown 1000:nobody /data/ -R &&\
    echo "Compact finished!"
USER 1000

# CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
ENTRYPOINT ["/usr/local/openresty/nginx/entrypoint.sh"]

STOPSIGNAL SIGQUIT


# docker build ./ -t yorkane/openresty:base -f base.Dockerfile --progress=plain
# docker run --rm -it -v ./nginx:/usr/local/openresty/nginx --name dot yorkane/openresty:base sh
# docker save yorkane/openresty:base | xz > orap.tar.xz -v -T4

