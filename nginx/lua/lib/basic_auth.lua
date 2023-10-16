local split, find = require("ngx.re").split, string.find
local ngsub, nmatch, decode_base64 = ngx.re.gsub, ngx.re.match, ngx.decode_base64
local ok, env = pcall(require, 'env')
if not ok then
    env = {}
end

local _M = {}
local function set_resp(status, err)
    ngx.status = status
    ngx.print(err)
    ngx.exit(status)
    return
end

function _M.extract_auth_header(auth)
    local m, err = nmatch(auth, "Basic\\s(.+)", "jo")
    if err then
        -- error authorization
        return nil, nil, err
    end
    local decoded = decode_base64(m[1])
    local res
    res, err = split(decoded, ":")
    if err then
        return nil, nil, "split authorization err:" .. err
    end
    local username = ngsub(res[1], "\\s+", "", "jo")
    local password = ngsub(res[2], "\\s+", "", "jo")
    return username, password
end

function _M.init_by_string(user_pass_str, ip_limit_str, key_str)
    if not user_pass_str then
        return
    end
    local auth_conf = { user = {}, ip = {}, ua = {} } -- clear the defaults
    local arr = split(user_pass_str, ' *, *', 'jo')
    for i = 1, #arr do
        local a1 = split(arr[i], ':', 'jo')
        if a1 then
            auth_conf.user[a1[1]] = a1[2]
        end
    end

    arr = split(ip_limit_str or '', ' *, *', 'jo')
    for i = 1, #arr do
        local a1 = split(arr[i], '=', 'jo')
        if a1 then
            auth_conf.ip[a1[1]] = tonumber(a1[2]) or 1
        end
    end

    arr = split(key_str or '', ' *, *', 'jo')
    for i = 1, #arr do
        local a1 = split(arr[i], '=', 'jo')
        if a1 then
            auth_conf.ua[arr[i]] = 1
        end
    end
    return auth_conf
end

function _M.handle(conf)
    if conf and type(conf) ~= 'table' then
        error('bad config parameter, leave nil to apply `env.auth_conf`')
    end
    if env and env.OR_AUTH_USER then
        conf = _M.init_by_string(env.OR_AUTH_USER, env.OR_AUTH_IP, env.OR_AUTH_KEY_SECRET)
        env.auth_conf = conf
        conf.auth_key = env.OR_AUTH_KEY or 'x-bakey'
        env.OR_AUTH_USER = nil
        env.OR_AUTH_IP = nil
    else
        conf = conf or env.auth_conf
    end


    local ip = ngx.var.http_x_forwarded_for or ngx.var.remote_addr
    local ua = ngx.req.get_headers(100)[conf.auth_key or 'x-bakey'] or 0
    if ip == '127.0.0.1' or conf.ip[ip] == 1 then
        return ip
    end
    if conf.ip[ip] == 0 then
        return set_resp(403, "no access")
    end
    if conf.ua[ua] == 1 then
        return ua
    end
    if conf.ua[ua] == 0 then
        return set_resp(403, "no access")
    end

    local auth_header = ngx.var.http_authorization
    if not auth_header then
        ngx.header["WWW-Authenticate"] = "Basic realm='.'"
        return set_resp(401, "authorization required")
    end

    local username, password, err = _M.extract_auth_header(auth_header)
    if err then
        return set_resp(401, "Invalid User")
    end

    local pwd = conf.user[username]
    if not pwd then
        return set_resp(401, "Invalid User")
    end
    if pwd ~= password then
        return set_resp(401, "Invalid user")
    end
    return username
end

return _M
