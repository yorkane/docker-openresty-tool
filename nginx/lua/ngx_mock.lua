if ngx then
	return ngx
end

--- ngx
---@class ngx_mock
ngx = {
	AGAIN = -2,
	ALERT = 2,
	CRIT = 3,
	DEBUG = 8,
	DECLINED = -5,
	DONE = -4,
	EMERG = 1,
	ERR = 4,
	ERROR = -1,
	HTTP_ACCEPTED = 202,
	HTTP_BAD_GATEWAY = 502,
	HTTP_BAD_REQUEST = 400,
	HTTP_CLOSE = 444,
	HTTP_CONFLICT = 409,
	HTTP_CONTINUE = 100,
	HTTP_COPY = 128,
	HTTP_CREATED = 201,
	HTTP_DELETE = 32,
	HTTP_FORBIDDEN = 403,
	HTTP_GATEWAY_TIMEOUT = 504,
	HTTP_GET = 2,
	HTTP_GONE = 410,
	HTTP_HEAD = 4,
	HTTP_ILLEGAL = 451,
	HTTP_INSUFFICIENT_STORAGE = 507,
	HTTP_INTERNAL_SERVER_ERROR = 500,
	HTTP_LOCK = 4096,
	HTTP_METHOD_NOT_IMPLEMENTED = 501,
	HTTP_MKCOL = 64,
	HTTP_MOVE = 256,
	HTTP_MOVED_PERMANENTLY = 301,
	HTTP_MOVED_TEMPORARILY = 302,
	HTTP_NOT_ACCEPTABLE = 406,
	HTTP_NOT_ALLOWED = 405,
	HTTP_NOT_FOUND = 404,
	HTTP_NOT_MODIFIED = 304,
	HTTP_NO_CONTENT = 204,
	HTTP_OK = 200,
	HTTP_OPTIONS = 512,
	HTTP_PARTIAL_CONTENT = 206,
	HTTP_PATCH = 16384,
	HTTP_PAYMENT_REQUIRED = 402,
	HTTP_PERMANENT_REDIRECT = 308,
	HTTP_POST = 8,
	HTTP_PROPFIND = 1024,
	HTTP_PROPPATCH = 2048,
	HTTP_PUT = 16,
	HTTP_REQUEST_TIMEOUT = 408,
	HTTP_SEE_OTHER = 303,
	HTTP_SERVICE_UNAVAILABLE = 503,
	HTTP_SPECIAL_RESPONSE = 300,
	HTTP_SWITCHING_PROTOCOLS = 101,
	HTTP_TEMPORARY_REDIRECT = 307,
	HTTP_TOO_MANY_REQUESTS = 429,
	HTTP_TRACE = 32768,
	HTTP_UNAUTHORIZED = 401,
	HTTP_UNLOCK = 8192,
	HTTP_UPGRADE_REQUIRED = 426,
	HTTP_VERSION_NOT_SUPPORTED = 505,
	INFO = 7,
	NOTICE = 6,
	OK = 0,
	STDERR = 0,
	WARN = 5,
	null = "userdata: NULL",
	var = {
		arg_name = ' ', -- argument name in the request line
		args = ' ', -- arguments in the request line
		binary_remote_addr = ' ', -- client address in a binary form, value’s length is always 4 bytes
		body_bytes_sent = 23432, -- number of bytes sent to a client, not counting the response header; this variable is compatible with the “%B” parameter of the mod_log_config Apache module
		bytes_sent = 1024, -- number of bytes sent to a client (1.3.8, 1.2.5)
		connection = 11252, -- connection serial number (1.3.8, 1.2.5)
		connection_requests = ' ', -- current number of requests made through a connection (1.3.8, 1.2.5)
		content_length = ' ', -- “Content-Length” request header field
		content_type = 'html/text', -- “Content-Type” request header field
		cookie_name = ' ', -- the name cookie
		document_root = ' ', -- root or alias directive’s value for the current request
		document_uri = ' ', -- same as $uri
		host = 'localhost.mock', -- in this order of precedence: host name from the request line, or host name from the “Host” request header field, or the server name matching a request
		hostname = ' ', -- host name
		http_name = ' ', -- arbitrary request header field; the last part of a variable name is the field name converted to lower case with dashes replaced by underscores
		https = "on", -- if connection operates in SSL mode, or an empty string otherwise
		is_args = " ", -- “?” if a request line has arguments, or an empty string otherwise
		limit_rate = " ", -- setting this variable enables response rate limiting; see limit_rate
		msec = 123, -- current time in seconds with the milliseconds resolution (1.3.9, 1.2.6)
		nginx_version = "1.9.7.1", --nginx version
		pid = '8874', -- PID of the worker process
		pipe = ' ', -- “p” if request was pipelined, “.” otherwise (1.3.12, 1.2.7)
		proxy_protocol_addr = ' ', -- client address from the PROXY protocol header, or an empty string otherwise (1.5.12) The PROXY protocol must be previously enabled by setting the proxy_protocol parameter in the listen directive.
		query_string = ' ', -- same as $args
		realpath_root = ' ', -- an absolute pathname corresponding to the root or alias directive’s value for the current request, with all symbolic links resolved to real paths
		remote_addr = ' ', -- client address
		remote_port = ' ', -- client port
		remote_user = ' ', -- user name supplied with the Basic authentication
		request = ' ', -- full original request line
		request_body = ' ', -- request body The variable’s value is made available in locations processed by the proxy_pass, fastcgi_pass, uwsgi_pass, and scgi_pass directives.
		request_body_file = ' ', -- name of a temporary file with the request body At the end of processing, the file needs to be removed. To always write the request body to a file, client_body_in_file_only needs to be enabled. When the name of a temporary file is passed in a proxied request or in a request to a FastCGI/uwsgi/SCGI server, passing the request body should be disabled by the proxy_pass_request_body off, fastcgi_pass_request_body off, uwsgi_pass_request_body off, or scgi_pass_request_body off directives, respectively.
		request_completion = ' ', -- “OK” if a request has completed, or an empty string otherwise
		request_filename = ' ', -- file path for the current request, based on the root or alias directives, and the request URI
		request_length = ' ', -- request length (including request line, header, and request body) (1.3.12, 1.2.7)
		request_method = ' ', -- request method, usually “GET” or “POST”
		request_time = ' ', -- request processing time in seconds with a milliseconds resolution (1.3.9, 1.2.6); time elapsed since the first bytes were read from the client
		request_uri = ' ', -- full original request URI (with arguments)
		scheme = ' ', -- request scheme, “http” or “https”
		sent_http_name = ' ', -- arbitrary response header field; the last part of a variable name is the field name converted to lower case with dashes replaced by underscores
		server_addr = ' ', -- an address of the server which accepted a request Computing a value of this variable usually requires one system call. To avoid a system call, the listen directives must specify addresses and use the bind parameter.
		server_name = ' ', -- name of the server which accepted a request
		server_port = ' ', -- port of the server which accepted a request
		server_protocol = ' ', -- request protocol, usually “HTTP/1.0”, “HTTP/1.1”, or “HTTP/2.0”
		status = ' ', -- response status (1.3.2, 1.2.2)
		time_iso8601 = ' ', -- local time in the ISO 8601 standard format (1.3.12, 1.2.7)
		time_local = ' ', -- local time in the Common Log Format (1.3.12, 1.2.7)
		uri = '/test/path? ' -- current URI in request, normalized The value of $uri may change during request processing, e.g. when doing internal redirects, or when using index files.
	},
	---@type table<string, ngx.shared.DICT>
	shared = {}
}

