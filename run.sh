#!/bin/sh
set -e

# allow the container to be started with `--user`
if [ "$0" = '/run.sh' -a "$(id -u)" = '0' ]; then
    chown -R openresty /app
    exec su-exec openresty "/run.sh"
fi

# allow the container to be started with `--user`
if [ "$0" = 'openresty' -a "$(id -u)" = '0' ]; then
    chown -R openresty /var/lib/tarantool
    exec su-exec openresty "$0" "$@"
fi


echo "arg: $0"

if [ -z "$UPSTREAMS" ]; then
    echo "Please set UPSTREAMS"
    exit 1
fi

UPSTREAMS=$(echo $UPSTREAMS | tr "," "\n" | tr -d " ")

UPSTREAM_STR=""

for upstream in $UPSTREAMS; do
    UPSTREAM_STR=`echo -e "$UPSTREAM_STR\n        server $upstream;"`
done

mkdir -p /app/logs

cat > /app/nginx.conf <<-EOF
daemon off;
error_log stderr;
events { worker_connections 1024; use epoll; }
stream {
    lua_shared_dict tarantool 10m;

    upstream tarantool {
        $UPSTREAM_STR
    }

    server {
        listen 3301;
        proxy_pass tarantool;
        proxy_connect_timeout 1s;
        proxy_timeout 30m;
    }

    init_worker_by_lua_block {
        ngx.log(ngx.ERR, "path: " .. package.path)
        local sentinel = require("tarantool-sentinel")
        sentinel.watch({user="guest"});
    }
}
EOF

exec openresty -p /app -c nginx.conf
