local ipairs = ipairs
local table_insert = table.insert
local table_sort = table.sort
local pcall = pcall
local require = require
require("orange.lib.globalpatches")()
local ck = require("orange.lib.cookie")
local utils = require("orange.utils.utils")
local config_loader = require("orange.utils.config_loader")
local dao = require("orange.store.dao")
local dns_client = require("resty.dns.client")
local ERR = ngx.ERR

local HEADERS = {
    PROXY_LATENCY = "X-Orange-Proxy-Latency",
    UPSTREAM_LATENCY = "X-Orange-Upstream-Latency",
}

local loaded_plugins = {}

local function load_node_plugins(config, store)
    ngx.log(ngx.DEBUG, "Discovering used plugins")

    local sorted_plugins = {}
    local plugins = config.plugins

    for _, v in ipairs(plugins) do
        local loaded, plugin_handler = utils.load_module_if_exists("orange.plugins." .. v .. ".handler")
        if not loaded then
            ngx.log(ngx.WARN, "The following plugin is not installed or has no handler: " .. v)
        else
            ngx.log(ngx.DEBUG, "Loading plugin: " .. v)
            table_insert(sorted_plugins, {
                name = v,
                handler = plugin_handler(store),
            })
        end
    end

    table_sort(sorted_plugins, function(a, b)
        local priority_a = a.handler.PRIORITY or 0
        local priority_b = b.handler.PRIORITY or 0
        return priority_a > priority_b
    end)

    return sorted_plugins
end

-- ms
local function now()
    return ngx.now() * 1000
end

-- ########################### Orange #############################
local Orange = {}

-- 执行过程:
-- 加载配置
-- 实例化存储store
-- 加载插件
-- 插件排序
function Orange.init(options)
    options = options or {}
    local store, config
    local status, err = pcall(function()
        local conf_file_path = options.config
        config = config_loader.load(conf_file_path)
        local store_type = config.store
        local modname = "orange.store." .. store_type .. ".store"
        local data_source_key = "store_" .. store_type
        ngx.log(ERR, "loading from data source:" .. data_source_key)
        store = require(modname)(config[data_source_key])
        loaded_plugins = load_node_plugins(config, store)
        ngx.update_time()
        config.orange_start_at = ngx.now()
    end)

    if not status or err then
        ngx.log(ERR, "Startup error: " .. err)
        os.exit(1)
    end

    local consul = require("orange.plugins.consul_balancer.consul_balancer")
    consul.set_shared_dict_name("consul_upstream", "consul_upstream_watch")
    Orange.data = {
        store = store,
        config = config,
        consul = consul
    }

    -- init dns_client
    assert(dns_client.init())

    return config, store
end

function Orange.init_worker()
    -- 仅在 init_worker 阶段调用，初始化随机因子，仅允许调用一次
    math.randomseed()
    -- 初始化定时器，清理计数器等
    if Orange.data and Orange.data.store then
        local ok, err = ngx.timer.at(0, function(premature, store, config)
            local available_plugins = config.plugins
            for _, v in ipairs(available_plugins) do
                local load_success = dao.load_data(store, v)
                if not load_success then
                    os.exit(1)
                end

                if v == "consul_balancer" then
                    for ii,p in ipairs(loaded_plugins) do
                        if v == p.name then
                            p.handler.db_ready()
                        end
                    end
                end
            end
            if Orange.data.config.store == "etcd" then
                local register_rotate_time = Orange.data.config.store_etcd.register.register_rotate_time
                local ok , err = dao.register_node(store, config, register_rotate_time)
                if not ok then
                    ngx.log(ERR, "failed to register mysql to etcd. err:" .. err)
                    os.exit(1)
                end
                if Orange.data.config.store == "etcd" then
                    local register_rotate_time = Orange.data.config.store_etcd.register.register_rotate_time
                    local handler
                    handler = function (premature, store, config)
                        if premature then
                            return
                        end

                        local ok , err = dao.register_node(store, config, register_rotate_time)
                        if not ok then
                            return
                        end
                    end
                    local ok, err = ngx.timer.every(register_rotate_time, handler, Orange.data.store,
                        Orange.data.config)
                    if not ok then
                        ngx.log(ERR, "failed to create the timer: ", err)
                        return
                    end
                end
            end
        end, Orange.data.store, Orange.data.config)

        if not ok then
            ngx.log(ERR, "failed to create the timer: ", err)
            return os.exit(1)
        end
    end

    for _, plugin in ipairs(loaded_plugins) do
        plugin.handler:init_worker()
    end
