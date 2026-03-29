# Dockerfile - docker-openresty-tool
# Builds on top of yorkane/openresty-base (pre-compiled OpenResty + LuaRocks)
# Adds: project-specific Lua libraries, nginx config
# Image processing: uses imgproxy (separate Docker service) instead of lua-vips

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

# Install extra Lua libraries and runtime deps on top of the base image
RUN set -eux \
    # ── Mirror selection ──────────────────────────────────────────────────────
    # USE_CN_MIRROR=1  switches ALL download sources to CN-accessible mirrors:
    #   apk      → USTC (mirrors.ustc.edu.cn)
    #   luarocks → API7 mirror (proxy by APISIX team)
    #   GitHub   → ghfast.top reverse-proxy  (raw + archive downloads)
    # Leave USE_CN_MIRROR empty for international builds.
    # ──────────────────────────────────────────────────────────────────────────
    && GHRAW="https://raw.githubusercontent.com" \
    && GHARCHIVE="https://github.com" \
    && if [ -n "${USE_CN_MIRROR}" ]; then \
    sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories; \
    GHRAW="https://ghfast.top/https://raw.githubusercontent.com"; \
    GHARCHIVE="https://ghfast.top/https://github.com"; \
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
        openssl-dev \
    \
    # Build deps only needed for lua C extension compilation
    && apk add --no-cache --virtual .build-deps \
        build-base \
        git \
        wget \
    \
    # ─── lua-resty-mlcache 安装 ───────────────────────────────────────────────
    # mlcache 依赖: lua-resty-lrucache, lua-resty-signal
    # 优先尝试 luarocks，失败则手动从 GitHub 安装
    && LUA_SHARE=/usr/local/openresty/luajit/share/lua/5.1 \
    && SITELIB=/usr/local/openresty/site/lualib \
    \
    # mlcache 需要 lrucache (OpenResty 内置) 和 FFI bindings
    # 先尝试 luarocks 安装
    && luarocks install lua-resty-mlcache 2>/dev/null || { \
        echo "[WARN] luarocks install failed, installing mlcache from GitHub..."; \
        cd /tmp && rm -rf _mlcache_ && mkdir _mlcache_ && cd _mlcache_; \
        wget -qO- "${GHARCHIVE}/openresty/lua-resty-mlcache/archive/refs/heads/master.tar.gz" | tar xz -C .; \
        mkdir -p "${SITELIB}/resty"; \
        cp lua-resty-mlcache*/lib/resty/mlcache*.lua "${SITELIB}/resty/"; \
        cd /tmp && rm -rf _mlcache_; \
        echo "[INFO] mlcache installed from GitHub"; \
    } \
    \
    # ─── 其他 luarocks 包 ────────────────────────────────────────────────────
    && for PKG in lua-resty-http lua-resty-template lua-ffi-zlib lua-resty-redis-connector; do \
        luarocks install ${PKG} 2>/dev/null || { \
            echo "[WARN] luarocks install ${PKG} failed, skipping..."; \
        }; \
    done \
    \
    # ─── luazip 手动编译 ────────────────────────────────────────────────────
    # luarocks 安装 luazip 会链接错误，必须手动编译
    && cd /tmp \
    && wget -q "${GHARCHIVE}/mpeterv/luazip/archive/refs/heads/master.tar.gz" \
    && tar xzf master.tar.gz \
    && cd luazip-master \
    && gcc -O2 -fPIC -I/usr/local/openresty/luajit/include/luajit-2.1 -c src/luazip.c -o src/luazip.o \
    && gcc -shared -o zip.so src/luazip.o -L/usr/local/openresty/luajit/lib -lluajit-5.1 -lzzip -Wl,-rpath,/usr/local/openresty/luajit/lib \
    && cp zip.so /usr/local/openresty/luajit/lib/lua/5.1/zip.so \
    && cd /tmp && rm -rf luazip-master \
    \
    # NOTE: imgproxy is now deployed as a separate Docker service (see docker-compose.yml).
    # imgproxy handles all image processing. yot connects via HTTP to imgproxy:8080.
    \
    # Download raw Lua files into OpenResty's luajit share path
    && LUA_SHARE=/usr/local/openresty/luajit/share/lua/5.1 \
    # OpenResty site lualib path — the canonical location for third-party modules
    && SITELIB=/usr/local/openresty/site/lualib \
    && cd "${LUA_SHARE}" \
    && wget -q "${GHRAW}/semyon422/luajit-iconv/master/init.lua" -O libiconv.lua \
    && wget -q "${GHRAW}/spacewander/luafilesystem/master/lfs_ffi.lua" \
    && mkdir -p resty && cd resty \
    && wget -q "${GHRAW}/cloudflare/lua-resty-cookie/master/lib/resty/cookie.lua" \
    && wget -q "${GHRAW}/jkeys089/lua-resty-hmac/master/lib/resty/hmac.lua" \
    \
    # Install lua-resty-ctxvar (yorkane/lua-resty-ctxvar) → site/lualib/resty/ctxvar.lua
    && cd /tmp && rm -rf _tmp_ && mkdir _tmp_ \
    && wget -qO- "${GHARCHIVE}/yorkane/lua-resty-ctxvar/archive/refs/heads/main.tar.gz" \
    | tar xz -C _tmp_ \
    && mkdir -p "${SITELIB}/resty" \
    && cp _tmp_/lua-resty-ctxvar-main/lib/resty/ctxvar.lua "${SITELIB}/resty/ctxvar.lua" \
    \
    # lua-resty-mlcache now installed via luarocks above
    # Install lua-resty-klib (yorkane/lua-resty-klib) → site/lualib/klib/*.lua
    && rm -rf _tmp_ && mkdir _tmp_ \
    && wget -qO- "${GHARCHIVE}/yorkane/lua-resty-klib/archive/refs/heads/main.tar.gz" \
    | tar xz -C _tmp_ \
    && mkdir -p "${SITELIB}/klib" \
    && cp -r _tmp_/lua-resty-klib-main/lib/klib/. "${SITELIB}/klib/" \
    \
    # ─── lua-resty-openssl 安装 ────────────────────────────────────────────────
    # lua-resty-http 0.17+ 依赖 lua-resty-openssl 用于 mTLS 支持
    # 需要完整的目录结构 (resty/openssl/x509/, resty/openssl/auxiliary/)
    && rm -rf _tmp_ && mkdir _tmp_ && cd _tmp_ \
    && wget -qO- "${GHARCHIVE}/fffonion/lua-resty-openssl/archive/refs/heads/master.tar.gz" \
    | tar xz -C . \
    && mkdir -p "${SITELIB}/resty/openssl" \
    && cp -r lua-resty-openssl-master/lib/resty/openssl/. "${SITELIB}/resty/openssl/" \
    && cp lua-resty-openssl-master/lib/resty/openssl/*.lua "${SITELIB}/resty/" \
    && cd /tmp && rm -rf _tmp_ \
    \
    
    # Download frontend third-party libs into nginx/html/libs/ (bundled, no CDN at runtime)
    && mkdir -p /usr/local/openresty/nginx/html/libs \
    && cd /usr/local/openresty/nginx/html/libs \
    && wget -q "https://cdn.jsdelivr.net/npm/jszip@3.10.1/dist/jszip.min.js" \
    && wget -q "https://cdn.jsdelivr.net/npm/pdfjs-dist@3.11.174/build/pdf.min.js" \
    && wget -q "https://cdn.jsdelivr.net/npm/pdfjs-dist@3.11.174/build/pdf.worker.min.js" \
    && wget -q "https://cdn.jsdelivr.net/npm/jspdf@2.5.1/dist/jspdf.umd.min.js" \
    \
    # Copy nginx binary to /usr/local/bin so it's always on PATH
    && mv /usr/local/openresty/nginx/sbin/nginx /usr/local/bin/nginx \
    \
    # Clean up build artifacts and caches to reduce image size
    && rm -rf /tmp/* \
    && rm -rf /var/cache/apk/* \
    && rm -rf /root/.cache/* \
    && rm -rf /root/.luarocks/* \
    && rm -rf /usr/local/share/lua/5.1/doc/* \
    && rm -rf /usr/local/share/man/* \
    && rm -rf /usr/local/lib/pkgconfig/* \
    && rm -rf /usr/local/include/* \
    && find /usr/local -type d -name ".git" -exec rm -rf {} + 2>/dev/null || true \
    && find /tmp -type f -name "*.tar.gz" -delete 2>/dev/null || true \
    && apk del .build-deps \
    \
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
#     --build-arg BASE_IMAGE=ghcr.io/yorkacdne/openresty-base:sha-abc1234
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
