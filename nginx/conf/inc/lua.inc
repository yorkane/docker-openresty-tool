lua_max_running_timers 2048; # Don't open too much timers
lua_check_client_abort on;
lua_socket_log_errors off;
lua_socket_pool_size 1024;
lua_socket_keepalive_timeout 60s;
lua_socket_connect_timeout 10s; #default 60s
lua_socket_send_timeout 10s; #default 60s
lua_socket_read_timeout 10s; #default 60s