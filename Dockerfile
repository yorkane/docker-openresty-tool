FROM yorkane/openresty:base as builder
FROM alpine:3.18
USER 0
WORKDIR /data

RUN echo 'ls -la "$@"' > /usr/bin/ll && chmod 755 /usr/bin/ll && \
	sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories && \
	apk add --no-cache \
        gd \
        geoip \
        libgcc \
        libxslt \
        zlib \
        curl libarchive-tools tree &&\
	echo "prepared"
	
COPY --from=builder /usr/local/openresty /usr/local/openresty
COPY ./nginx/entrypoint.sh /usr/local/openresty/nginx/entrypoint.sh
RUN tree /usr/local/

RUN tree /usr/local/ && mkdir -p /usr/local/openresty/nginx/bins/ && \
	chmod 755 /usr/local/openresty/nginx/entrypoint.sh && \
	tree /usr/local/openresty && \
    echo "compact finished!"

ENV PATH=$PATH:/usr/local/openresty/luajit/bin:/usr/local/openresty/bin:/usr/local/openresty/nginx \
LUA_PATH="/usr/local/openresty/nginx/lua/?.lua;/usr/local/openresty/nginx/lua/?/init.lua;/usr/local/openresty/site/lualib/?.ljbc;/usr/local/openresty/site/lualib/?/init.ljbc;/usr/local/openresty/lualib/?.ljbc;/usr/local/openresty/lualib/?/init.ljbc;/usr/local/openresty/site/lualib/?.lua;/usr/local/openresty/site/lualib/?/init.lua;/usr/local/openresty/lualib/?.lua;/usr/local/openresty/lualib/?/init.lua;./?.lua;/usr/local/openresty/luajit/share/luajit-2.1.0-beta3/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;/usr/local/openresty/luajit/share/lua/5.1/?.lua;/usr/local/openresty/luajit/share/lua/5.1/?/init.lua;" \
LUA_CPATH="/usr/local/openresty/nginx/lua/?.so/usr/local/openresty/site/lualib/?.so;/usr/local/openresty/lualib/?.so;./?.so;/usr/local/lib/lua/5.1/?.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so;/usr/local/lib/lua/5.1/loadall.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so;"

#sed -i "s@/usr/local/openresty/nginx/sbin/nginx@nginx@" /usr/local/openresty/bin/resty
#sed -i 's@"$prefix_dir/"@"/usr/local/openresty/nginx/"@' /usr/local/openresty/bin/resty

ENTRYPOINT ["/usr/local/openresty/nginx/entrypoint.sh"]
STOPSIGNAL SIGQUIT


# docker build ./ -t yorkane/openresty:1 -t yorkane/openresty:1.21.4.2 --progress=plain
# docker run --rm -it --name dot yorkane/openresty:1 sh