FROM alpine:3.14 as builder
WORKDIR /data
RUN cd /tmp/ && \
	sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories && \
	wget 'https://openresty.org/package/admin@openresty.com-5ea678a6.rsa.pub' -P /etc/apk/keys/ && \
	echo "https://openresty.org/package/alpine/v3.14/main" | tee -a /etc/apk/repositories && \
	apk add openresty-opm luarocks5.1 lua5.1-dev gcc libc-dev make zziplib-dev && \
	ln -sf /usr/bin/luarocks-5.1 /usr/bin/luarocks

RUN echo "Install Dependencies" && \
opm install ledgetech/lua-resty-http ledgetech/lua-resty-redis-connector bungle/lua-resty-template hamishforbes/lua-ffi-zlib openresty/lua-resty-string openresty/lua-resty-lrucache

RUN	mkdir -p /usr/local/openresty/lua/ && \
	export LUAJIT_DIR=/usr/local/openresty/luajit  && \
	luarocks install luasocket && \
	luarocks install luazip && \
	echo "Finished"

FROM alpine:3.15
WORKDIR /usr/local/openresty/
ENV PATH=$PATH:/usr/local/openresty/luajit/bin:/usr/local/openresty/bin \
	LUA_PATH="/usr/local/openresty/nginx/lua/?.lua;/usr/local/openresty/nginx/lua/?/init.lua;/usr/local/openresty/site/lualib/?.ljbc;/usr/local/openresty/site/lualib/?/init.ljbc;/usr/local/openresty/lualib/?.ljbc;/usr/local/openresty/lualib/?/init.ljbc;/usr/local/openresty/site/lualib/?.lua;/usr/local/openresty/site/lualib/?/init.lua;/usr/local/openresty/lualib/?.lua;/usr/local/openresty/lualib/?/init.lua;./?.lua;/usr/local/openresty/luajit/share/luajit-2.1.0-beta3/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;/usr/local/openresty/luajit/share/lua/5.1/?.lua;/usr/local/openresty/luajit/share/lua/5.1/?/init.lua;" \
LUA_CPATH="/usr/local/openresty/nginx/lua/?.so/usr/local/openresty/site/lualib/?.so;/usr/local/openresty/lualib/?.so;./?.so;/usr/local/lib/lua/5.1/?.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so;/usr/local/lib/lua/5.1/loadall.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so;"

COPY --from=builder /usr/local/openresty/site/lualib/ /usr/local/openresty/site/lualib
COPY --from=builder /usr/local/lib/lua/5.1/ /usr/local/openresty/site/lualib
COPY --from=builder /usr/local/share/lua/5.1/ /usr/local/openresty/site/lualib

RUN echo 'ls -la "$@"' > /usr/bin/ll && chmod 755 /usr/bin/ll && \
	sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories && \
	wget 'https://openresty.org/package/admin@openresty.com-5ea678a6.rsa.pub' -P /etc/apk/keys/ && \
	echo "https://openresty.org/package/alpine/v3.14/main" | tee -a /etc/apk/repositories && \
	apk --no-cache add openresty zlib zziplib tree curl && \
	apk add libarchive-tools --repository=http://mirrors.ustc.edu.cn/alpine/edge/main/ && \
	rm -rf site/pod site/manifest site/resty.index resty resty.index bin && \
	mv /usr/local/openresty/nginx/sbin/nginx /usr/local/bin/ && \
	mkdir -p /usr/local/openresty/nginx/lua && echo "--" > /usr/local/openresty/nginx/lua/init.lua && echo "--" > /usr/local/openresty/nginx/lua/init_worker.lua && \
	sed -i "1iexport PERL5LIB=/usr/local/openresty/nginx/"  /etc/profile && \
    sed -i "1iexport LUA_PATH='/usr/local/openresty/nginx/lua/?.lua;/usr/local/openresty/nginx/lua/?/init.lua;/usr/local/openresty/site/lualib/?.ljbc;/usr/local/openresty/site/lualib/?/init.ljbc;/usr/local/openresty/lualib/?.ljbc;/usr/local/openresty/lualib/?/init.ljbc;/usr/local/openresty/site/lualib/?.lua;/usr/local/openresty/site/lualib/?/init.lua;/usr/local/openresty/lualib/?.lua;/usr/local/openresty/lualib/?/init.lua;./?.lua;	/usr/local/openresty/luajit/share/luajit-2.1.0-beta3/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;/usr/local/openresty/luajit/share/lua/5.1/?.lua;/usr/local/openresty/luajit/share/lua/5.1/?/init.lua;'" /etc/profile && \
    sed -i "1iexport LUA_CPATH='/usr/local/openresty/site/lualib/?.so;/usr/local/openresty/lualib/?.so;./?.so;/usr/local/lib/lua/5.1/?.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so;/usr/local/lib/lua/5.1/loadall.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so;'"  /etc/profile && \
	cp nginx/conf/mime.types ./ && cp nginx/conf/koi* ./ && cp nginx/conf/win-utf ./ && \
	cd /usr/local/openresty/site/lualib/ && mkdir klib -p && \
	wget 'https://raw.githubusercontent.com/semyon422/luajit-iconv/master/init.lua' -O libiconv.lua && \
	wget 'https://raw.githubusercontent.com/spacewander/luafilesystem/master/lfs_ffi.lua' && \
	 cd /usr/local/openresty/site/lualib/resty/ && \
	wget 'https://raw.githubusercontent.com/cloudflare/lua-resty-cookie/master/lib/resty/cookie.lua' && \
	wget 'https://raw.githubusercontent.com/jkeys089/lua-resty-hmac/master/lib/resty/hmac.lua'  && \
	wget 'https://raw.githubusercontent.com/openresty/lua-resty-shell/master/lib/resty/shell.lua'
# 	# wget 'https://raw.githubusercontent.com/yorkane/lua-resty-ctxvar/main/lib/resty/ctxvar.lua' && \

run	cd /tmp/ && rm _tmp_ -rf && mkdir _tmp_ && \
	curl -Lk "https://github.com/yorkane/lua-resty-klib/archive/refs/heads/main.zip" | bsdtar -xkf- -C _tmp_ && tree && cd _tmp_/*main/lib/ && mv * /usr/local/openresty/site/lualib/ && \

	cd /tmp/ && rm _tmp_ -rf && mkdir _tmp_ && \
	curl -Lk "https://github.com/fffonion/lua-resty-acme/archive/refs/heads/master.zip" | bsdtar -xkf- -C _tmp_ && tree && cd _tmp_/*master/lib/resty && mv * /usr/local/openresty/site/lualib/resty/ &&\

	cd /tmp/ && rm _tmp_ -rf && mkdir _tmp_ && \
	curl -Lk "https://github.com/fffonion/lua-resty-openssl/archive/refs/heads/master.zip" | bsdtar -xkf- -C _tmp_ && tree && cd _tmp_/*master/lib/resty && mv * /usr/local/openresty/site/lualib/resty/ &&\

	cd /tmp/ && rm _tmp_ -rf && mkdir _tmp_ && \
	echo "Finished"

COPY ./entrypoint.sh /usr/local/openresty/
ENTRYPOINT ["/usr/local/openresty/entrypoint.sh"]
STOPSIGNAL SIGQUIT


# docker build ./ -t docker-openresty-tool:1