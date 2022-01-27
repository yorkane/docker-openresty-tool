gzip on;  #Development turn off
gzip_comp_level    6; # level 4-6 are the most efficiency settings
gzip_min_length  256;
gzip_buffers 16 64k;
gzip_types      application/json application/x-javascript text/css application/javascript application/xml+rss text/javascript text/plain text/xml application/vnd.ms-fontobject application/x-font-opentype application/x-font-truetype application/x-font-ttf application/xml font/eot font/opentype font/otf image/vnd.microsoft.icon; #defualt contains text/html font/ttf font/otf image/svg+xml font/woff;
gzip_proxied any;