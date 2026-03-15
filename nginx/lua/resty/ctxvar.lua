-- resty.ctxvar: Request context wrapper
-- Wraps ngx.var and ngx.req into a convenient table interface

local _M = {}

---Create a context wrapper from an existing table or ngx context
---@param env table|nil: Optional initial table, or will create from ngx context
---@return table: Wrapped context with var, host, request_uri, request_header etc.
local function wrap(env)
    env = env or {}
    
    -- Wrap ngx.var for convenient access
    env.var = env.var or ngx.var or {}
    
    -- Host from request
    env.host = env.host or ngx.var.host or ngx.var.http_host or ''
    
    -- Request URI
    env.request_uri = env.request_uri or ngx.var.request_uri or ngx.var.uri or ''
    
    -- Request method
    env.request_method = env.request_method or ngx.var.request_method or ngx.req.get_method() or ''
    
    -- Request headers
    env.request_header = env.request_header or ngx.req.get_headers() or {}
    
    -- Request body (lazy load)
    local request_body
    local function get_request_body()
        if not request_body then
            ngx.req.read_body()
            request_body = ngx.req.get_body_data()
        end
        return request_body
    end
    env.get_request_body = get_request_body
    
    -- Response
    env.status = ngx.status
    
    return env
end

-- Support both wrap(env) and require('resty.ctxvar')(env) syntax
_M.new = wrap
return setmetatable(_M, {__call = function(_, env) return wrap(env) end})