---@return string @type
function ngx.hmac_sha1(arg)
end

--- ngx.resp
ngx.resp = {}

---@return string @type
function ngx.resp.get_headers(arg)
end

--- ngx.thread
ngx.thread = {}

---@return string @type
function ngx.thread.kill(arg)
end

---@return string @type
function ngx.thread.wait(arg)
end

---spawn
---@param func fun(arg1:any, arg2:any, ...):any
---@param arg1 any
---@param arg2 any
---@return thread @ using ngx.thread.wait(co) to get func result
function ngx.thread.spawn(func, arg1, arg2, ...)
end

---@return string @type
function ngx.encode_args(arg)
end

---@return string @type
function ngx.crc32_long(arg)
end

---@return string @type
function ngx.crc32_short(arg)
end

---@return string @type
function ngx._phase_ctx(arg)
end

---@return string @type
function ngx.md5_bin(s)
end -- /usr/local/openresty/lualib/resty/core/hash.lua:30


---@return string @type
function ngx.sha1_bin(s)
end -- /usr/local/openresty/lualib/resty/core/hash.lua:62


---@return string @type
function ngx.decode_args(arg)
end

---@return string @type
function ngx.time()
end -- /usr/local/openresty/lualib/resty/core/time.lua:74


---@return string @type
function ngx.cookie_time(sec)
end -- /usr/local/openresty/lualib/resty/core/time.lua:113

