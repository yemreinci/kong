local policy_cluster = require "kong.plugins.rate-limiting.policies.cluster"
local timestamp = require "kong.tools.timestamp"
local reports = require "kong.reports"
local redis = require "resty.redis"
local memcached = require "resty.memcached"

local kong = kong
local pairs = pairs
local null = ngx.null
local shm = ngx.shared.kong_rate_limiting_counters
local fmt = string.format


local EMPTY_UUID = "00000000-0000-0000-0000-000000000000"


local function is_present(str)
  return str and str ~= "" and str ~= null
end


local function get_service_and_route_ids(conf)
  conf = conf or {}

  local service_id = conf.service_id
  local route_id   = conf.route_id

  if not service_id or service_id == null then
    service_id = EMPTY_UUID
  end

  if not route_id or route_id == null then
    route_id = EMPTY_UUID
  end

  return service_id, route_id
end


local get_local_key = function(conf, identifier, period, period_date)
  local service_id, route_id = get_service_and_route_ids(conf)

  return fmt("ratelimit:%s:%s:%s:%s:%s", route_id, service_id, identifier,
             period_date, period)
end


local sock_opts = {}


local EXPIRATION = require "kong.plugins.rate-limiting.expiration"


local function get_redis_connection(conf)
  local red = redis:new()
  red:set_timeout(conf.redis_timeout)
  -- use a special pool name only if redis_database is set to non-zero
  -- otherwise use the default pool name host:port
  sock_opts.pool = conf.redis_database and
                    conf.redis_host .. ":" .. conf.redis_port ..
                    ":" .. conf.redis_database
  local ok, err = red:connect(conf.redis_host, conf.redis_port,
                              sock_opts)
  if not ok then
    kong.log.err("failed to connect to Redis: ", err)
    return nil, err
  end

  local times, err = red:get_reused_times()
  if err then
    kong.log.err("failed to get connect reused times: ", err)
    return nil, err
  end

  if times == 0 then
    if is_present(conf.redis_password) then
      local ok, err = red:auth(conf.redis_password)
      if not ok then
        kong.log.err("failed to auth Redis: ", err)
        return nil, err
      end
    end

    if conf.redis_database ~= 0 then
      -- Only call select first time, since we know the connection is shared
      -- between instances that use the same redis database

      local ok, err = red:select(conf.redis_database)
      if not ok then
        kong.log.err("failed to change Redis database: ", err)
        return nil, err
      end
    end
  end

  return red
end

local function get_memcache_connection(conf)
  local memc, err = memcached:new()
  if not memc then
    kong.log.err("failed to instantiate memc: ", err)
    return
  end

  memc:set_timeout(1000) -- 1 sec

  local ok, err = memc:connect("127.0.0.1", 5701) -- TODO read from config
  if not ok then
    kong.log.err("failed to connect: ", err)
    return
  end

  local times, err = memc:get_reused_times()
  if err then
    kong.log.err("failed to get connect reused times: ", err)
    return nil, err
  end

  return memc
end

local function int_to_bytes(val)
  local t = {}
  while val > 0 do
    local x = val % 256;
    table.insert(t, 1, string.char(x))
    val = (val - x) / 256
  end
  return table.concat(t)
end

local function bytes_to_int(s)
  if s == nil then
    return 0
  end
  local val = 0
  for i = 1, #s do
    val = val * 256 + string.byte(s, i)
  end
  return val
end

