local say, print, nmd5, select = ngx.say, ngx.print, ngx.md5, select

local split = require('ngx.re').split
local byte, find, sub, lower, sreverse, char = string.byte, string.find, string.sub, string.lower, string.reverse, string.char
local ins = table.insert
local nfind, nsub, gmatch, nmatch = ngx.re.find, ngx.re.gsub, ngx.re.gmatch, ngx.re.match
local ctxvar = require('resty.ctxvar')
local dump, logs, dump_class, dump_lua, dump_doc, dump_dict = require("klib.dump").global()

local _M = {

}
local reg_convert_img = [[^(.+)\.(jpg|bmp|png|ppm|jpeg|webp|gif)$]]
local reg_sub_folder = [[(.+?[^\d\/]+)[\d]+\.(jpg|bmp|png|ppm|jpeg|webp|gif)]]
local reg_clean_folder = [[^(.+?)[_\- \t\W]*$]]


--local utf8 = require 'lua-utf8'

local badtxt = [[(%20\-%20%E5%93%94%E5%93%A9%E5%93%94%E5%93%A9|%EF%BD%9C%E6%96%B9%E6%A0%BC%E5%AD%90%20vocus)]]
local webdav_ignore = 'webdav.'

---handle
---@param env resty.ctxvar
function _M.handle(env)
    env = ctxvar(env)
    local method = env.var.request_method
    local host = sub(env.host, #webdav_ignore+1, -1)
    if method == 'MKCOL' then
        if byte(env.request_uri, -1) ~= 47 then
            env.request_uri = env.request_uri..'/'
            local str = ngx.unescape_uri(env.request_uri or '/') or '/'
            -- logs(uri, str)
            ngx.req.set_uri(str, false)
        end
    elseif method == 'MOVE' then
        local dest = env.request_header['Destination']
        if not dest then
            ngx.status = 405
            ngx.print('MOVE method need `Destination` header')
            ngx.exit(405)
            return
        end
        local mc = nmatch(env.request_header['Destination'], 'https?://[^/]+(/.+)', 'ijo')
        -- rewrite the Header['Destination'] from 'http://demo.com/request-uri.xxx' into '/request-uri.xxx'
        if mc and mc[1] then
            dest = mc[1]
        end
        if not nfind(env.request_uri, [[^/[^\.]+\.\w+]], 'jo') and byte(env.request_uri, -1) ~= 47 then
            env.request_uri = env.request_uri .. '/'
            ngx.req.set_header('Destination', dest .. '/')
            ngx.req.set_uri(env.request_uri, false)
        else
            ngx.req.set_header('Destination', dest)
        end
    elseif method == 'PROPFIND' then
        local str = ngx.unescape_uri(sub(env.request_uri, 2,-1)) or '/'
        if #str == 0 then
            str = '/'
        end
        ngx.req.set_uri(str, false)
    end

    if find(env.request_uri,host, 1, true) then
        ngx.status = 405
        ngx.print('Could not archive own-site')
        ngx.exit(405)
        return
    end
    local uri, n = nsub(env.request_uri, badtxt, '', 'jo')
    uri = ngx.re.sub(uri, [[/_]], '/', 'jo')
    -- logs(n, uri, '===========', ngx.unescape_uri(uri))
    --if n and n > 0 then
        ngx.req.set_uri(ngx.unescape_uri(uri), false)
    --end
    logs(method, ngx.req.get_headers())
    if method == 'PUT' then
        --local txt = env.request_body
    end

    if method == 'PROPPATCH'  then
        ngx.header['Content-Type'] = 'text/xml'
        ngx.status = 207
        ngx.print('<?xml version="1.0"?><a:multistatus xmlns:a="DAV:"><a:response><a:propstat><a:status>HTTP/1.1 200 OK</a:status></a:propstat></a:response></a:multistatus>')
    end
end

function _M.main(folder_path)
end

function _M.test()

end

return _M