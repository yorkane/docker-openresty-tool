-- use this to overcome env.lua settings
return {
	auth_conf = {
        user = { 
            -- user name and password, will be override by env.OR_AUTH_USER
            -- admin2 = "admin2password", 
            -- root1 = "root1password" 
        }, 
        ip = {
            -- will be override by env.OR_AUTH_IP
            -- ["192.168.1.3"] = 1, -- auth free to access
            -- ["FE60:0:0:07C:FE:0:0:5CA8"] = 0, -- forbid to access
        },
        ua = {
            -- ['curl/8.4.0'] = 1
        }
    },
	_VERSION = 0.1
}