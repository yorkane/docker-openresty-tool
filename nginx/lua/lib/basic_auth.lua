local split, find, next = require("ngx.re").split, string.find, next
local ngsub, nmatch, decode_base64 = ngx.re.gsub, ngx.re.match, ngx.decode_base64
local ok, env = pcall(require, 'env')
if not ok then
    env = {}
end

local _M = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- IP Range Matching (CIDR support)
-- ─────────────────────────────────────────────────────────────────────────────
local function parse_cidr(cidr)
    local ip, mask = cidr:match("([^/]+)/(%d+)")
    if ip and mask then
        return ip, tonumber(mask)
    end
    return cidr, 32  -- single IP, /32
end

local function ip_to_number(ip)
    local parts = {}
    for part in ip:gmatch("%d+") do
        table.insert(parts, tonumber(part))
    end
    if #parts ~= 4 then return nil end
    return (parts[1] * 16777216) + (parts[2] * 65536) + (parts[3] * 256) + parts[4]
end

local bit = require("bit")
local band, lshift = bit.band, bit.lshift

local function match_ip(cidr, client_ip)
    local ip, mask = parse_cidr(cidr)
    local ip_num = ip_to_number(ip)
    local client_num = ip_to_number(client_ip)
    if not ip_num or not client_num then return false end
    local mask_bits = lshift(0xFFFFFFFF, 32 - mask)
    return band(ip_num, mask_bits) == band(client_num, mask_bits)
end

-- Check if client IP is in the whitelist (comma-separated IPs/IP ranges)
local function is_ip_whitelisted(client_ip, whitelist_str)
    if not whitelist_str or whitelist_str == "" then
        return false
    end
    local arr = split(whitelist_str, ' *, *', 'jo')
    for i = 1, #arr do
        local cidr = arr[i]:gsub("%s+", "")
        if cidr ~= "" and match_ip(cidr, client_ip) then
            return true
        end
    end
    return false
end

-- Parse OR_IMGPROXY_UPSTREAM and extract IPs for automatic whitelist
local function get_imgproxy_upstream_ips()
    local ok, env = pcall(require, "env")
    env = (ok and env) or {}
    local upstream = env.OR_IMGPROXY_UPSTREAM or ""
    if upstream == "" then
        return ""
    end
    local ips = {}
    for server in upstream:gmatch("[^,]+") do
        server = server:gsub("%s+", "")
        local host, port = server:match("([^:]+):(%d+)")
        if host then
            -- Skip Docker service names (no dots = likely internal name)
            if host:match("%.") then
                table.insert(ips, host)
            end
        end
    end
    return table.concat(ips, ",")
end

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

    -- Extract the FIRST IP from X-Forwarded-For (original client IP through proxies)
    -- Format: "<original_ip>, <proxy1_ip>, <proxy2_ip>, ... <current_ip>"
    local forwarded_for = ngx.var.http_x_forwarded_for
    local ip
    if forwarded_for then
        ip = forwarded_for:match("^%s*([^,%s]+)")
    else
        ip = ngx.var.remote_addr
    end

    -- Check Bearer token auth (allows bypassing IP whitelist for trusted services like imgproxy)
    -- Supports:
    --   1. Authorization: Bearer <token> header
    --   2. X-Internal-Auth header (legacy)
    --   3. User-Agent header matching OR_AUTH_BEARER (for imgproxy)
    local bearer_token = env.OR_AUTH_BEARER or ""
    local internal_auth_header = env.OR_INTERNAL_AUTH_HEADER or ""  -- legacy fallback
    local request_bearer = ngx.var.http_authorization or ""
    local request_ua = ngx.var.http_user_agent or ""

    -- Check Bearer token in Authorization header
    if request_bearer:match("^Bearer%s+(.+)") then
        local token = request_bearer:match("^Bearer%s+(.+)")
        if bearer_token ~= "" and token == bearer_token then
            ngx.log(ngx.DEBUG, "[basic_auth] Bearer token matched, allowing")
            return ip
        end
    end

    -- Check User-Agent matching OR_AUTH_BEARER (for imgproxy requests)
    if bearer_token ~= "" and request_ua == bearer_token then
        ngx.log(ngx.DEBUG, "[basic_auth] User-Agent matched OR_AUTH_BEARER, allowing")
        return ip
    end

    -- Legacy X-Internal-Auth header support
    if internal_auth_header ~= "" then
        local request_internal_auth = ngx.var.http_x_internal_auth or ""
        if request_internal_auth == internal_auth_header then
            ngx.log(ngx.DEBUG, "[basic_auth] Legacy internal auth header matched, allowing")
            return ip
        end
    end
    local ua = ngx.req.get_headers(100)[conf.auth_key or 'x-bakey'] or 0

    -- Build effective IP whitelist: OR_AUTH_IP_WHITELIST + OR_IMGPROXY_UPSTREAM IPs
    local env_whitelist = env.OR_AUTH_IP_WHITELIST or ""
    local upstream_ips = get_imgproxy_upstream_ips()
    local whitelist = env_whitelist
    if upstream_ips ~= "" then
        if whitelist ~= "" then
            whitelist = whitelist .. "," .. upstream_ips
        else
            whitelist = upstream_ips
        end
    end

    -- DEBUG: log whitelist info
    ngx.log(ngx.DEBUG, "[basic_auth] client_ip=", ip, " upstream=", env.OR_IMGPROXY_UPSTREAM or "",
            " whitelist=", whitelist, " env_whitelist=", env_whitelist, " upstream_ips=", upstream_ips)

    -- Check whitelist first (whitelisted IPs skip auth)
    if is_ip_whitelisted(ip, whitelist) then
        ngx.log(ngx.DEBUG, "[basic_auth] IP whitelisted, allowing")
        return ip
    end

    -- Check explicit IP allow/deny rules
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
    if not next(conf.user) then
        return
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
