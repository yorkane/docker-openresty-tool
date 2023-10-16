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
local reg_badtxt = [[\$]]


---handle
---@param env resty.ctxvar
function _M.handle(env)
    env = ctxvar(env)
    local method = env.var.request_method
    local host = env.host
    local uri, n = nsub(env.request_uri, reg_badtxt, '', 'jo')
    uri = ngx.re.sub(uri, [[/_]], '/', 'jo')
    if method == 'MKCOL' then
        if byte(env.request_uri, -1) ~= 47 then
            env.request_uri = env.request_uri..'/'
            ngx.req.set_uri(ngx.unescape_uri(uri), false)
        end
    end

    if method == 'PUT' then
        if find(env.request_uri,host, 1, true) then
            ngx.status = 405
            ngx.print('Could not archive own-site')
            ngx.exit(405)
            return
        end
        --local txt = env.request_body
    end
end

function _M.main(folder_path)
    local badtxt = [[(%20\-%20%E5%93%94%E5%93%A9%E5%93%94%E5%93%A9|%EF%BD%9C%E6%96%B9%E6%A0%BC%E5%AD%90%20vocus)]]
    local txt = nsub('/vocus.cc/_article_644f45adfd897800017b9705-Stable%20Diffusion%20--%20%E8%A8%93%E7%B7%B4LoRA%EF%BC%88%E5%9B%9B%EF%BC%89%EF%BD%9C%E6%96%B9%E6%A0%BC%E5%AD%90%20vocus.html', badtxt, '', 'jo')
    dump(ngx.unescape_uri(txt))

end
return _M