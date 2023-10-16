local dump, logs, dump_class, dump_lua, dump_dict = require('klib.dump').locally()
local util = require('klib.util')
local check = require('klib.check_sanity')
local json = require "cjson"
local ins, tonumber, insert, type, concat = table.insert, tonumber, table.insert, type, table.concat
local split = require "ngx.re".split
local say, print, nvar, nfind, nsub, print, nmatch, gmatch, nreq = ngx.say, ngx.print, ngx.var, ngx.re.find, ngx.re.gsub, ngx.print, ngx.re.match, ngx.re.gmatch, ngx.req
local sfind, sub, lower, sreverse, slast, char, byte = string.find, string.sub, string.lower, string.reverse, string.find_last, string.char, string.byte
local dict = ngx.shared['cache']
local _M = {}

function _M.handle()
    if ngx.get_phase() ~= 'timer' then
        ngx.header['worker_id'] = ngx.worker.id() .. '/' .. ngx.worker.count() --ngx.header['ETag'] = 'W/idtest1'
    end
    local hmac = require('resty.hmac')
    local epg = require('klib.file').read('epg.json')
    --local ctx = require('resty.ctxvar').new()
    local ok, res = xpcall(function()
        say('tap')
    end, debug.traceback)
    if not ok then
        dump(res)
    end
end

function _M.test(...)
    local len = select('#', ...)
    for i = 1, len do
        local var = select(i, ...)
    end
    return len
end

function _M.tapd()
    local class = ngx.var.query_string
    print(check.check_class(class, true))
end

function _M.yaml()
    local class_text = ngx.var.query_string
    if class_text and type(class_text) == 'string' then
        local json = require('lib.json')
        local list = split(class_text, ',+', 'jo')
        for i = 1, #list do
            local name = list[i]
            local ok, klass = pcall(require, name)
            if ok then
                say(dump.dump_yaml(klass), '\n---')
            else
                local ok, klass = pcall(require, 'configs.' .. name)
                if ok then
                    say(dump.dump_yaml(klass), '\n---')
                else
                    dump(klass)
                end
            end
        end
    end
end

function _M.proc(query)
    query = query or nreq.get_uri_args()
    if query.dump then
        print(check.check_class(query.dump, true))
    end
    if query.class then
        print(check.check_class(query.class))
    end
end

function _M.resolve()
    local resolver, err = require('klib.synconf').get_resolver()
    local server, ip = ngx.var.arg_domain
    if server and resolver and resolver.get_ip then
        ip, err = resolver:get_ip(server)
    end
    local r = require('resty.dns.resolver'):new({ nameservers = { '218.108.248.200' } })

    dump(resolver, server, ip, err)

    --dump(r:query('www.baidu.com'))

end

function _M.eval()
    ngx.req.read_body()
    local body = nreq.get_body_data()
    if body and nfind(body, [[local |dump\(|print\(|\require]], 'jo') then
        local fun = loadstring(body)
        local ok, res = xpcall(fun, debug.traceback)
        if res then
            dump(res)
        end
    end
end

local str = [[
cache_key_include_host: true # 缓存key是否包括 domain host （不同的domain 要共享缓存时关闭此配置）
dict: cache # Openresty 内部缓存池key `lua_shared_dict cache 50m;` 和nginx.conf配置文件对应
body_filter:
 replace:
  # (.+?)epg.wtvdev.com: \1.$host_1
  # (.+?)(asp|obmp).wasu.tv: \1.$host_1
  #https://source-picx: http://source-pic
  #https://boot-video.xuexi.cn: http://source-pic.asp.wasu.tv
  #http\://y.test.epg.wtvdev.com:  http://hz.test.epg.wtvdev.com
  https\://source-pic.asp.wasu.tv: http://source-pic.asp.wasu.tv
  y.test.epg.wtvdev.com: hz.test.epg.wtvdev.com
  y.test.epgpage.wtvdev.com: hz.test.epgpage.wtvdev.com
sign:
 header_key: epg-sign
 secret: 893hg590bj45i03040jj
 type: SHA256
 include:
  - "body"
gzip_min_length: 110
gzip_force: 0
cache_key_include_host: 1
policy: #缓存策略集合
 source-pic.asp.wasu.tv:
  host_map: 121.43.118.43:80
 *: #默认的匹配规则
  host_map: #域名Host 对应的后端服务
   *: 121.43.118.43:80
  #host: y.test.epg.wtvdev.com
  #host: y.test.epgpage.wtvdev.com
  expires: 5 #默认缓存5秒
  cache_key_include_host: 1
  /article/:
   expires: 30 #默认缓存30秒
   args:
    link: -2 #屏蔽link参数
  /blocktest_path: -1 #禁止访问返回403
  /channel/: 4
  /conf/: 7
  /ext-search/: 15
  /index/heartbeat: 0 #透传，不做任何处理
  /special/:
   expires: 30 #默认缓存30秒
   inactive_seconds: 86400 #单独定制灰度保存时间
   args: #对该路径下的query args 做缓存策略配置
    topicFirst: 10 #该路径下带`topicFirst` 参数的访问 缓存10秒，否则缓存30秒
 www.mock.com:
  /mock/:
   expires: 0 #默认全部不缓存， 否则缓存5秒
   args:
    bad: -1 #屏蔽 `bad` 参数
    mock5s: 5
stale_status: # 5xx 错误缓存时间
 500: 3
 501: 5
 502: 5
 503: 5
 504: 5
 505: 5
#redis_url: redis://Tjishu_!&)256@r-bp1kpuyrg77q990w2n.redis.rds.aliyuncs.com:6379/1#redis地址，在K8S 尽量使用IP地址或者公共域名地址
inactive_seconds: 2592000 #无活动的缓存保存时间 30x24x3600, 期间如果有失败的请求，将使用灰度缓存替代，并延长再次保存时间
cache_status: #4xx响应缓存时间 只对有缓存策略的响应生效(-1,0 均不生效)
 400: 10
 401: 10
 403: 10
 404: 10
hide_header: #隐藏输出的响应头 只对有缓存策略的响应生效(-1,0 均不生效)
 cache-control: 1 #1生效，0及以下不生效
 cookie: 1
 set-cookie: 1
]]
function _M.main()
    --dump(require('lib.json').try_parse(str))
    local str = [["fdsfds.js"]]
    dump(nsub(str, [[\w+\.js[\?]*"]]))
end

return _M

--[[
curl -H 'cookie: uuid_tt_dd=10_9796907490-1543991494659-890838; UN=yorkane; gr_user_id=5743cb79-266c-4690-8496-5bbf0c3012fa;' 127.0.0.1/__tap
]]