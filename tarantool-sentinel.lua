local upstream = require "ngx.upstream"
local mp = require "MessagePack"
local tnt = require "tarantool"

local function parse_host_port(url)
    local host = nil
    local port = nil

    local rest = string.gsub(url, ":([^:%]]*)$",
                             function(p) port=tonumber(p); return "" end)

    host = rest

    return host, port
end

local function get_peers(upstream_name)
    -- returns a list of peers. Example:
    -- {{weight=1,
    --   id=0,
    --   conns=0,
    --   fails=0,
    --   current_weight=0,
    --   backup=true,
    --   down=true,
    --   fail_timeout=10,
    --   effective_weight=1,
    --   name="127.0.0.1:3302",
    --   max_fails=1}}

    local result = upstream.get_primary_peers(upstream_name)

    if not result then
        error("failed to get primary peers in upstream " .. upstream_name)
    end

    local backup_peers = upstream.get_backup_peers(upstream_name)

    if not backup_peers then
        error("failed to get backup peers in upstream " .. upstream_name)
    end

    for i=1,#result do
        result[i].backup = false
    end

    for i=1,#backup_peers do
        backup_peers[i].backup = true
        table.insert(result, backup_peers[i])
    end

    for i=1,#result do
        if result[i].down == nil then
            result[i].down = false
        end
    end

    return result
end

local function get_readonly(tar)
    local res, err = tar:eval("return box.cfg.read_only", { })

    if res == nil then
        return nil
    end

    return res[1]
end

local function set_readonly(tar, is_readonly)
    local res, err = tar:eval("box.cfg{read_only=" .. tostring(is_readonly) .. "}", { })

    if res == nil then
        return nil
    end

    return true
end

local function dict_get(dict, key)
    local raw_value = dict:get(key)

    if raw_value == nil then
        return nil
    end

    return mp.unpack(raw_value)
end

local function dict_set(dict, key, value)
    dict:set(key, mp.pack(value))
end

local function check(user, password, tnt_hosts)
    local peers = get_peers("tarantool")
    local connections = {}
    local dict = ngx.shared.tarantool

    local leader = dict_get(dict, "leader")
    local failure_count = dict_get(dict, "failure_count") or {}

    for i,peer in ipairs(peers) do
        local host, port = parse_host_port(peer.name)
        port = port or 3301

        if tnt_hosts then
            host, port = parse_host_port(tnt_hosts[i])
            port = port or 3301
        end

        local tar, err = tnt:new({
            host = host,
            port = port,
            user = user,
            password = password,
            socket_timeout = 500,
            show_version_header = false
        })
        tar:set_timeout(500)

        local res, err = tar:connect()
        if res == nil then
            ngx.log(ngx.ERR, "Failed to connect to " .. host .. ":" .. port .. " : "..err)
            failure_count[i] = (failure_count[i] or 0) + 1
        else
            connections[i] = tar
        end
    end

    local healthy = {}

    -- Detect peer status using ping
    for i,peer in ipairs(peers) do
        local tar = connections[i]


        if tar ~= nil then
            local res = tar:ping()
            if res == 'PONG' then
                failure_count[i] = 0
            else
                failure_count[i] = (failure_count[i] or 0) + 1
            end
        end

        healthy[i] = (failure_count[i] or 0) < peer.max_fails
    end

    dict_set(dict, "failure_count", failure_count)

    local readonly = {}

    if leader ~= nil and not healthy[leader] then
        leader = nil
    end

    -- Before initial leader election all peers should be
    -- read only to reduce probability of races.
    for i,peer in ipairs(peers) do
        local tar = connections[i]
        if tar ~= nil then
            local is_readonly = get_readonly(tar)

            readonly[i] = is_readonly

            if not is_readonly and leader ~= i then
                ngx.log(ngx.ERR, "Setting peer readonly: " .. peer.name)
                set_readonly(tar, true)
                readonly[i] = true
            end
        end
    end

    -- Elect a leader
    if leader == nil then
        for i,peer in ipairs(peers) do
            tar = connections[i]
            if healthy[i] and tar ~= nil and leader == nil then
                ngx.log(ngx.ERR, "Setting leader to : " .. peer.name)
                leader = i
                dict_set(dict, "leader", leader)

                ngx.log(ngx.ERR, "Setting peer read/write: " .. peer.name)
                set_readonly(tar, false)

                if peer.down then
                    ngx.log(ngx.ERR, "Setting peer up: " .. peer.name)
                    upstream.set_peer_down("tarantool", peer.backup, peer.id, false)
                end
            end
        end
    end

    -- After electing a leader, mark non-leader nodes as down
    for i,peer in ipairs(peers) do
        if i ~= leader and not peer.down then
            ngx.log(ngx.ERR, "Setting peer down: " .. peer.name)
            upstream.set_peer_down("tarantool", peer.backup, peer.id, true)
        end
    end

    for i,tar in ipairs(connections) do
        tar:disconnect()
    end
end

local function watch(params)
    if params == nil then
        params = {}
    end
    local user = params.user
    local password = params.password
    local delay = params.delay or 5
    local tnt_hosts = params.tnt_hosts

    -- Work around for tarantool 1.6 that doesn't support auth packets
    -- with 'guest' user
    if user == "guest" then
        user = nil
    end

    local function timer()
        local status, err = pcall(function() check(user, password, tnt_hosts) end)
        if err then
            ngx.log(ngx.ERR, err)
        end
        ngx.timer.at(delay, timer)
    end

    ngx.timer.at(0, timer)
end


return {watch=watch}
