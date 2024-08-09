-- global init here
local env = require('env')
if env.OR_ACME then
require("resty.acme.autossl").init({
	-- setting the following to true
	-- implies that you read and accepted https://letsencrypt.org/repository/
	tos_accepted = true,
	-- uncomment following for first time setup
	staging = true,
	-- uncomment following to enable RSA + ECC double cert
	-- domain_key_types = { 'rsa', 'ecc' },
	-- uncomment following to enable tls-alpn-01 challenge
	-- enabled_challenge_handlers = { 'http-01', 'tls-alpn-01' },
	account_key_path = "/usr/local/openresty/nginx/conf/cert/account.key",
	account_email = "youemail@youdomain.com",
	domain_whitelist = { "example.com" },
})
end