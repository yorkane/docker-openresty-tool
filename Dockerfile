# In CI, pass --build-arg BASE_IMAGE=yorkane/openresty-base:latest
# For local builds, the default is the locally-built orabase:1
ARG BASE_IMAGE=orabase:1
FROM ${BASE_IMAGE}
WORKDIR /usr/local/openresty/nginx
COPY ./nginx/ /usr/local/openresty/nginx


RUN chmod a+x /usr/local/openresty/site/ -R && \
    chmod a+x /usr/local/openresty/nginx/lua/ -R && \
    chmod a+x /usr/local/openresty/nginx/bins/ -R && \
    chmod 755 /usr/local/openresty/nginx/conf/*.sh && \
    # Install libvips runtime + lua-vips binding
    apk add --no-cache --virtual .vips-build vips-dev git && \
    export LUAJIT_DIR=/usr/local/openresty/luajit && \
    luarocks config rocks_provided.luaffi-tkl "2.1-1" && \
    luarocks install lua-vips && \
    # 清理 vips-dev git 和构建缓存
    apk del .vips-build git && \
    rm -rf /tmp/* /var/cache/luarocks /var/cache/apk /root/.cache && \
    echo "Finished"

ENV PATH=$PATH:/usr/local/openresty/luajit/bin:/usr/local/openresty/bin:/usr/local/openresty/nginx/bins  \
LUA_PATH="/usr/local/openresty/nginx/lua/?.lua;/usr/local/openresty/nginx/lua/?/init.lua;/usr/local/openresty/site/lua/?.lua;/usr/local/openresty/site/lua/?/init.lua;/usr/local/openresty/site/lualib/?.lua;/usr/local/openresty/site/lualib/?/init.lua;/usr/local/openresty/lualib/?.lua;/usr/local/openresty/lualib/?/init.lua;./?.lua;/usr/local/openresty/site/lualib/?.ljbc;/usr/local/openresty/site/lualib/?/init.ljbc;/usr/local/openresty/lualib/?.ljbc;/usr/local/openresty/lualib/?/init.ljbc;/usr/local/openresty/luajit/share/luajit-2.1/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;/usr/local/openresty/luajit/share/lua/5.1/?.lua;/usr/local/openresty/luajit/share/lua/5.1/?/init.lua;" \
LUA_CPATH="/usr/local/openresty/nginx/lua/?.so/usr/local/openresty/site/lualib/?.so;/usr/local/openresty/lualib/?.so;./?.so;/usr/local/lib/lua/5.1/?.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so;/usr/local/lib/lua/5.1/loadall.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so;"

ENTRYPOINT ["/usr/local/openresty/nginx/conf/entrypoint.sh"]
# CMD ["nginx", "-g", "daemon off;"]

STOPSIGNAL SIGQUIT
# docker build  -t yorkane/docker-openresty-tool:latest ./ --progress=plain 
# docker save yorkane/docker-openresty-tool:latest | xz > yot1.tar.xz -v -T4
# xz -d -k < yot1.tar.xz | docker load

# docker run --rm -p 8888:80 -it -v /data:/webdav --name dot yorkane/docker-openresty-tool:latest sh
# docker run --rm -p 8888:80 -e GID=1000 -eUID=1000 -it -v /data:/webdav -v /code/docker-openresty-tool/nginx:/usr/local/openresty/nginx --name dot yorkane/docker-openresty-tool:latest sh

