local socket = require("socket") -- require luasocket
local char = string.char
local _M = {}
local rdp_bytes = string.char(3,0,0) -- rdp bytes
function _M.test_connection()
	local sock = ngx.req.socket()
	local len, data = sock:peek(1) -- peek the first 1 byte that contains the length
	if not len then
		return
	end
	
	len = string.byte(len)
	if len > 5 then
		len = 5
	end
	data = sock:peek(len + 1)
	ngx.log(ngx.NOTICE, "== Remote access ", ngx.var.remote_addr, ":", ngx.var.remote_port, " Length: ", len, " Data:", data)
	if string.sub(data, 1, 3) == rdp_bytes then
		return true
	end
end

function _M.wake(macstr)
	local udp = socket.udp()
	udp:setoption('broadcast', true)
	udp:settimeout(1)
	local mac = ''
	for w in string.gmatch(macstr, "[0-9A-Za-z][0-9A-Za-z]") do
		mac = mac .. char(tonumber(w, 16))
	end
	return udp:sendto(mac..''..char(0xff):rep(6) .. mac:rep(16), '255.255.255.255', 9)
end

return _M