--- ngx.config
ngx.config = {}

---@return string @type
function ngx.config.prefix(arg)
end

---@return string @type
function ngx.config.nginx_configure(arg)
end

--- ngx.header
ngx.header = {}

---@return string @type
function ngx.send_headers(arg)
end

---@return string @type
function ngx.on_abort(arg)
end

---@return string @type
function ngx.get_now(arg)
end

---@return string @type
function ngx.md5(s)
end -- /usr/local/openresty/lualib/resty/core/hash.lua:46


---@return string @type
function ngx.today()
end -- /usr/local/openresty/lualib/resty/core/time.lua:84


---@return string @type
function ngx.say(...)
end

--- ngx.timer
ngx.timer = {}

---at
---@param delay number @fractional seconds like 0.001 to mean 1 millisecond
---@param callback fun(is_premature:boolean, user_arg1, user_arg2) @ can be any Lua function, which will be invoked later in a background "light thread" after the delay specified.
---@param user_arg1 table|string|number
---@param user_arg2 table|string|number
function ngx.timer.at(delay, callback, user_arg1, user_arg2, ...)
end

---@return number @the number of timers currently running.
function ngx.timer.running_count(arg)
end

---@return number @the number of pending timers.
function ngx.timer.pending_count(arg)
end

---every timer will be created every delay seconds until the current Nginx worker process starts exiting.
---@param delay number @fractional seconds like 0.001 to mean 1 millisecond, cannot be zero,
---@param callback fun(is_premature:boolean, user_arg1, user_arg2) @ can be any Lua function, which will be invoked later in a background "light thread" after the delay specified.
---@param user_arg1 table|string|number
---@param user_arg2 table|string|number
function ngx.timer.every(delay, callback, user_arg1, user_arg2, ...)
end

--- ngx.req
ngx.req = {}

---@return string @type
function ngx.req.is_internal(arg)
end

---@return string @type
function ngx.req.set_method(method)
end -- /usr/local/openresty/lualib/resty/core/request.lua:267


---@return string @type
function ngx.req.init_body(arg)
end

---@return string @type
function ngx.req.set_body_file(arg)
end

---@return string @type
function ngx.req.finish_body(arg)
end

---@return string @type
function ngx.req.socket(arg)
end

---@return string @type
function ngx.req.raw_header(arg)
end

---@return string @type
function ngx.req.set_body_data(arg)
end

---@return string @type
function ngx.req.read_body(arg)
end

---@return string @type
function ngx.req.get_uri_args(max_args)
end -- /usr/local/openresty/lualib/resty/core/request.lua:145


---@return string @type
function ngx.req.set_header(name, value)
end -- /usr/local/openresty/lualib/resty/core/request.lua:297


---@return string @type
function ngx.req.get_method()
end -- /usr/local/openresty/lualib/resty/core/request.lua:238


---@return string @type
function ngx.req.get_uri_args(arg)
end

---@return string @type
function ngx.req.start_time()
end -- /usr/local/openresty/lualib/resty/core/request.lua:207


---@return string @type
function ngx.req.discard_body(arg)
end

---@return string @type
function ngx.req.set_uri(arg)
end

---@return string @type
function ngx.req.clear_header(name)
end -- /usr/local/openresty/lualib/resty/core/request.lua:338


---@return string @type
function ngx.req.get_headers(max_headers, raw)
end -- /usr/local/openresty/lualib/resty/core/request.lua:76


---@return string @type
function ngx.req.http_version(arg)
end