end

function Orange.init_cookies()
    ngx.ctx.__cookies__ = nil

    local COOKIE, err = ck:new()
    if not err and COOKIE then
        ngx.ctx.__cookies__ = COOKIE
    end
end

function Orange.redirect()
    ngx.ctx.ORANGE_REDIRECT_START = now()

    for _, plugin in ipairs(loaded_plugins) do
        plugin.handler:redirect()
    end

    local now_time = now()
    ngx.ctx.ORANGE_REDIRECT_TIME = now_time - ngx.ctx.ORANGE_REDIRECT_START
    ngx.ctx.ORANGE_REDIRECT_ENDED_AT = now_time
end

function Orange.rewrite()
    ngx.ctx.ORANGE_REWRITE_START = now()

    for _, plugin in ipairs(loaded_plugins) do
        plugin.handler:rewrite()
    end

    local now_time = now()
    ngx.ctx.ORANGE_REWRITE_TIME = now_time - ngx.ctx.ORANGE_REWRITE_START
    ngx.ctx.ORANGE_REWRITE_ENDED_AT = now_time
end


function Orange.access()
    ngx.ctx.ORANGE_ACCESS_START = now()

    for _, plugin in ipairs(loaded_plugins) do
        plugin.handler:access()
    end

    local now_time = now()
    ngx.ctx.ORANGE_ACCESS_TIME = now_time - ngx.ctx.ORANGE_ACCESS_START
    ngx.ctx.ORANGE_ACCESS_ENDED_AT = now_time
    ngx.ctx.ORANGE_PROXY_LATENCY = now_time - ngx.req.start_time() * 1000
    ngx.ctx.ACCESSED = true
end

function Orange.balancer()
    for _, plugin in ipairs(loaded_plugins) do
        plugin.handler:balancer()
    end
end

function Orange.header_filter()

    if ngx.ctx.ACCESSED then
        local now_time = now()
        ngx.ctx.ORANGE_WAITING_TIME = now_time - ngx.ctx.ORANGE_ACCESS_ENDED_AT -- time spent waiting for a response from upstream
        ngx.ctx.ORANGE_HEADER_FILTER_STARTED_AT = now_time
    end

    for _, plugin in ipairs(loaded_plugins) do
        plugin.handler:header_filter()
    end

    if ngx.ctx.ACCESSED then
        ngx.header[HEADERS.UPSTREAM_LATENCY] = ngx.ctx.ORANGE_WAITING_TIME
        ngx.header[HEADERS.PROXY_LATENCY] = ngx.ctx.ORANGE_PROXY_LATENCY
    end
end

function Orange.body_filter()
    for _, plugin in ipairs(loaded_plugins) do
        plugin.handler:body_filter()
    end

    if ngx.ctx.ACCESSED then
        if ngx.ctx.ORANGE_HEADER_FILTER_STARTED_AT == nil then
            ngx.ctx.ORANGE_HEADER_FILTER_STARTED_AT = 0
        end
        ngx.ctx.ORANGE_RECEIVE_TIME = now() - ngx.ctx.ORANGE_HEADER_FILTER_STARTED_AT
    end
end

function Orange.log()
    for _, plugin in ipairs(loaded_plugins) do
        plugin.handler:log()
    end
end

return Orange
