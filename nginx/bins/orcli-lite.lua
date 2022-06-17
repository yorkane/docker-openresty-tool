-- Shell command:
-- ../bin/resty --shdict "appconf 10m" refresh_code.lua
-- apk add openresty-resty openresty-opm --repository=http://openresty.org/package/alpine/v3.13/main/
-- opm install lindowx/lua-resty-vardump
-- echo '/usr/local/openresty/bin/resty -c 1024 --errlog-level warn -I /usr/local/openresty/nginx/lua -I `pwd` -I `pwd`/lib -I `pwd`/lua --shdict "cache 50m" --shdict "cache_bus 10m" --shdict "lock 1m" --shdict "event_bus 10m" --shdict "timer 10m"  --shdict "prometheus 2m" --shdict "klib_auth_mfa 1m" $shdicts /usr/local/openresty/site/orcli-lite.lua "$@"' > /usr/bin/orcli && chmod 755 /usr/bin/orcli
-- cp /code/orad/bin/orcli-lite.lua /usr/local/openresty/site/
require "klib.dump".global()
local _M, say = {}, ngx.say
local buildin_fun = '\nlocal vardump = require "klib.dump".global()\nlocal cjson = require("cjson")\nlocal say, byte,char,sub,match,encode_base64,decode_base64=ngx.say, string.byte, string.char, string.sub , ngx.re.match, ngx.encode_base64, ngx.decode_base64;\n'
function _M.run()
	if ngx.get_phase() ~= 'timer' then
		ngx.say('current environment is not on resty-client')
		return
	end

	local class_name = arg[1]
	local module, method_name, options
	if not class_name then
		say('no lua class not file found!')
		return
	end

	if class_name == 'run' then
		local str = ''
		for i = 2, #arg do
			str = str ..' '.. arg[i] or ''
		end
		local funstr = ''
		if string.find(str, 'return' ,1 ,true) then
			funstr = buildin_fun..str
		else
			funstr = buildin_fun .. 'return ' .. str
		end
		--ngx.say(funstr)
		dump(load(funstr)())
		return
	end

	if string.find(class_name, '.lua', 1, true) then
		module = dofile(class_name)
		if not module then
			return -- no module
		end
	else
		say('lua file or code required required')
		return
	end
	if not method_name then
		method_name = arg[2] or 'main'
	end

	local fun = rawget(module, method_name) or module[method_name]
	if not fun then
		fun = rawget(module, 'test') or module.test
		if fun then
			print('Not found: `', method_name, '()` Using test() instead\n')
			method_name = 'test'
		else
			say('no method`', method_name, '`found in this class:	', class_name, '\n Please using  -c=`development|test` -l=`debug|info|notice|warn|error|crtit` -m=`method_name` param1, param2, parmam3 ... ')
			say('Try to dump target object:')
			if arg[2] == 'yaml' then
				say(dump_yaml(module))
			elseif arg[2] == 'json' then
				say(require('cjson').encode(module))
			else
				dump(module)
			end
			return
		end
	end
	dump(fun())
end

_M.run()

return _M