---@return string @type
function ngx.req.append_body(arg)
end

---@return string @type
function ngx.req.get_body_data(arg)
end

---@return string @type
function ngx.req.get_post_args(arg)
end

---@return string @type
function ngx.req.get_body_file(arg)
end

---@param args string|table<string, string> @ well formed query string or query object 
---@return string @type
function ngx.req.set_uri_args(arg)
end

---@return string @type
function ngx.log(arg)
end

---@return string @type
function ngx.escape_uri(s)
end -- /usr/local/openresty/lualib/resty/core/uri.lua:26


---@return string @type
function ngx.encode_base64(s, no_padding)
end -- /usr/local/openresty/lualib/resty/core/base64.lua:35

--- ngx.socket
ngx.socket = {}

---@return string @type
function ngx.socket.tcp(arg)
end

---@return string @type
function ngx.socket.connect(arg)
end

---@return string @type
function ngx.socket.udp(arg)
end

---@return string @type
function ngx.socket.stream(arg)
end

--- ngx.worker
ngx.worker = {}

---@return string @type
function ngx.worker.exiting()
end -- /usr/local/openresty/lualib/resty/core/worker.lua:19



---pid This function returns a Lua number for the process ID (PID) of the current Nginx worker process. This API is more efficient than ngx.var.pid and can be used in contexts where the ngx.var.VARIABLE API cannot be used (like init_worker_by_lua).
---@return number
function ngx.worker.pid()
end -- /usr/local/openresty/lualib/resty/core/worker.lua:24



---count Returns the ordinal number of the current Nginx worker processes (starting from number 0).
---@return number
function ngx.worker.count()
end -- /usr/local/openresty/lualib/resty/core/worker.lua:39

---id
---@return number  @Returns the ordinal number of the current Nginx worker processes (starting from number 0).
function ngx.worker.id()
end -- /usr/local/openresty/lualib/resty/core/worker.lua:29




---@return string @type
function ngx.now()
end -- /usr/local/openresty/lualib/resty/core/time.lua:69

--- ngx.arg
ngx.arg = {}

---@return string @type
function ngx.throw_error(arg)
end

---@return string @type
function ngx.exec(arg)
end

---@return string @type
function ngx.utctime()
end -- /usr/local/openresty/lualib/resty/core/time.lua:102


---@return string @type
function ngx.parse_http_time(time_str)
end -- /usr/local/openresty/lualib/resty/core/time.lua:140


---@return string @type
function ngx.get_phase()
end -- /usr/local/openresty/lualib/resty/core/phase.lua:34

--- ngx.location
ngx.location = {}

---@return string @type
function ngx.location.capture(arg)
end

---@return string @type
function ngx.location.capture_multi(arg)
end

---@return string @type
function ngx.get_now_ts(arg)
end

---@return string @type
function ngx.print(...)
end

---@return string @type
function ngx.exit(rc)
end -- /usr/local/openresty/lualib/resty/core/exit.lua:26


---@return string @type
function ngx.eof(arg)
end

---@return string @type
function ngx.localtime()
end -- /usr/local/openresty/lualib/resty/core/time.lua:93


---@return string @type
function ngx.http_time(sec)
end -- /usr/local/openresty/lualib/resty/core/time.lua:127


---@return string @type
function ngx.quote_sql_str(arg)
end

---@return string @type
function ngx.update_time()
end -- /usr/local/openresty/lualib/resty/core/time.lua:79


---@return string @type
function ngx.flush(arg)
end

---@return string @type
function ngx.unescape_uri(s)
end -- /usr/local/openresty/lualib/resty/core/uri.lua:46


---@return string @type
function ngx.decode_base64(s)
end -- /usr/local/openresty/lualib/resty/core/base64.lua:72

--- ngx.re
ngx.re = {}

---@return string @type
function ngx.re.find(subj, regex, opts, ctx, nth)
end -- /usr/local/openresty/lualib/resty/core/regex.lua:583


---@return string @type
function ngx.re.gsub(subj, regex, replace, opts)
end -- /usr/local/openresty/lualib/resty/core/regex.lua:1065


---@return string @type
function ngx.re.match(subj, regex, opts, ctx, res)
end -- /usr/local/openresty/lualib/resty/core/regex.lua:578


