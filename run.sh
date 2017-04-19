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


TNT_HOSTS=$(echo $TNT_HOSTS | tr "," "\n" | tr -d " ")

TNT_HOSTS_STR=""

for tnt_host in $TNT_HOSTS; do
    TNT_HOST_STR=`echo -e "$TNT_HOST_STR,\"$tnt_host\""`
done

# remove leading comma
TNT_HOST_STR=`echo "$TNT_HOST_STR" | cut -c 2-`

if [ -z "$TNT_HOST_STR" ]; then
    TNT_HOST_STR="tnt_hosts=nil"
else
    TNT_HOST_STR="tnt_hosts={$TNT_HOST_STR}"
fi

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
        $TNT_HOST_STR

        sentinel.watch({user="guest", tnt_hosts=tnt_hosts});
    }
}
EOF

exec openresty -p /app -c nginx.conf
