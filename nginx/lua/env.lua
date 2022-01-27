local _M = {hostname='1570327a85d8',
SYSTEM_DNS = "192.168.5.1", INIT_AT_UTC = ngx.utctime(),
generated = 'Thu Jan 27 15:44:32 UTC 2022'
}


local ok, patch = pcall(require, "_env") -- env.lua will be always rewrite by entrypoint.sh, using _env to overcome settings
if ok then
    for key, val in pairs(patch) do
        _M[key] = val
    end
end
return _M

