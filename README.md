# A proxy with hot-warm failover for Tarantool

The sentinel is an add-on for OpenResty (nginx) that uses tcp stream
proxy to switch between multiple upstream Tarantool instances. In
addition to just proxying, the sentinel actively monitors Tarantool,
and turns "non-leader" instances read only.

The sentinel handles the usual problem of updating tuples with the
same primary key on 2 master-master instances. In a usual case it
leads to broken replication. But since sentinel makes keeps one
instance read/write, this scenario is unlikely.

## Requirement

This proxy requires a patched version of OpenResty with support for
Lua stream API and a modified proxy handler.

- See `proxy_upstream_connclose.diff` for the modifications of proxy handler
- https://github.com/tarantool/stream-lua-nginx-module.git - a patched version of official stream management module
- https://github.com/tarantool/lua-stream-upstream-nginx-module.git - api for managing tcp upstreams

## Usage

Due to complicated build procedures, it is a good idea to just use Docker:

```sh
docker build -t sentinel .
```

Assuming you have 2 instances of Tarantool in master-master running on localhost:3301 and localhost:3302, to run a proxy do as follows:

```sh
docker run --rm -t -i -p3303:3301 -e UPSTREAMS=localhost:3301,localhost:3302 sentinel
```

Then do:

```sh
tarantoolctl connect localhost:3301
```
