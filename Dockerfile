FROM oradev:2 as builder
FROM orabase:1
WORKDIR /usr/local/openresty/nginx
COPY --from=builder /usr/lib/libroaring.so /usr/lib/
COPY ./nginx/ /usr/local/openresty/nginx


RUN ln -snf /usr/lib/libroaring.so /usr/lib/libroaring.so.2 &&\
    chmod a+x /usr/local/openresty/site/ -R && chmod a+x /usr/local/openresty/nginx/lua/ -R && chmod a+x /usr/local/openresty/nginx/bins/ -R && \
	chmod 755 /usr/local/openresty/nginx/conf/*.sh && \
	apk add envsubst &&\
	cd /tmp/ && rm _tmp_ -rf && mkdir _tmp_ && curl -Lk "https://github.com/yorkane/lua-resty-klib/archive/refs/heads/main.zip" | bsdtar -xkf- -C _tmp_ && tree && mv _tmp_/*main/lib/* /usr/local/share/lua/5.1/ &&\
	# cd /tmp/ && rm _tmp_ -rf && mkdir _tmp_ && curl -Lk "https://github.com/fffonion/lua-resty-acme/archive/refs/heads/master.zip" | bsdtar -xkf- -C _tmp_ && tree && mv _tmp_/*master/lib/resty/* /usr/local/share/lua/5.1/ &&\
	# cd /tmp/ && rm _tmp_ -rf && mkdir _tmp_ && curl -Lk "https://github.com/fffonion/lua-resty-openssl/archive/refs/heads/master.zip" | bsdtar -xkf- -C _tmp_ && tree && mv _tmp_/*master/lib/resty/* /usr/local/share/lua/5.1/ &&\
	# cd /tmp/ && rm _tmp_ -rf && mkdir _tmp_ && curl -Lk "https://github.com/openresty/lua-resty-lrucache/archive/refs/heads/master.zip" | bsdtar -xkf- -C _tmp_ && tree && mv _tmp_/*master/lib/resty/* /usr/local/share/lua/5.1/ &&\
	# cd /tmp/ && rm _tmp_ -rf && mkdir _tmp_ && curl -Lk "https://github.com/openresty/lua-resty-string/archive/refs/heads/master.zip" | bsdtar -xkf- -C _tmp_ && tree && mv _tmp_/*master/lib/resty/* /usr/local/share/lua/5.1/ &&\
	rm -rf /tmp/* &&\
#apk add  --no-cache perl &&\
	echo "Finished"

ENV PATH=$PATH:/usr/local/openresty/luajit/bin:/usr/local/openresty/bin:/usr/local/openresty/nginx/bins  \
LUA_PATH="/usr/local/openresty/nginx/lua/?.lua;/usr/local/openresty/nginx/lua/?/init.lua;/usr/local/openresty/site/lua/?.lua;/usr/local/openresty/site/lua/?/init.lua;/usr/local/openresty/site/lualib/?.lua;/usr/local/openresty/site/lualib/?/init.lua;/usr/local/openresty/lualib/?.lua;/usr/local/openresty/lualib/?/init.lua;./?.lua;/usr/local/openresty/site/lualib/?.ljbc;/usr/local/openresty/site/lualib/?/init.ljbc;/usr/local/openresty/lualib/?.ljbc;/usr/local/openresty/lualib/?/init.ljbc;/usr/local/openresty/luajit/share/luajit-2.1/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;/usr/local/openresty/luajit/share/lua/5.1/?.lua;/usr/local/openresty/luajit/share/lua/5.1/?/init.lua;" \
LUA_CPATH="/usr/local/openresty/nginx/lua/?.so/usr/local/openresty/site/lualib/?.so;/usr/local/openresty/lualib/?.so;./?.so;/usr/local/lib/lua/5.1/?.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so;/usr/local/lib/lua/5.1/loadall.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so;"

ENTRYPOINT ["/usr/local/openresty/nginx/conf/entrypoint.sh"]
# CMD ["nginx", "-g", "daemon off;"]

STOPSIGNAL SIGQUIT
# docker build  -t yorkane/docker-openresty-tool:latest ./ --progress=plain 
# docker build ./ -t yorkane/docker-openresty-tool:latest -t yorkane/docker-openresty-tool:1.21.4.1 -t registry.wtvdev.com/pub/docker-openresty-tool:1.21.4.1
# docker run --rm -p 8888:80 -it -v /data:/webdav --name dot yorkane/docker-openresty-tool:latest sh
# docker run --rm -p 8888:80 -e GID=1000 -eUID=1000 -it -v /data:/webdav -v /code/docker-openresty-tool/nginx:/usr/local/openresty/nginx --name dot yorkane/docker-openresty-tool:latest sh