return {
  ["local"] = {
    increment = function(conf, limits, identifier, current_timestamp, value)
      local periods = timestamp.get_timestamps(current_timestamp)
      for period, period_date in pairs(periods) do
        if limits[period] then
          local cache_key = get_local_key(conf, identifier, period, period_date)
          local newval, err = shm:incr(cache_key, value, 0, EXPIRATION[period])
          if not newval then
            kong.log.err("could not increment counter for period '", period, "': ", err)
            return nil, err
          end
        end
      end

      return true
    end,
    usage = function(conf, identifier, period, current_timestamp)
      local periods = timestamp.get_timestamps(current_timestamp)
      local cache_key = get_local_key(conf, identifier, period, periods[period])

      local current_metric, err = shm:get(cache_key)
      if err then
        return nil, err
      end

      return current_metric or 0
    end
  },
  ["cluster"] = {
    increment = function(conf, limits, identifier, current_timestamp, value)
      local db = kong.db
      local service_id, route_id = get_service_and_route_ids(conf)
      local policy = policy_cluster[db.strategy]

      local ok, err = policy.increment(db.connector, limits, identifier,
                                       current_timestamp, service_id, route_id,
                                       value)

      if not ok then
        kong.log.err("cluster policy: could not increment ", db.strategy,
                     " counter: ", err)
      end

      return ok, err
    end,
    usage = function(conf, identifier, period, current_timestamp)
      local db = kong.db
      local service_id, route_id = get_service_and_route_ids(conf)
      local policy = policy_cluster[db.strategy]

      local row, err = policy.find(identifier, period, current_timestamp,
                                   service_id, route_id)

      if err then
        return nil, err
      end

      if row and row.value ~= null and row.value > 0 then
        return row.value
      end

      return 0
    end
  },
  ["redis"] = {
    increment = function(conf, limits, identifier, current_timestamp, value)
      local red, err = get_redis_connection(conf)
      if not red then
        return nil, err
      end

      local periods = timestamp.get_timestamps(current_timestamp)
      red:init_pipeline()
      for period, period_date in pairs(periods) do
        if limits[period] then
          local cache_key = get_local_key(conf, identifier, period, period_date)

          red:eval([[
            local key, value, expiration = KEYS[1], tonumber(ARGV[1]), ARGV[2]

            if redis.call("incrby", key, value) == value then
              redis.call("expire", key, expiration)
            end
          ]], 1, cache_key, value, EXPIRATION[period])
        end
      end
      local _, err = red:commit_pipeline()
      if err then
        kong.log.err("failed to commit increment pipeline in Redis: ", err)
        return nil, err
      end

      local ok, err = red:set_keepalive(10000, 100)
      if not ok then
        kong.log.err("failed to set Redis keepalive: ", err)
        return nil, err
      end

      return true
    end,
    usage = function(conf, identifier, period, current_timestamp)
      local red, err = get_redis_connection(conf)
      if not red then
        return nil, err
      end

      reports.retrieve_redis_version(red)

      local periods = timestamp.get_timestamps(current_timestamp)
      local cache_key = get_local_key(conf, identifier, period, periods[period])

      local current_metric, err = red:get(cache_key)
      if err then
        return nil, err
      end

      if current_metric == null then
        current_metric = nil
      end

      local ok, err = red:set_keepalive(10000, 100)
      if not ok then
        kong.log.err("failed to set Redis keepalive: ", err)
      end

      return current_metric or 0
    end
  },
  ["memcached"] = {
    increment = function(conf, limits, identifier, current_timestamp, value)
      local memc, err = get_memcache_connection(conf)
      if not memc then
        return nil, err
      end

      local periods = timestamp.get_timestamps(current_timestamp)

      kong.log.notice("memc: ", memc)

      for period, period_date in pairs(periods) do
        if limits[period] then
          kong.log.notice("period: ", period, " ", period_date)

          local cache_key = get_local_key(conf, identifier, period, period_date)
          
          kong.log.notice("value: ", value)
          local ok, err = memc:add(cache_key, int_to_bytes(value), EXPIRATION[period])

          if err == "NOT_STORED" then
            local new_value, err = memc:incr(cache_key, value);
            if not new_value then
              kong.log.err("incr err: ", err)
              return nil, err
            end
            kong.log.notice("incremented: ", new_value)
          elseif err then
            kong.log.err("add err: ", err)
            return nil, err
          end

        end
      end
      
      local ok, err = memc:set_keepalive(10000, 100) -- TODO is this config OK for us?

      if not ok then
        kong.log.err("failed to set memcache keepalive: ", err)
        return nil, err
      end

      return true
    end,
    usage = function(conf, identifier, period, current_timestamp)
      local memc, err = get_memcache_connection(conf)
      if not memc then
        return nil, err
      end

      local periods = timestamp.get_timestamps(current_timestamp)
      local cache_key = get_local_key(conf, identifier, period, periods[period])

      local current_metric_bytes, flags, err = memc:get(cache_key)
      if err then
        kong.log.err("get err: ", err)
        return nil, err
      end

      local current_metric = bytes_to_int(current_metric_bytes)

      local ok, err = memc:set_keepalive(10000, 100)
      if not ok then
        kong.log.err("failed to set memcache keepalive: ", err)
      end

      kong.log.notice("current metric: ", cache_key, " ", current_metric)

      return current_metric or 0
    end
  }
}