---@return string @type
function ngx.re.sub(subj, regex, replace, opts)
end -- /usr/local/openresty/lualib/resty/core/regex.lua:1060


---@return string @type
function ngx.re.gmatch(subj, regex, opts)
end -- /usr/local/openresty/lualib/resty/core/regex.lua:648


---@return string @type
function ngx.sleep(seconds)
end

---@return string @type
function ngx.redirect(url)
end

---@return string @type
function ngx.get_today()
end

---at
---@param delay number @fractional seconds like 0.001 to mean 1 millisecond
---@param callback fun(is_premature:boolean, user_arg1, user_arg2) @ can be any Lua function, which will be invoked later in a background "light thread" after the delay specified.
---@param user_arg1 table|string|number
---@param user_arg2 table|string|number
function ngx.timer.at(delay, callback, user_arg1, user_arg2, ...)
end
---every timer will be created every delay seconds until the current Nginx worker process starts exiting.
---@param delay number @fractional seconds like 0.001 to mean 1 millisecond, cannot be zero,
---@param callback fun(is_premature:boolean, user_arg1, user_arg2) @ can be any Lua function, which will be invoked later in a background "light thread" after the delay specified.
---@param user_arg1 table|string|number
---@param user_arg2 table|string|number
function ngx.timer.every(delay, callback, user_arg1, user_arg2, ...)
end

---@class ngx.shared.DICT
local _ndic = {}
---@param key string
---@return string, number @ value, uint32 flag
function _ndic:get(key)
	return
end

---@param key string
---@return string, number, boolean @ value, flag, is-staled
function _ndic:get_stale(key)
	return
end

---set Unconditionally sets a key-value pair into the shm-based dictionary ngx.shared.DICT. Returns three values:
---@param key string
---@param value string
---@param exptime_seconds number @ second
---@param flags number @flags argument specifies a user flags value associated with the entry to be stored. It can also be retrieved later with the value.
---@return boolean, string, boolean @success: boolean value to indicate whether the key-value pair is stored or not, err: textual error message, can be "no memory". forcible: a boolean value to indicate whether other valid items have been removed forcibly when out of storage in the shared memory zone.
function _ndic:set(key, value, exptime_seconds, flags)
	return
end

---safe_set Similar to the set method, but never overrides the (least recently used) unexpired items in the store when running out of storage in the shared memory zone. In this case, it will immediately return nil and the string "no memory".
---@param key string
---@return boolean, string @ok, err
function _ndic:safe_set(key, value, exptime, flags)
	return
end

---add Just like the set method, but only stores the key-value pair into the dictionary ngx.shared.DICT if the key does not exist.
---@param key string
---@return boolean, string, boolean @success, err, forcible
function _ndic:add(key, value, exptime, flags)
	return
end

---safe_add Similar to the add method, but never overrides the (least recently used) unexpired items in the store when running out of storage in the shared memory zone. In this case, it will immediately return nil and the string "no memory".
---@param key string
---@return boolean, string @ ok, err
function _ndic:safe_add(key, value, exptime, flags)
	return
end

---@param key string
---@return boolean, string,boolean @success, err, forcible
function _ndic:replace(key, value, exptime, flags)
	return
end

---delete Unconditionally removes the key-value pair from the shm-based dictionary ngx.shared.DICT.
---@param key string
---@return boolean, string, boolean @success, err, forcible. Always return true while key is not null
function _ndic:delete(key)
	return
end

---incr Like the add method, it also overrides the (least recently used) unexpired items in the store when running out of storage in the shared memory zone
---@param key string
---@param value number @ number to add with current val
---@param init number @ if the init argument is not specified or takes the value nil, this method will return nil and the error string "not found", if the init argument takes a number value, this method will create a new key with the value init + value.
---@param init_ttl number @ The optional init_ttl argument specifies expiration time (in seconds) of the value when it is initialized via the init argument. The time resolution is 0.001 seconds. If init_ttl takes the value 0 (which is the default), then the item will never expire. This argument cannot be provided without providing the init argument as well, and has no effect if the value already exists (e.g., if it was previously inserted via set or the likes).
---@return number, string, boolean @ newval, err, forcible?
function _ndic:incr(key, value, init, init_ttl)
	return
