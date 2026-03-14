-- lib/preview_inject.lua
-- Injects a single <script src="/__or_preview.js"> tag into every HTML
-- directory listing (fancyindex, autoindex, zipfs browse pages, etc.).
--
-- The actual preview logic lives in nginx/html/__or_preview.js,
-- served as a static file via the location = /__or_preview.js block in main.conf.
--
-- Usage in nginx config (inside location /):
--   header_filter_by_lua_block { require('lib.preview_inject').filter() }
--   body_filter_by_lua_block   { require('lib.preview_inject').body()   }

local _M = {}

-- The only thing we inject — a cacheable external script tag.
local SCRIPT_TAG = '<script src="/__or_preview.js" defer></script>'

-- header_filter: detect HTML responses and clear Content-Length
function _M.filter()
    local ct = ngx.header["Content-Type"] or ""
    if ct:find("text/html", 1, true) then
        ngx.header["Content-Length"] = nil   -- must clear; body length will change
        ngx.ctx.or_preview_inject = true
    end
end

-- body_filter: buffer all chunks, inject script tag before </body> at eof
function _M.body()
    if not ngx.ctx.or_preview_inject then return end

    local chunk = ngx.arg[1] or ""
    local eof   = ngx.arg[2]

    if chunk ~= "" then
        ngx.ctx.or_preview_buf = (ngx.ctx.or_preview_buf or "") .. chunk
        ngx.arg[1] = ""   -- hold; emit only when complete
    end

    if not eof then return end

    -- Flush: inject before </body>, or append at end if tag is absent
    ngx.ctx.or_preview_inject = false
    local buf = ngx.ctx.or_preview_buf or ""
    ngx.ctx.or_preview_buf = nil

    local injected = false
    local result = buf:gsub("</[Bb][Oo][Dd][Yy]>", function ()
        injected = true
        return SCRIPT_TAG .. "</body>"
    end, 1)

    ngx.arg[1] = injected and result or (buf .. SCRIPT_TAG)
end

return _M
