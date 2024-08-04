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

function _M.main()

end

return _M

--[[
curl -H 'cookie: uuid_tt_dd=10_9796907490-1543991494659-890838; UN=yorkane; gr_user_id=5743cb79-266c-4690-8496-5bbf0c3012fa;' 127.0.0.1/__tap
]]