end

---@param key string
---@return string
function _ndic:lpush(key, value)
	return
end

---@param key string
---@return string
function _ndic:rpush(key, value)
	return
end

---@param key string
---@return string
function _ndic:lpop(key)
	return
end

---@param key string
---@return string
function _ndic:rpop(key)
	return
end

---@param key string
---@return string
function _ndic:llen(key)
	return
end

---@param key string
function _ndic:flush_all()
	return
end

---@param max_count number
---@return number @flushed item number
function _ndic:flush_expired(max_count)
	return
end

---@param max_count number
---@return string[]
function _ndic:get_keys(max_count)
	return
end

---@return number
function _ndic:free_space()
	return
end
---@return number
function _ndic:capacity()
	return
end


-- Any name could be called
local mt_mock_method = {
	__index = function()
		return function()
			return nil
			--return 'mock called'
		end
	end
}

-- Any property could be called
local mt_mock_cache = {
	__index = function()
		local new_obj = {}
		setmetatable(new_obj, mt_mock_method)
		return new_obj
	end
}
setmetatable(ngx.shared, mt_mock_cache)

---@class ffi
local ffi = { C = {} }

---free
---@param cdata userdata
function ffi.C.free(cdata)
end

---printf
function ffi.C.printf(...)
end

---malloc
---@param num number
function ffi.C.malloc(num)
end

---load This loads the dynamic library given by name and returns a new C library namespace which binds to its symbols.
---@param lib_path string @ If name is a path, the library is loaded from this path. Otherwise name is canonicalized in a system-dependent way and searched in the default search path for dynamic libraries: On POSIX systems, if the name contains no dot, the extension .so is appended. Also, the lib prefix is prepended if necessary. So ffi.load("z") looks for "libz.so" in the default shared library search path. On Windows systems, if the name contains no dot, the extension .dll is appended. So ffi.load("ws2_32") looks for "ws2_32.dll" in the default DLL search path.
---@param is_load_globally boolean @  On POSIX systems, if global is true, the library symbols are loaded into the global namespace, too.
function ffi.load(lib_path, is_load_globally)
end

---typeof Creates a ctype object for the given ct. This function is especially useful to parse a cdecl only once and then use the resulting ctype object as a constructor.
---@param c_type_str string
---@return userdata @ c/c++ data type
function ffi.typeof(c_type_str)
end

---cast Creates a scalar cdata object for the given ct. The cdata object is initialized with init using the "cast" variant of the C type conversion rules.-This functions is mainly useful to override the pointer compatibility checks or to convert pointers to addresses or vice versa.
---@param c_type userdata
---@param data string|number|table
---@return userdata
function ffi.cast(c_type, data)
end

---metatype Creates a ctype object for the given ct and associates it with a metatable. Only struct/union types, complex numbers and vectors are allowed. Other types may be wrapped in a struct, if needed.
---@param c_type userdata
---@param metatable table
function ffi.metatype(c_type, metatable)
end

---gc Associates a finalizer with a pointer or aggregate cdata object. The cdata object is returned unchanged. This function allows safe integration of unmanaged resources into the automatic memory management of the LuaJIT garbage collector. Typical usage:
---@param cdata userdata
---@param c_method_finalizer fun @c_method
function ffi.gc(cdata, c_method_finalizer)
end

---sizeof Returns the size of ct in bytes. Returns nil if the size is not known (e.g. for "void" or function types). Requires nelem for VLA/VLS types, except for cdata objects.
---@param c_type userdata
---@param cdata userdata|userdata[]
---@return userdata @ number of c type
function ffi.sizeof(c_type, cdata)
end

---string
---@param ptr userdata
---@param length number
---@return string
function ffi.string(ptr, length)
end

---new Creates a cdata object for the given c-type string.
---@param c_type_str string
---@param cdata userdata @convert cdata to c-type
---@return userdata @ managed c-data
function ffi.new(c_type_str, cdata)
end

---cdef Adds multiple C declarations for types or external symbols (named variables or functions). def must be a Lua string.
---@param str string
function ffi.cdef(str)
end

return ngx
