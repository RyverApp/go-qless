-- Current SHA: 8993d12c1f6d413bf4e9275b36f15d3499ceb0dc
-- This is a generated file
local Qless = {
  ns = 'ql:'
}

local QlessQueue = {
  ns = Qless.ns .. 'q:'
}
QlessQueue.__index = QlessQueue

local QlessWorker = {
  ns = Qless.ns .. 'w:'
}
QlessWorker.__index = QlessWorker

local QlessJob = {
  ns = Qless.ns .. 'j:'
}
QlessJob.__index = QlessJob

local QlessRecurringJob = {}
QlessRecurringJob.__index = QlessRecurringJob

local QlessResource = {
  ns = Qless.ns .. 'rs:'
}
QlessResource.__index = QlessResource;

Qless.config = {}

local function extend_table(target, other)
  for i, v in ipairs(other) do
    table.insert(target, v)
  end
end

function Qless.publish(channel, message)
  redis.call('publish', Qless.ns .. channel, message)
end

function Qless.job(jid)
  assert(jid, 'Job(): no jid provided')
  local job = {}
  setmetatable(job, QlessJob)
  job.jid = jid
  return job
end

function Qless.recurring(jid)
  assert(jid, 'Recurring(): no jid provided')
  local job = {}
  setmetatable(job, QlessRecurringJob)
  job.jid = jid
  return job
end

function Qless.resource(rid)
  assert(rid, 'Resource(): no rid provided')
  local res = {}
  setmetatable(res, QlessResource)
  res.rid = rid
  return res
end

function Qless.failed(group, start, limit)
  start = assert(tonumber(start or 0),
    'Failed(): Arg "start" is not a number: ' .. (start or 'nil'))
  limit = assert(tonumber(limit or 25),
    'Failed(): Arg "limit" is not a number: ' .. (limit or 'nil'))

  if group then
    return {
      total = redis.call('llen', 'ql:f:' .. group),
      jobs  = redis.call('lrange', 'ql:f:' .. group, start, start + limit - 1)
    }
  else
    local response = {}
    local groups = redis.call('smembers', 'ql:failures')
    for index, group in ipairs(groups) do
      response[group] = redis.call('llen', 'ql:f:' .. group)
    end
    return response
  end
end

function Qless.jobs(now, state, ...)
  assert(state, 'Jobs(): Arg "state" missing')
  if state == 'complete' then
    local offset = assert(tonumber(arg[1] or 0),
      'Jobs(): Arg "offset" not a number: ' .. tostring(arg[1]))
    local count  = assert(tonumber(arg[2] or 25),
      'Jobs(): Arg "count" not a number: ' .. tostring(arg[2]))
    return redis.call('zrevrange', 'ql:completed', offset,
      offset + count - 1)
  else
    local name  = assert(arg[1], 'Jobs(): Arg "queue" missing')
    local offset = assert(tonumber(arg[2] or 0),
      'Jobs(): Arg "offset" not a number: ' .. tostring(arg[2]))
    local count  = assert(tonumber(arg[3] or 25),
      'Jobs(): Arg "count" not a number: ' .. tostring(arg[3]))

    local queue = Qless.queue(name)
    if state == 'running' then
      return queue.locks.peek(now, offset, count)
    elseif state == 'stalled' then
      return queue.locks.expired(now, offset, count)
    elseif state == 'waiting' then
      return queue.work.peek(now, offset, count)
    elseif state == 'scheduled' then
      queue:check_scheduled(now, queue.scheduled.length())
      return queue.scheduled.peek(now, offset, count)
    elseif state == 'depends' then
      return queue.depends.peek(now, offset, count)
    elseif state == 'recurring' then
      return queue.recurring.peek('+inf', offset, count)
    else
      error('Jobs(): Unknown type "' .. state .. '"')
    end
  end
end

function Qless.track(now, command, jid)
  if command ~= nil then
    assert(jid, 'Track(): Arg "jid" missing')
    assert(Qless.job(jid):exists(), 'Track(): Job does not exist')
    if string.lower(command) == 'track' then
      Qless.publish('track', jid)
      return redis.call('zadd', 'ql:tracked', now, jid)
    elseif string.lower(command) == 'untrack' then
      Qless.publish('untrack', jid)
      return redis.call('zrem', 'ql:tracked', jid)
    else
      error('Track(): Unknown action "' .. command .. '"')
    end
  else
    local response = {
      jobs = {},
      expired = {}
    }
    local jids = redis.call('zrange', 'ql:tracked', 0, -1)
    for index, jid in ipairs(jids) do
      local data = Qless.job(jid):data()
      if data then
        table.insert(response.jobs, data)
      else
        table.insert(response.expired, jid)
      end
    end
    return response
  end
end

function Qless.tag(now, command, ...)
  assert(command,
    'Tag(): Arg "command" must be "add", "remove", "get" or "top"')

  if command == 'add' then
    local jid  = assert(arg[1], 'Tag(): Arg "jid" missing')
    local tags = redis.call('hget', QlessJob.ns .. jid, 'tags')
    if tags then
      tags = cjson.decode(tags)
      local _tags = {}
      for i,v in ipairs(tags) do _tags[v] = true end

      for i=2,#arg do
        local tag = arg[i]
        if _tags[tag] == nil or _tags[tag] == false then
          _tags[tag] = true
          table.insert(tags, tag)
        end
        redis.call('zadd', 'ql:t:' .. tag, now, jid)
        redis.call('zincrby', 'ql:tags', 1, tag)
      end

      redis.call('hset', QlessJob.ns .. jid, 'tags', cjson.encode(tags))
      return tags
    else
      error('Tag(): Job ' .. jid .. ' does not exist')
    end
  elseif command == 'remove' then
    local jid  = assert(arg[1], 'Tag(): Arg "jid" missing')
    local tags = redis.call('hget', QlessJob.ns .. jid, 'tags')
    if tags then
      tags = cjson.decode(tags)
      local _tags = {}
      for i,v in ipairs(tags) do _tags[v] = true end

      for i=2,#arg do
        local tag = arg[i]
        _tags[tag] = nil
        redis.call('zrem', 'ql:t:' .. tag, jid)
        redis.call('zincrby', 'ql:tags', -1, tag)
      end

      local results = {}
      for i,tag in ipairs(tags) do if _tags[tag] then table.insert(results, tag) end end

      redis.call('hset', QlessJob.ns .. jid, 'tags', cjson.encode(results))
      return results
    else
      error('Tag(): Job ' .. jid .. ' does not exist')
    end
  elseif command == 'get' then
    local tag    = assert(arg[1], 'Tag(): Arg "tag" missing')
    local offset = assert(tonumber(arg[2] or 0),
      'Tag(): Arg "offset" not a number: ' .. tostring(arg[2]))
    local count  = assert(tonumber(arg[3] or 25),
      'Tag(): Arg "count" not a number: ' .. tostring(arg[3]))
    return {
      total = redis.call('zcard', 'ql:t:' .. tag),
      jobs  = redis.call('zrange', 'ql:t:' .. tag, offset, offset + count - 1)
    }
  elseif command == 'top' then
    local offset = assert(tonumber(arg[1] or 0) , 'Tag(): Arg "offset" not a number: ' .. tostring(arg[1]))
    local count  = assert(tonumber(arg[2] or 25), 'Tag(): Arg "count" not a number: ' .. tostring(arg[2]))
    return redis.call('zrevrangebyscore', 'ql:tags', '+inf', 2, 'limit', offset, count)
  else
    error('Tag(): First argument must be "add", "remove" or "get"')
  end
end

function Qless.cancel(now, ...)
  local dependents = {}
  for _, jid in ipairs(arg) do
    dependents[jid] = redis.call(
      'smembers', QlessJob.ns .. jid .. '-dependents') or {}
  end

  for i, jid in ipairs(arg) do
    for j, dep in ipairs(dependents[jid]) do
      if dependents[dep] == nil or dependents[dep] == false then
        error('Cancel(): ' .. jid .. ' is a dependency of ' .. dep ..
           ' but is not mentioned to be canceled')
      end
    end
  end

  local cancelled_jids = {}

  for _, jid in ipairs(arg) do
    local state, queue, failure, worker = unpack(redis.call(
      'hmget', QlessJob.ns .. jid, 'state', 'queue', 'failure', 'worker'))

    if state ~= false and state ~= 'complete' then
      table.insert(cancelled_jids, jid)

      local encoded = cjson.encode({
        jid    = jid,
        worker = worker,
        event  = 'canceled',
        queue  = queue
      })
      Qless.publish('log', encoded)

      if worker and (worker ~= '') then
        redis.call('zrem', 'ql:w:' .. worker .. ':jobs', jid)
        Qless.publish('w:' .. worker, encoded)
      end

      if queue then
        local queue = Qless.queue(queue)
        queue.work.remove(jid)
        queue.locks.remove(jid)
        queue.scheduled.remove(jid)
        queue.depends.remove(jid)
      end

      Qless.job(jid):release_resources(now)

      for i, j in ipairs(redis.call(
        'smembers', QlessJob.ns .. jid .. '-dependencies')) do
        redis.call('srem', QlessJob.ns .. j .. '-dependents', jid)
      end

      redis.call('del', QlessJob.ns .. jid .. '-dependencies')

      if state == 'failed' then
        failure = cjson.decode(failure)
        redis.call('lrem', 'ql:f:' .. failure.group, 0, jid)
        if redis.call('llen', 'ql:f:' .. failure.group) == 0 then
          redis.call('srem', 'ql:failures', failure.group)
        end
        local bin = failure.when - (failure.when % 86400)
        local failed = redis.call(
          'hget', 'ql:s:stats:' .. bin .. ':' .. queue, 'failed')
        redis.call('hset',
          'ql:s:stats:' .. bin .. ':' .. queue, 'failed', failed - 1)
      end

      local tags = cjson.decode(
        redis.call('hget', QlessJob.ns .. jid, 'tags') or '{}')
      for i, tag in ipairs(tags) do
        redis.call('zrem', 'ql:t:' .. tag, jid)
        redis.call('zincrby', 'ql:tags', -1, tag)
      end

      if redis.call('zscore', 'ql:tracked', jid) ~= false then
        Qless.publish('canceled', jid)
      end

      redis.call('del', QlessJob.ns .. jid)
      redis.call('del', QlessJob.ns .. jid .. '-history')
    end
  end

  return cancelled_jids
end

local Set = {}

function Set.new (t)
  local set = {}
  for _, l in ipairs(t) do set[l] = true end
  return set
end

function Set.union (a,b)
  local res = Set.new{}
  for k in pairs(a) do res[k] = true end
  for k in pairs(b) do res[k] = true end
  return res
end

function Set.intersection (a,b)
  local res = Set.new{}
  for k in pairs(a) do
    res[k] = b[k]
  end
  return res
end

function Set.diff(a,b)
  local res = Set.new{}
  for k in pairs(a) do
    if not b[k] then res[k] = true end
  end

  return res
end

Qless.config.defaults = {
  ['application']        = 'qless',
  ['heartbeat']          = 60,
  ['grace-period']       = 10,
  ['stats-history']      = 30,
  ['histogram-history']  = 7,
  ['jobs-history-count'] = 50000,
  ['jobs-history']       = 604800
}

Qless.config.get = function(key, default)
  if key then
    return redis.call('hget', 'ql:config', key) or
      Qless.config.defaults[key] or default
  else
    local reply = redis.call('hgetall', 'ql:config')
    for i = 1, #reply, 2 do
      Qless.config.defaults[reply[i]] = reply[i + 1]
    end
    return Qless.config.defaults
  end
end

Qless.config.set = function(option, value)
  assert(option, 'config.set(): Arg "option" missing')
  assert(value , 'config.set(): Arg "value" missing')
  Qless.publish('log', cjson.encode({
    event  = 'config_set',
    option = option,
    value  = value
  }))

  redis.call('hset', 'ql:config', option, value)
end

Qless.config.unset = function(option)
  assert(option, 'config.unset(): Arg "option" missing')
  Qless.publish('log', cjson.encode({
    event  = 'config_unset',
    option = option
  }))

  redis.call('hdel', 'ql:config', option)
end

function QlessJob:data(...)
  local job = redis.call(
      'hmget', QlessJob.ns .. self.jid, 'jid', 'klass', 'state', 'queue',
      'worker', 'priority', 'expires', 'retries', 'remaining', 'data',
      'tags', 'failure', 'spawned_from_jid', 'resources', 'result_data', 'throttle_interval')

  if not job[1] then
    return nil
  end

  local data = {
    jid              = job[1],
    klass            = job[2],
    state            = job[3],
    queue            = job[4],
    worker           = job[5] or '',
    tracked          = redis.call(
      'zscore', 'ql:tracked', self.jid) ~= false,
    priority         = tonumber(job[6]),
    expires          = tonumber(job[7]) or 0,
    retries          = tonumber(job[8]),
    remaining        = math.floor(tonumber(job[9])),
    data             = job[10],
    tags             = cjson.decode(job[11]),
    history          = self:history(),
    failure          = cjson.decode(job[12] or '{}'),
    resources        = cjson.decode(job[14] or '[]'),
    result_data      = cjson.decode(job[15] or '{}'),
    interval         = tonumber(job[16]) or 0,
    dependents       = redis.call(
      'smembers', QlessJob.ns .. self.jid .. '-dependents'),
    dependencies     = redis.call(
      'smembers', QlessJob.ns .. self.jid .. '-dependencies'),
    spawned_from_jid = job[13]
  }

  if #arg > 0 then
    local response = {}
    for index, key in ipairs(arg) do
      table.insert(response, data[key])
    end
    return response
  else
    return data
  end
end

function QlessJob:complete(now, worker, queue, data, ...)
  assert(worker, 'Complete(): Arg "worker" missing')
  assert(queue , 'Complete(): Arg "queue" missing')
  if data then
    assert(cjson.decode(data), 'Complete(): Arg "data" not JSON: ' .. tostring(data))
  end

  local options = {}
  for i = 1, #arg, 2 do options[arg[i]] = arg[i + 1] end

  local nextq   = options['next']
  local delay   = assert(tonumber(options['delay'] or 0))
  local depends = assert(cjson.decode(options['depends'] or '[]'),
    'Complete(): Arg "depends" not JSON: ' .. tostring(options['depends']))

  local result_data = options['result_data']

  if options['delay'] and nextq == nil then
    error('Complete(): "delay" cannot be used without a "next".')
  end

  if options['depends'] and nextq == nil then
    error('Complete(): "depends" cannot be used without a "next".')
  end

  local bin = now - (now % 86400)

  local lastworker, state, priority, retries, current_queue, interval = unpack(
    redis.call('hmget', QlessJob.ns .. self.jid, 'worker', 'state',
      'priority', 'retries', 'queue', 'throttle_interval'))

  if lastworker == false then
    error('Complete(): Job ' .. self.jid .. ' does not exist')
  elseif (state ~= 'running') then
    error('Complete(): Job ' .. self.jid .. ' is not currently running: ' ..
      state)
  elseif lastworker ~= worker then
    error('Complete(): Job ' .. self.jid ..
      ' has been handed out to another worker: ' .. tostring(lastworker))
  elseif queue ~= current_queue then
    error('Complete(): Job ' .. self.jid .. ' running in another queue: ' ..
      tostring(current_queue))
  end

  local next_run = 0
  if interval then
    interval = tonumber(interval)
    if interval > 0 then
      next_run = now + interval
    else
      next_run = -1
    end
  end

  self:history(now, 'done')

  if data then
    redis.call('hset', QlessJob.ns .. self.jid, 'data', data)
  end

  if result_data then
    redis.call('hset', QlessJob.ns .. self.jid, 'result_data', result_data)
  end

  local queue_obj = Qless.queue(queue)
  queue_obj.work.remove(self.jid)
  queue_obj.locks.remove(self.jid)
  queue_obj.scheduled.remove(self.jid)

  self:release_resources(now)

  local time = tonumber(
    redis.call('hget', QlessJob.ns .. self.jid, 'time') or now)
  local waiting = now - time
  Qless.queue(queue):stat(now, 'run', waiting)
  redis.call('hset', QlessJob.ns .. self.jid,
    'time', string.format("%.20f", now))

  redis.call('zrem', 'ql:w:' .. worker .. ':jobs', self.jid)

  if redis.call('zscore', 'ql:tracked', self.jid) ~= false then
    Qless.publish('completed', self.jid)
  end

  if nextq then
    queue_obj = Qless.queue(nextq)
    Qless.publish('log', cjson.encode({
      jid   = self.jid,
      event = 'advanced',
      queue = queue,
      to    = nextq
    }))

    self:history(now, 'put', {q = nextq})

    if redis.call('zscore', 'ql:queues', nextq) == false then
      redis.call('zadd', 'ql:queues', now, nextq)
    end

    redis.call('hmset', QlessJob.ns .. self.jid,
      'state', 'waiting',
      'worker', '',
      'failure', '{}',
      'queue', nextq,
      'expires', 0,
      'remaining', tonumber(retries))

    if (delay > 0) and (#depends == 0) then
      queue_obj.scheduled.add(now + delay, self.jid)
      return 'scheduled'
    else
      local count = 0
      for i, j in ipairs(depends) do
        local state = redis.call('hget', QlessJob.ns .. j, 'state')
        if (state and state ~= 'complete') then
          count = count + 1
          redis.call(
            'sadd', QlessJob.ns .. j .. '-dependents',self.jid)
          redis.call(
            'sadd', QlessJob.ns .. self.jid .. '-dependencies', j)
        end
      end
      if count > 0 then
        queue_obj.depends.add(now, self.jid)
        redis.call('hset', QlessJob.ns .. self.jid, 'state', 'depends')
        if delay > 0 then
          queue_obj.depends.add(now, self.jid)
          redis.call('hset', QlessJob.ns .. self.jid, 'scheduled', now + delay)
        end
        return 'depends'
      else
        if self:acquire_resources(now) then
          queue_obj.work.add(now, priority, self.jid)
        end
        return 'waiting'
      end
    end
  else
    Qless.publish('log', cjson.encode({
      jid   = self.jid,
      event = 'completed',
      queue = queue
    }))

    redis.call('hmset', QlessJob.ns .. self.jid,
      'state', 'complete',
      'worker', '',
      'failure', '{}',
      'queue', '',
      'expires', 0,
      'remaining', tonumber(retries),
      'throttle_next_run', next_run
    )

    local count = Qless.config.get('jobs-history-count')
    local time  = Qless.config.get('jobs-history')

    count = tonumber(count or 50000)
    time  = tonumber(time  or 7 * 24 * 60 * 60)

    redis.call('zadd', 'ql:completed', now, self.jid)

    local jids = redis.call('zrangebyscore', 'ql:completed', 0, now - time)
    for index, jid in ipairs(jids) do
      local tags = cjson.decode(
        redis.call('hget', QlessJob.ns .. jid, 'tags') or '{}')
      for i, tag in ipairs(tags) do
        redis.call('zrem', 'ql:t:' .. tag, jid)
        redis.call('zincrby', 'ql:tags', -1, tag)
      end
      redis.call('del', QlessJob.ns .. jid)
      redis.call('del', QlessJob.ns .. jid .. '-history')
    end
    redis.call('zremrangebyscore', 'ql:completed', 0, now - time)

    jids = redis.call('zrange', 'ql:completed', 0, (-1-count))
    for index, jid in ipairs(jids) do
      local tags = cjson.decode(
        redis.call('hget', QlessJob.ns .. jid, 'tags') or '{}')
      for i, tag in ipairs(tags) do
        redis.call('zrem', 'ql:t:' .. tag, jid)
        redis.call('zincrby', 'ql:tags', -1, tag)
      end
      redis.call('del', QlessJob.ns .. jid)
      redis.call('del', QlessJob.ns .. jid .. '-history')
    end
    redis.call('zremrangebyrank', 'ql:completed', 0, (-1-count))

    for i, j in ipairs(redis.call(
      'smembers', QlessJob.ns .. self.jid .. '-dependents')) do
      redis.call('srem', QlessJob.ns .. j .. '-dependencies', self.jid)
      if redis.call(
        'scard', QlessJob.ns .. j .. '-dependencies') == 0 then
        local q, p, scheduled = unpack(
          redis.call('hmget', QlessJob.ns .. j, 'queue', 'priority', 'scheduled'))
        if q then
          local queue = Qless.queue(q)
          queue.depends.remove(j)
          if scheduled then
            queue.scheduled.add(scheduled, j)
            redis.call('hset', QlessJob.ns .. j, 'state', 'scheduled')
            redis.call('hdel', QlessJob.ns .. j, 'scheduled')
          else
            if Qless.job(j):acquire_resources(now) then
              queue.work.add(now, p, j)
            end
            redis.call('hset', QlessJob.ns .. j, 'state', 'waiting')
          end
        end
      end
    end

    redis.call('del', QlessJob.ns .. self.jid .. '-dependents')

    return 'complete'
  end
end

function QlessJob:fail(now, worker, group, message, data)
  local worker  = assert(worker           , 'Fail(): Arg "worker" missing')
  local group   = assert(group            , 'Fail(): Arg "group" missing')
  local message = assert(message          , 'Fail(): Arg "message" missing')

  local bin = now - (now % 86400)

  if data then
    assert(cjson.decode(data), 'Fail(): Arg "data" not JSON: ' .. tostring(data))
  end

  local queue, state, oldworker = unpack(redis.call(
    'hmget', QlessJob.ns .. self.jid, 'queue', 'state', 'worker'))

  if not state then
    error('Fail(): Job ' .. self.jid .. ' does not exist')
  elseif state ~= 'running' then
    error('Fail(): Job ' .. self.jid .. ' not currently running: ' .. state)
  elseif worker ~= oldworker then
    error('Fail(): Job ' .. self.jid .. ' running with another worker: ' ..
      oldworker)
  end

  Qless.publish('log', cjson.encode({
    jid     = self.jid,
    event   = 'failed',
    worker  = worker,
    group   = group,
    message = message
  }))

  if redis.call('zscore', 'ql:tracked', self.jid) ~= false then
    Qless.publish('failed', self.jid)
  end

  redis.call('zrem', 'ql:w:' .. worker .. ':jobs', self.jid)

  self:history(now, 'failed', {worker = worker, group = group})

  redis.call('hincrby', 'ql:s:stats:' .. bin .. ':' .. queue, 'failures', 1)
  redis.call('hincrby', 'ql:s:stats:' .. bin .. ':' .. queue, 'failed'  , 1)

  local queue_obj = Qless.queue(queue)
  queue_obj.work.remove(self.jid)
  queue_obj.locks.remove(self.jid)
  queue_obj.scheduled.remove(self.jid)

  self:release_resources(now)

  if data then
    redis.call('hset', QlessJob.ns .. self.jid, 'data', data)
  end

  redis.call('hmset', QlessJob.ns .. self.jid,
    'state', 'failed',
    'worker', '',
    'expires', '',
    'failure', cjson.encode({
      ['group']   = group,
      ['message'] = message,
      ['when']    = math.floor(now),
      ['worker']  = worker
    }))

  redis.call('sadd', 'ql:failures', group)
  redis.call('lpush', 'ql:f:' .. group, self.jid)


  return self.jid
end

function QlessJob:retry(now, queue, worker, delay, group, message)
  assert(queue , 'Retry(): Arg "queue" missing')
  assert(worker, 'Retry(): Arg "worker" missing')
  delay = assert(tonumber(delay or 0),
    'Retry(): Arg "delay" not a number: ' .. tostring(delay))

  local oldqueue, state, retries, oldworker, priority, failure = unpack(
    redis.call('hmget', QlessJob.ns .. self.jid, 'queue', 'state',
      'retries', 'worker', 'priority', 'failure'))

  if oldworker == false then
    error('Retry(): Job ' .. self.jid .. ' does not exist')
  elseif state ~= 'running' then
    error('Retry(): Job ' .. self.jid .. ' is not currently running: ' ..
      state)
  elseif oldworker ~= worker then
    error('Retry(): Job ' .. self.jid ..
      ' has been given to another worker: ' .. oldworker)
  end

  local remaining = tonumber(redis.call(
    'hincrby', QlessJob.ns .. self.jid, 'remaining', -1))
  redis.call('hdel', QlessJob.ns .. self.jid, 'grace')

  Qless.queue(oldqueue).locks.remove(self.jid)
  self:release_resources(now)

  redis.call('zrem', 'ql:w:' .. worker .. ':jobs', self.jid)

  if remaining < 0 then
    local group = group or 'failed-retries-' .. queue
    self:history(now, 'failed', {['group'] = group})

    redis.call('hmset', QlessJob.ns .. self.jid, 'state', 'failed',
      'worker', '',
      'expires', '')
    if group ~= nil and message ~= nil then
      redis.call('hset', QlessJob.ns .. self.jid,
        'failure', cjson.encode({
          ['group']   = group,
          ['message'] = message,
          ['when']    = math.floor(now),
          ['worker']  = worker
        })
      )
    else
      redis.call('hset', QlessJob.ns .. self.jid,
      'failure', cjson.encode({
        ['group']   = group,
        ['message'] =
          'Job exhausted retries in queue "' .. oldqueue .. '"',
        ['when']    = now,
        ['worker']  = unpack(self:data('worker'))
      }))
    end

    redis.call('sadd', 'ql:failures', group)
    redis.call('lpush', 'ql:f:' .. group, self.jid)
    local bin = now - (now % 86400)
    redis.call('hincrby', 'ql:s:stats:' .. bin .. ':' .. queue, 'failures', 1)
    redis.call('hincrby', 'ql:s:stats:' .. bin .. ':' .. queue, 'failed'  , 1)
  else
    local queue_obj = Qless.queue(queue)
    if delay > 0 then
      queue_obj.scheduled.add(now + delay, self.jid)
      redis.call('hset', QlessJob.ns .. self.jid, 'state', 'scheduled')
    else
      if self:acquire_resources(now) then
        queue_obj.work.add(now, priority, self.jid)
      end
      redis.call('hset', QlessJob.ns .. self.jid, 'state', 'waiting')
    end

    if group ~= nil and message ~= nil then
      redis.call('hset', QlessJob.ns .. self.jid,
        'failure', cjson.encode({
          ['group']   = group,
          ['message'] = message,
          ['when']    = math.floor(now),
          ['worker']  = worker
        })
      )
    end
  end

  return math.floor(remaining)
end

function QlessJob:depends(now, command, ...)
  assert(command, 'Depends(): Arg "command" missing')
  local state = redis.call('hget', QlessJob.ns .. self.jid, 'state')
  if state ~= 'depends' then
    error('Depends(): Job ' .. self.jid ..
      ' not in the depends state: ' .. tostring(state))
  end

  if command == 'on' then
    for i, j in ipairs(arg) do
      local state = redis.call('hget', QlessJob.ns .. j, 'state')
      if (state and state ~= 'complete') then
        redis.call(
          'sadd', QlessJob.ns .. j .. '-dependents'  , self.jid)
        redis.call(
          'sadd', QlessJob.ns .. self.jid .. '-dependencies', j)
      end
    end
    return true
  elseif command == 'off' then
    if arg[1] == 'all' then
      for i, j in ipairs(redis.call(
        'smembers', QlessJob.ns .. self.jid .. '-dependencies')) do
        redis.call('srem', QlessJob.ns .. j .. '-dependents', self.jid)
      end
      redis.call('del', QlessJob.ns .. self.jid .. '-dependencies')
      local q, p = unpack(redis.call(
        'hmget', QlessJob.ns .. self.jid, 'queue', 'priority'))
      if q then
        local queue_obj = Qless.queue(q)
        queue_obj.depends.remove(self.jid)
        if self:acquire_resources(now) then
          queue_obj.work.add(now, p, self.jid)
        end
        redis.call('hset', QlessJob.ns .. self.jid, 'state', 'waiting')
      end
    else
      for i, j in ipairs(arg) do
        redis.call('srem', QlessJob.ns .. j .. '-dependents', self.jid)
        redis.call(
          'srem', QlessJob.ns .. self.jid .. '-dependencies', j)
        if redis.call('scard',
          QlessJob.ns .. self.jid .. '-dependencies') == 0 then
          local q, p = unpack(redis.call(
            'hmget', QlessJob.ns .. self.jid, 'queue', 'priority'))
          if q then
            local queue_obj = Qless.queue(q)
            queue_obj.depends.remove(self.jid)
            if self:acquire_resources(now) then
              queue_obj.work.add(now, p, self.jid)
            end
            redis.call('hset',
              QlessJob.ns .. self.jid, 'state', 'waiting')
          end
        end
      end
    end
    return true
  else
    error('Depends(): Argument "command" must be "on" or "off"')
  end
end

function QlessJob:heartbeat(now, worker, data)
  assert(worker, 'Heatbeat(): Arg "worker" missing')

  local queue = redis.call('hget', QlessJob.ns .. self.jid, 'queue') or ''
  local expires = now + tonumber(
    Qless.config.get(queue .. '-heartbeat') or
    Qless.config.get('heartbeat', 60))

  if data then
    assert(cjson.decode(data), 'Heartbeat(): Arg "data" not JSON: ' .. tostring(data))
  end

  local job_worker, state = unpack(
    redis.call('hmget', QlessJob.ns .. self.jid, 'worker', 'state'))
  if job_worker == false then
    error('Heartbeat(): Job ' .. self.jid .. ' does not exist')
  elseif state ~= 'running' then
    error(
      'Heartbeat(): Job ' .. self.jid .. ' not currently running: ' .. state)
  elseif job_worker ~= worker or #job_worker == 0 then
    error(
      'Heartbeat(): Job ' .. self.jid ..
      ' given out to another worker: ' .. job_worker)
  else
    if data then
      redis.call('hmset', QlessJob.ns .. self.jid, 'expires',
        expires, 'worker', worker, 'data', data)
    else
      redis.call('hmset', QlessJob.ns .. self.jid,
        'expires', expires, 'worker', worker)
    end

    redis.call('zadd', 'ql:w:' .. worker .. ':jobs', expires, self.jid)

    redis.call('zadd', 'ql:workers', now, worker)

    local queue = Qless.queue(
      redis.call('hget', QlessJob.ns .. self.jid, 'queue'))
    queue.locks.add(expires, self.jid)
    return expires
  end
end

function QlessJob:priority(priority)
  priority = assert(tonumber(priority),
    'Priority(): Arg "priority" missing or not a number: ' ..
    tostring(priority))

  local queue = redis.call('hget', QlessJob.ns .. self.jid, 'queue')

  if queue == nil or queue == false then
    error('Priority(): Job ' .. self.jid .. ' does not exist')
  elseif queue == '' then
    redis.call('hset', QlessJob.ns .. self.jid, 'priority', priority)
    return priority
  else
    local queue_obj = Qless.queue(queue)
    if queue_obj.work.score(self.jid) then
      queue_obj.work.add(0, priority, self.jid)
    end
    redis.call('hset', QlessJob.ns .. self.jid, 'priority', priority)
    return priority
  end
end

function QlessJob:update(data)
  local tmp = {}
  for k, v in pairs(data) do
    table.insert(tmp, k)
    table.insert(tmp, v)
  end
  redis.call('hmset', QlessJob.ns .. self.jid, unpack(tmp))
end

function QlessJob:timeout(now)
  local queue_name, state, worker = unpack(redis.call('hmget',
    QlessJob.ns .. self.jid, 'queue', 'state', 'worker'))
  if queue_name == nil or queue_name == false then
    error('Timeout(): Job ' .. self.jid .. ' does not exist')
  elseif state ~= 'running' then
    error('Timeout(): Job ' .. self.jid .. ' not running')
  else
    self:history(now, 'timed-out')
    local queue = Qless.queue(queue_name)
    queue.locks.remove(self.jid)
    queue.work.add(now, '+inf', self.jid)
    redis.call('hmset', QlessJob.ns .. self.jid,
      'state', 'stalled', 'expires', 0)
    local encoded = cjson.encode({
      jid    = self.jid,
      event  = 'lock_lost',
      worker = worker
    })
    Qless.publish('w:' .. worker, encoded)
    Qless.publish('log', encoded)
    return queue_name
  end
end

function QlessJob:exists()
  return redis.call('exists', QlessJob.ns .. self.jid) == 1
end

function QlessJob:history(now, what, item)
  local history = redis.call('hget', QlessJob.ns .. self.jid, 'history')
  if history then
    history = cjson.decode(history)
    for i, value in ipairs(history) do
      redis.call('rpush', QlessJob.ns .. self.jid .. '-history',
        cjson.encode({math.floor(value.put), 'put', {q = value.q}}))

      if value.popped then
        redis.call('rpush', QlessJob.ns .. self.jid .. '-history',
          cjson.encode({math.floor(value.popped), 'popped',
            {worker = value.worker}}))
      end

      if value.failed then
        redis.call('rpush', QlessJob.ns .. self.jid .. '-history',
          cjson.encode(
            {math.floor(value.failed), 'failed', nil}))
      end

      if value.done then
        redis.call('rpush', QlessJob.ns .. self.jid .. '-history',
          cjson.encode(
            {math.floor(value.done), 'done', nil}))
      end
    end
    redis.call('hdel', QlessJob.ns .. self.jid, 'history')
  end

  if what == nil then
    local response = {}
    for i, value in ipairs(redis.call('lrange',
      QlessJob.ns .. self.jid .. '-history', 0, -1)) do
      value = cjson.decode(value)
      local dict = value[3] or {}
      dict['when'] = value[1]
      dict['what'] = value[2]
      table.insert(response, dict)
    end
    return response
  else
    local count = tonumber(Qless.config.get('max-job-history', 100))
    if count > 0 then
      local obj = redis.call('lpop', QlessJob.ns .. self.jid .. '-history')
      redis.call('ltrim', QlessJob.ns .. self.jid .. '-history', -count + 2, -1)
      if obj ~= nil and obj ~= false then
        redis.call('lpush', QlessJob.ns .. self.jid .. '-history', obj)
      end
    end
    return redis.call('rpush', QlessJob.ns .. self.jid .. '-history',
      cjson.encode({math.floor(now), what, item}))
  end
end

function QlessJob:release_resources(now)
  local resources = redis.call('hget', QlessJob.ns .. self.jid, 'resources')
  resources = cjson.decode(resources or '[]')
  for _, res in ipairs(resources) do
    Qless.resource(res):release(now, self.jid)
  end
end

function QlessJob:acquire_resources(now)
  local resources, priority = unpack(redis.call('hmget', QlessJob.ns .. self.jid, 'resources', 'priority'))
  resources = cjson.decode(resources or '[]')
  if (#resources == 0) then
    return true
  end

  local acquired_all = true

  for _, res in ipairs(resources) do
    local ok, res = pcall(function() return Qless.resource(res):acquire(now, priority, self.jid) end)
    if not ok then
      self:set_failed(now, 'system:fatal', res.msg)
      return false
    end
    acquired_all = acquired_all and res
  end

  return acquired_all
end

function QlessJob:set_failed(now, group, message, worker, release_work, release_resources)
  local group             = assert(group, 'Fail(): Arg "group" missing')
  local message           = assert(message, 'Fail(): Arg "message" missing')
  local worker            = worker or 'none'
  local release_work      = release_work or true
  local release_resources = release_resources or false

  local bin = now - (now % 86400)

  local queue = unpack(redis.call('hmget', QlessJob.ns .. self.jid, 'queue'))

  Qless.publish('log', cjson.encode({
    jid     = self.jid,
    event   = 'failed',
    worker  = worker,
    group   = group,
    message = message
  }))

  if redis.call('zscore', 'ql:tracked', self.jid) ~= false then
    Qless.publish('failed', self.jid)
  end

  self:history(now, 'failed', {group = group})

  redis.call('hincrby', 'ql:s:stats:' .. bin .. ':' .. queue, 'failures', 1)
  redis.call('hincrby', 'ql:s:stats:' .. bin .. ':' .. queue, 'failed'  , 1)

  if release_work then
    local queue_obj = Qless.queue(queue)
    queue_obj.work.remove(self.jid)
    queue_obj.locks.remove(self.jid)
    queue_obj.scheduled.remove(self.jid)
  end

  if release_resources then
    self:release_resources(now)
  end

  redis.call('hmset', QlessJob.ns .. self.jid,
    'state', 'failed',
    'worker', '',
    'expires', '',
    'failure', cjson.encode({
      ['group']   = group,
      ['message'] = message,
      ['when']    = math.floor(now)
    }))

  redis.call('sadd', 'ql:failures', group)
  redis.call('lpush', 'ql:f:' .. group, self.jid)


  return self.jid
end
function Qless.queue(name)
  assert(name, 'Queue(): no queue name provided')
  local queue = {}
  setmetatable(queue, QlessQueue)
  queue.name = name

  queue.work = {
    peek = function(now, offset, count)
      if count == 0 then
        return {}
      end
      local jids = {}
      for index, jid in ipairs(redis.call(
        'zrevrange', queue:prefix('work'), offset, offset + count - 1)) do
        table.insert(jids, jid)
      end
      return jids
    end, remove = function(...)
      if #arg > 0 then
        return redis.call('zrem', queue:prefix('work'), unpack(arg))
      end
    end, add = function(now, priority, jid)
      if priority ~= '+inf' then
        priority = priority - (now / 10000000000)
      end
      return redis.call('zadd',
        queue:prefix('work'), priority, jid)
    end, score = function(jid)
      return redis.call('zscore', queue:prefix('work'), jid)
    end, length = function()
      return redis.call('zcard', queue:prefix('work'))
    end
  }

  queue.locks = {
    expired = function(now, offset, count)
      return redis.call('zrangebyscore',
        queue:prefix('locks'), '-inf', now, 'LIMIT', offset, count)
    end, peek = function(now, offset, count)
      return redis.call('zrangebyscore', queue:prefix('locks'),
        now, '+inf', 'LIMIT', offset, count)
    end, add = function(expires, jid)
      redis.call('zadd', queue:prefix('locks'), expires, jid)
    end, remove = function(...)
      if #arg > 0 then
        return redis.call('zrem', queue:prefix('locks'), unpack(arg))
      end
    end, running = function(now)
      return redis.call('zcount', queue:prefix('locks'), now, '+inf')
    end, length = function(now)
      if now then
        return redis.call('zcount', queue:prefix('locks'), 0, now)
      else
        return redis.call('zcard', queue:prefix('locks'))
      end
    end, job_time_left = function(now, jid)
      return tonumber(redis.call('zscore', queue:prefix('locks'), jid) or 0) - now
    end
  }

  queue.depends = {
    peek = function(now, offset, count)
      return redis.call('zrange',
        queue:prefix('depends'), offset, offset + count - 1)
    end, add = function(now, jid)
      redis.call('zadd', queue:prefix('depends'), now, jid)
    end, remove = function(...)
      if #arg > 0 then
        return redis.call('zrem', queue:prefix('depends'), unpack(arg))
      end
    end, length = function()
      return redis.call('zcard', queue:prefix('depends'))
    end
  }

  queue.scheduled = {
    peek = function(now, offset, count)
      return redis.call('zrange',
        queue:prefix('scheduled'), offset, offset + count - 1)
    end, ready = function(now, offset, count)
      return redis.call('zrangebyscore',
        queue:prefix('scheduled'), 0, now, 'LIMIT', offset, count)
    end, add = function(when, jid)
      redis.call('zadd', queue:prefix('scheduled'), when, jid)
    end, remove = function(...)
      if #arg > 0 then
        return redis.call('zrem', queue:prefix('scheduled'), unpack(arg))
      end
    end, length = function()
      return redis.call('zcard', queue:prefix('scheduled'))
    end
  }

  queue.recurring = {
    peek = function(now, offset, count)
      return redis.call('zrangebyscore', queue:prefix('recur'),
        0, now, 'LIMIT', offset, count)
    end, ready = function(now, offset, count)
    end, add = function(when, jid)
      redis.call('zadd', queue:prefix('recur'), when, jid)
    end, remove = function(...)
      if #arg > 0 then
        return redis.call('zrem', queue:prefix('recur'), unpack(arg))
      end
    end, update = function(increment, jid)
      redis.call('zincrby', queue:prefix('recur'), increment, jid)
    end, score = function(jid)
      return redis.call('zscore', queue:prefix('recur'), jid)
    end, length = function()
      return redis.call('zcard', queue:prefix('recur'))
    end
  }
  return queue
end

function QlessQueue:prefix(group)
  if group then
    return QlessQueue.ns..self.name..'-'..group
  else
    return QlessQueue.ns..self.name
  end
end

function QlessQueue:stats(now, date)
  date = assert(tonumber(date),
    'Stats(): Arg "date" missing or not a number: '.. (date or 'nil'))

  local bin = date - (date % 86400)

  local histokeys = {
    's0','s1','s2','s3','s4','s5','s6','s7','s8','s9','s10','s11','s12','s13','s14','s15','s16','s17','s18','s19','s20','s21','s22','s23','s24','s25','s26','s27','s28','s29','s30','s31','s32','s33','s34','s35','s36','s37','s38','s39','s40','s41','s42','s43','s44','s45','s46','s47','s48','s49','s50','s51','s52','s53','s54','s55','s56','s57','s58','s59',
    'm1','m2','m3','m4','m5','m6','m7','m8','m9','m10','m11','m12','m13','m14','m15','m16','m17','m18','m19','m20','m21','m22','m23','m24','m25','m26','m27','m28','m29','m30','m31','m32','m33','m34','m35','m36','m37','m38','m39','m40','m41','m42','m43','m44','m45','m46','m47','m48','m49','m50','m51','m52','m53','m54','m55','m56','m57','m58','m59',
    'h1','h2','h3','h4','h5','h6','h7','h8','h9','h10','h11','h12','h13','h14','h15','h16','h17','h18','h19','h20','h21','h22','h23',
    'd1','d2','d3','d4','d5','d6'
  }

  local mkstats = function(name, bin, queue)
    local results = {}

    local key = 'ql:s:' .. name .. ':' .. bin .. ':' .. queue
    local count, mean, vk = unpack(redis.call('hmget', key, 'total', 'mean', 'vk'))

    count = tonumber(count) or 0
    mean  = tonumber(mean) or 0
    vk    = tonumber(vk)

    results.count     = count or 0
    results.mean      = mean  or 0
    results.histogram = {}

    if not count then
      results.std = 0
    else
      if count > 1 then
        results.std = math.sqrt(vk / (count - 1))
      else
        results.std = 0
      end
    end

    local histogram = redis.call('hmget', key, unpack(histokeys))
    for i=1,#histokeys do
      table.insert(results.histogram, tonumber(histogram[i]) or 0)
    end
    return results
  end

  local retries, failed, failures = unpack(redis.call('hmget', 'ql:s:stats:' .. bin .. ':' .. self.name, 'retries', 'failed', 'failures'))
  return {
    retries  = tonumber(retries  or 0),
    failed   = tonumber(failed   or 0),
    failures = tonumber(failures or 0),
    wait     = mkstats('wait', bin, self.name),
    run      = mkstats('run' , bin, self.name)
  }
end

function QlessQueue:peek(now, count)
  count = assert(tonumber(count),
    'Peek(): Arg "count" missing or not a number: ' .. tostring(count))

  local jids = self.locks.expired(now, 0, count)

  self:check_recurring(now, count - #jids)

  self:check_scheduled(now, count - #jids)

  extend_table(jids, self.work.peek(now, 0, count - #jids))

  return jids
end

function QlessQueue:paused()
  return redis.call('sismember', 'ql:paused_queues', self.name) == 1
end

function QlessQueue.pause(now, ...)
  redis.call('sadd', 'ql:paused_queues', unpack(arg))
end

function QlessQueue.unpause(...)
  redis.call('srem', 'ql:paused_queues', unpack(arg))
end

function QlessQueue:pop(now, worker, count)
  assert(worker, 'Pop(): Arg "worker" missing')
  count = assert(tonumber(count),
    'Pop(): Arg "count" missing or not a number: ' .. tostring(count))

  local expires = now + tonumber(
    Qless.config.get(self.name .. '-heartbeat') or
    Qless.config.get('heartbeat', 60))

  if self:paused() then
    return {}
  end

  redis.call('zadd', 'ql:workers', now, worker)

  local max_concurrency = tonumber(
    Qless.config.get(self.name .. '-max-concurrency', 0))

  if max_concurrency > 0 then
    local allowed = math.max(0, max_concurrency - self.locks.running(now))
    count = math.min(allowed, count)
    if count == 0 then
      return {}
    end
  end

  local jids = self:invalidate_locks(now, count)

  self:check_recurring(now, count - #jids)

  self:check_scheduled(now, count - #jids)

  extend_table(jids, self.work.peek(now, 0, count - #jids))

  local state
  for index, jid in ipairs(jids) do
    local job = Qless.job(jid)
    state = unpack(job:data('state'))
    job:history(now, 'popped', {worker = worker})

    local time = tonumber(
      redis.call('hget', QlessJob.ns .. jid, 'time') or now)
    local waiting = now - time
    self:stat(now, 'wait', waiting)
    redis.call('hset', QlessJob.ns .. jid,
      'time', string.format("%.20f", now))

    redis.call('zadd', 'ql:w:' .. worker .. ':jobs', expires, jid)

    job:update({
      worker  = worker,
      expires = expires,
      state   = 'running'
    })

    self.locks.add(expires, jid)

    local tracked = redis.call('zscore', 'ql:tracked', jid) ~= false
    if tracked then
      Qless.publish('popped', jid)
    end
  end

  self.work.remove(unpack(jids))

  return jids
end

function QlessQueue:stat(now, stat, val)
  local bin = now - (now % 86400)
  local key = 'ql:s:' .. stat .. ':' .. bin .. ':' .. self.name

  local count, mean, vk = unpack(
    redis.call('hmget', key, 'total', 'mean', 'vk'))

  count = count or 0
  if count == 0 then
    mean  = val
    vk    = 0
    count = 1
  else
    count = count + 1
    local oldmean = mean
    mean  = mean + (val - mean) / count
    vk    = vk + (val - mean) * (val - oldmean)
  end

  val = math.floor(val)
  if val < 60 then -- seconds
    redis.call('hincrby', key, 's' .. val, 1)
  elseif val < 3600 then -- minutes
    redis.call('hincrby', key, 'm' .. math.floor(val / 60), 1)
  elseif val < 86400 then -- hours
    redis.call('hincrby', key, 'h' .. math.floor(val / 3600), 1)
  else -- days
    redis.call('hincrby', key, 'd' .. math.floor(val / 86400), 1)
  end
  redis.call('hmset', key, 'total', count, 'mean', mean, 'vk', vk)
end

function QlessQueue:put(now, worker, jid, klass, data, delay, ...)
  assert(jid  , 'Put(): Arg "jid" missing')
  assert(klass, 'Put(): Arg "klass" missing')
  assert(cjson.decode(data), 'Put(): Arg "data" missing or not JSON: ' .. tostring(data))
  delay = assert(tonumber(delay),
    'Put(): Arg "delay" not a number: ' .. tostring(delay))

  if #arg % 2 == 1 then
    error('Odd number of additional args: ' .. tostring(arg))
  end
  local options = {}
  for i = 1, #arg, 2 do options[arg[i]] = arg[i + 1] end

  local job = Qless.job(jid)
  local priority, tags, oldqueue, state, failure, retries, oldworker, interval, next_run, old_resources =
    unpack(redis.call('hmget', QlessJob.ns .. jid, 'priority', 'tags',
      'queue', 'state', 'failure', 'retries', 'worker', 'throttle_interval', 'throttle_next_run', 'resources'))

  next_run = next_run or now

  local replace = assert(tonumber(options['replace'] or 1) ,
    'Put(): Arg "replace" not a number: ' .. tostring(options['replace']))

  if replace == 0 and state == 'running' then
    local time_left = self.locks.job_time_left(now, jid)
    if time_left > 0 then
      return time_left
    end
  end

  if tags then
    Qless.tag(now, 'remove', jid, unpack(cjson.decode(tags)))
  end

  retries  = assert(tonumber(options['retries']  or retries or 5) ,
    'Put(): Arg "retries" not a number: ' .. tostring(options['retries']))
  tags     = assert(cjson.decode(options['tags'] or tags or '[]' ),
    'Put(): Arg "tags" not JSON'          .. tostring(options['tags']))
  priority = assert(tonumber(options['priority'] or priority or 0),
    'Put(): Arg "priority" not a number'  .. tostring(options['priority']))
  local depends = assert(cjson.decode(options['depends'] or '[]') ,
    'Put(): Arg "depends" not JSON: '     .. tostring(options['depends']))

  local resources = assert(cjson.decode(options['resources'] or '[]'),
    'Put(): Arg "resources" not JSON array: '     .. tostring(options['resources']))
  assert(#resources == 0 or QlessResource.all_exist(resources), 'Put(): invalid resources requested')

  if old_resources then
    old_resources = Set.new(cjson.decode(old_resources))
    local removed_resources = Set.diff(old_resources, Set.new(resources))
    for k in pairs(removed_resources) do
      Qless.resource(k):release(now, jid)
    end
  end

  local interval = assert(tonumber(options['interval'] or interval or 0),
    'Put(): Arg "interval" not a number: ' .. tostring(options['interval']))

  if interval > 0 then
    local minimum_delay = next_run - now
    if minimum_delay < 0 then
      minimum_delay = 0
    elseif minimum_delay > delay then
      delay = minimum_delay
    end
  else
    next_run = 0
  end

  if #depends > 0 then
    local new = {}
    for _, d in ipairs(depends) do new[d] = 1 end

    local original = redis.call(
      'smembers', QlessJob.ns .. jid .. '-dependencies')
    for _, dep in pairs(original) do
      if new[dep] == nil or new[dep] == false then
        redis.call('srem', QlessJob.ns .. dep .. '-dependents'  , jid)
        redis.call('srem', QlessJob.ns .. jid .. '-dependencies', dep)
      end
    end
  end

  Qless.publish('log', cjson.encode({
    jid   = jid,
    event = 'put',
    queue = self.name
  }))

  job:history(now, 'put', {q = self.name})

  if oldqueue then
    local queue_obj = Qless.queue(oldqueue)
    queue_obj.work.remove(jid)
    queue_obj.locks.remove(jid)
    queue_obj.depends.remove(jid)
    queue_obj.scheduled.remove(jid)
  end

  if oldworker and oldworker ~= '' then
    redis.call('zrem', 'ql:w:' .. oldworker .. ':jobs', jid)
    if oldworker ~= worker then
      local encoded = cjson.encode({
        jid    = jid,
        event  = 'lock_lost',
        worker = oldworker
      })
      Qless.publish('w:' .. oldworker, encoded)
      Qless.publish('log', encoded)
    end
  end

  if state == 'complete' then
    redis.call('zrem', 'ql:completed', jid)
  end

  for i, tag in ipairs(tags) do
    redis.call('zadd', 'ql:t:' .. tag, now, jid)
    redis.call('zincrby', 'ql:tags', 1, tag)
  end

  if state == 'failed' then
    failure = cjson.decode(failure)
    redis.call('lrem', 'ql:f:' .. failure.group, 0, jid)
    if redis.call('llen', 'ql:f:' .. failure.group) == 0 then
      redis.call('srem', 'ql:failures', failure.group)
    end
    local bin = failure.when - (failure.when % 86400)
    redis.call('hincrby', 'ql:s:stats:' .. bin .. ':' .. self.name, 'failed'  , -1)
  end

  redis.call('hmset', QlessJob.ns .. jid,
    'jid'      , jid,
    'klass'    , klass,
    'data'     , data,
    'priority' , priority,
    'tags'     , cjson.encode(tags),
    'resources', cjson.encode(resources),
    'state'    , ((delay > 0) and 'scheduled') or 'waiting',
    'worker'   , '',
    'expires'  , 0,
    'queue'    , self.name,
    'retries'  , retries,
    'remaining', retries,
    'time'     , string.format("%.20f", now),
    'throttle_interval', interval,
    'throttle_next_run', next_run,
    'result_data', '{}')

  for i, j in ipairs(depends) do
    local state = redis.call('hget', QlessJob.ns .. j, 'state')
    if (state and state ~= 'complete') then
      redis.call('sadd', QlessJob.ns .. j .. '-dependents'  , jid)
      redis.call('sadd', QlessJob.ns .. jid .. '-dependencies', j)
    end
  end

  if delay > 0 then
    if redis.call('scard', QlessJob.ns .. jid .. '-dependencies') > 0 then
      self.depends.add(now, jid)
      redis.call('hmset', QlessJob.ns .. jid,
        'state', 'depends',
        'scheduled', now + delay)
    else
      self.scheduled.add(now + delay, jid)
    end
  else
    if redis.call('scard', QlessJob.ns .. jid .. '-dependencies') > 0 then
      self.depends.add(now, jid)
      redis.call('hset', QlessJob.ns .. jid, 'state', 'depends')
    elseif #resources > 0 then
      if Qless.job(jid):acquire_resources(now) then
        self.work.add(now, priority, jid)
      end
    else
      self.work.add(now, priority, jid)
    end
  end

  if redis.call('zscore', 'ql:queues', self.name) == false then
    redis.call('zadd', 'ql:queues', now, self.name)
  end

  if redis.call('zscore', 'ql:tracked', jid) ~= false then
    Qless.publish('put', jid)
  end

  return jid
end

function QlessQueue:unfail(now, group, count)
  assert(group, 'Unfail(): Arg "group" missing')
  count = assert(tonumber(count or 25),
    'Unfail(): Arg "count" not a number: ' .. tostring(count))

  local jids = redis.call('lrange', 'ql:f:' .. group, -count, -1)

  local toinsert = {}
  for index, jid in ipairs(jids) do
    local job = Qless.job(jid)
    local data = job:data()
    job:history(now, 'put', {q = self.name})
    redis.call('hmset', QlessJob.ns .. data.jid,
      'state'    , 'waiting',
      'worker'   , '',
      'expires'  , 0,
      'queue'    , self.name,
      'remaining', data.retries or 5)

    if #data['resources'] then
      if job:acquire_resources(now) then
        self.work.add(now, data.priority, data.jid)
      end
    else
      self.work.add(now, data.priority, data.jid)
    end
  end

  redis.call('ltrim', 'ql:f:' .. group, 0, -count - 1)
  if (redis.call('llen', 'ql:f:' .. group) == 0) then
    redis.call('srem', 'ql:failures', group)
  end

  return #jids
end

function QlessQueue:recur(now, jid, klass, data, spec, ...)
  assert(jid  , 'RecurringJob On(): Arg "jid" missing')
  assert(klass, 'RecurringJob On(): Arg "klass" missing')
  assert(spec , 'RecurringJob On(): Arg "spec" missing')
  assert(cjson.decode(data), 'RecurringJob On(): Arg "data" missing or not JSON: ' .. tostring(data))

  if spec == 'interval' then
    local interval = assert(tonumber(arg[1]),
      'Recur(): Arg "interval" not a number: ' .. tostring(arg[1]))
    local offset   = assert(tonumber(arg[2]),
      'Recur(): Arg "offset" not a number: '   .. tostring(arg[2]))
    if interval <= 0 then
      error('Recur(): Arg "interval" must be greater than 0')
    end

    if #arg % 2 == 1 then
      error('Odd number of additional args: ' .. tostring(arg))
    end

    local options = {}
    for i = 3, #arg, 2 do options[arg[i]] = arg[i + 1] end
    options.tags = assert(cjson.decode(options.tags or '{}'),
      'Recur(): Arg "tags" must be JSON string array: ' .. tostring(
        options.tags))
    options.priority = assert(tonumber(options.priority or 0),
      'Recur(): Arg "priority" not a number: ' .. tostring(
        options.priority))
    options.retries = assert(tonumber(options.retries  or 0),
      'Recur(): Arg "retries" not a number: ' .. tostring(
        options.retries))
    options.backlog = assert(tonumber(options.backlog  or 0),
      'Recur(): Arg "backlog" not a number: ' .. tostring(
        options.backlog))
    options.resources = assert(cjson.decode(options['resources'] or '[]'),
      'Recur(): Arg "resources" not JSON array: '     .. tostring(options['resources']))

    local count, old_queue = unpack(redis.call('hmget', 'ql:r:' .. jid, 'count', 'queue'))
    count = count or 0

    if old_queue then
      Qless.queue(old_queue).recurring.remove(jid)
    end

    redis.call('hmset', 'ql:r:' .. jid,
      'jid'      , jid,
      'klass'    , klass,
      'data'     , data,
      'priority' , options.priority,
      'tags'     , cjson.encode(options.tags or {}),
      'state'    , 'recur',
      'queue'    , self.name,
      'type'     , 'interval',
      'count'    , count,
      'interval' , interval,
      'retries'  , options.retries,
      'backlog'  , options.backlog,
      'resources', cjson.encode(options.resources))
    self.recurring.add(now + offset, jid)

    if redis.call('zscore', 'ql:queues', self.name) == false then
      redis.call('zadd', 'ql:queues', now, self.name)
    end

    return jid
  else
    error('Recur(): schedule type "' .. tostring(spec) .. '" unknown')
  end
end

function QlessQueue:length()
  return  self.locks.length() + self.work.length() + self.scheduled.length()
end

function QlessQueue:check_recurring(now, count)
  local moved = 0
  local r = self.recurring.peek(now, 0, count)
  for index, jid in ipairs(r) do
    local klass, data, priority, tags, retries, interval, backlog, resources = unpack(
      redis.call('hmget', 'ql:r:' .. jid, 'klass', 'data', 'priority',
        'tags', 'retries', 'interval', 'backlog', 'resources'))
    local _tags = cjson.decode(tags)
    local resources = cjson.decode(resources or '[]')
    local score = math.floor(tonumber(self.recurring.score(jid)))
    interval = tonumber(interval)

    backlog = tonumber(backlog or 0)
    if backlog ~= 0 then
      local num = ((now - score) / interval)
      if num > backlog then
        score = score + (
          math.ceil(num - backlog) * interval
        )
      end
    end

    while (score <= now) and (moved < count) do
      local count = redis.call('hincrby', 'ql:r:' .. jid, 'count', 1)
      moved = moved + 1

      local child_jid = jid .. '-' .. count

      for i, tag in ipairs(_tags) do
        redis.call('zadd', 'ql:t:' .. tag, now, child_jid)
        redis.call('zincrby', 'ql:tags', 1, tag)
      end

      redis.call('hmset', QlessJob.ns .. child_jid,
        'jid'              , child_jid,
        'klass'            , klass,
        'data'             , data,
        'priority'         , priority,
        'tags'             , tags,
        'state'            , 'waiting',
        'worker'           , '',
        'expires'          , 0,
        'queue'            , self.name,
        'retries'          , retries,
        'remaining'        , retries,
        'resources'        , cjson.encode(resources),
        'throttle_interval', 0,
        'time'             , string.format("%.20f", score),
        'spawned_from_jid' , jid)

      local job = Qless.job(child_jid)
      job:history(score, 'put', {q = self.name})


      local add_job = true
      if #resources then
        add_job = job:acquire_resources(score)
      end
      if add_job then
        self.work.add(score, priority, child_jid)
      end

      score = score + interval
      self.recurring.add(score, jid)
    end
  end
end

function QlessQueue:check_scheduled(now, count)
  local scheduled = self.scheduled.ready(now, 0, count)
  for index, jid in ipairs(scheduled) do
    local priority = tonumber(
      redis.call('hget', QlessJob.ns .. jid, 'priority') or 0)
    if Qless.job(jid):acquire_resources(now) then
      self.work.add(now, priority, jid)
    end
    self.scheduled.remove(jid)

    redis.call('hset', QlessJob.ns .. jid, 'state', 'waiting')
  end
end

function QlessQueue:invalidate_locks(now, count)
  local jids = {}
  for index, jid in ipairs(self.locks.expired(now, 0, count)) do
    local worker, failure = unpack(
      redis.call('hmget', QlessJob.ns .. jid, 'worker', 'failure'))
    redis.call('zrem', 'ql:w:' .. worker .. ':jobs', jid)

    local grace_period = tonumber(Qless.config.get('grace-period'))

    local courtesy_sent = tonumber(
      redis.call('hget', QlessJob.ns .. jid, 'grace') or 0)

    local send_message = (courtesy_sent ~= 1)
    local invalidate   = not send_message

    if grace_period <= 0 then
      send_message = true
      invalidate   = true
    end

    if send_message then
      if redis.call('zscore', 'ql:tracked', jid) ~= false then
        Qless.publish('stalled', jid)
      end
      Qless.job(jid):history(now, 'timed-out')
      redis.call('hset', QlessJob.ns .. jid, 'grace', 1)

      local encoded = cjson.encode({
        jid    = jid,
        event  = 'lock_lost',
        worker = worker
      })
      Qless.publish('w:' .. worker, encoded)
      Qless.publish('log', encoded)
      self.locks.add(now + grace_period, jid)

      local bin = now - (now % 86400)
      redis.call('hincrby',
        'ql:s:stats:' .. bin .. ':' .. self.name, 'retries', 1)
    end

    if invalidate then
      redis.call('hdel', QlessJob.ns .. jid, 'grace', 0)

      local remaining = tonumber(redis.call(
        'hincrby', QlessJob.ns .. jid, 'remaining', -1))

      if remaining < 0 then
        Qless.job(jid):release_resources(now)

        self.work.remove(jid)
        self.locks.remove(jid)
        self.scheduled.remove(jid)

        local group = 'failed-retries-' .. Qless.job(jid):data()['queue']
        local job = Qless.job(jid)
        job:history(now, 'failed', {group = group})
        redis.call('hmset', QlessJob.ns .. jid, 'state', 'failed',
          'worker', '',
          'expires', '')
        redis.call('hset', QlessJob.ns .. jid,
        'failure', cjson.encode({
          ['group']   = group,
          ['message'] =
            'Job exhausted retries in queue "' .. self.name .. '"',
          ['when']    = now,
          ['worker']  = unpack(job:data('worker'))
        }))

        redis.call('sadd', 'ql:failures', group)
        redis.call('lpush', 'ql:f:' .. group, jid)

        if redis.call('zscore', 'ql:tracked', jid) ~= false then
          Qless.publish('failed', jid)
        end
        Qless.publish('log', cjson.encode({
          jid     = jid,
          event   = 'failed',
          group   = group,
          worker  = worker,
          message =
            'Job exhausted retries in queue "' .. self.name .. '"'
        }))

        local bin = now - (now % 86400)
        redis.call('hincrby',
          'ql:s:stats:' .. bin .. ':' .. self.name, 'failures', 1)
        redis.call('hincrby',
          'ql:s:stats:' .. bin .. ':' .. self.name, 'failed'  , 1)
      else
        table.insert(jids, jid)
      end
    end
  end

  return jids
end

function QlessQueue.deregister(...)
  redis.call('zrem', Qless.ns .. 'queues', unpack(arg))
end

function QlessQueue.counts(now, name)
  if name then
    local queue = Qless.queue(name)
    local stalled = queue.locks.length(now)
    queue:check_scheduled(now, queue.scheduled.length())
    return {
      name      = name,
      waiting   = queue.work.length(),
      stalled   = stalled,
      running   = queue.locks.length() - stalled,
      scheduled = queue.scheduled.length(),
      depends   = queue.depends.length(),
      recurring = queue.recurring.length(),
      paused    = queue:paused()
    }
  else
    local queues = redis.call('zrange', 'ql:queues', 0, -1)
    local response = {}
    for index, qname in ipairs(queues) do
      table.insert(response, QlessQueue.counts(now, qname))
    end
    return response
  end
end
function QlessRecurringJob:data()
  local job = redis.call(
    'hmget', 'ql:r:' .. self.jid, 'jid', 'klass', 'state', 'queue',
    'priority', 'interval', 'retries', 'count', 'data', 'tags', 'backlog')

  if not job[1] then
    return nil
  end

  return {
    jid          = job[1],
    klass        = job[2],
    state        = job[3],
    queue        = job[4],
    priority     = tonumber(job[5]),
    interval     = tonumber(job[6]),
    retries      = tonumber(job[7]),
    count        = tonumber(job[8]),
    data         = job[9],
    tags         = cjson.decode(job[10]),
    backlog      = tonumber(job[11] or 0)
  }
end

function QlessRecurringJob:update(now, ...)
  local options = {}
  if redis.call('exists', 'ql:r:' .. self.jid) ~= 0 then
    for i = 1, #arg, 2 do
      local key = arg[i]
      local value = arg[i+1]
      assert(value, 'No value provided for ' .. tostring(key))
      if key == 'priority' or key == 'interval' or key == 'retries' then
        value = assert(tonumber(value), 'Recur(): Arg "' .. key .. '" must be a number: ' .. tostring(value))
        if key == 'interval' then
          local queue, interval = unpack(redis.call('hmget', 'ql:r:' .. self.jid, 'queue', 'interval'))
          Qless.queue(queue).recurring.update(
            value - tonumber(interval), self.jid)
        end
        redis.call('hset', 'ql:r:' .. self.jid, key, value)
      elseif key == 'data' then
        assert(cjson.decode(value), 'Recur(): Arg "data" is not JSON-encoded: ' .. tostring(value))
        redis.call('hset', 'ql:r:' .. self.jid, 'data', value)
      elseif key == 'klass' then
        redis.call('hset', 'ql:r:' .. self.jid, 'klass', value)
      elseif key == 'queue' then
        local queue_obj = Qless.queue(
          redis.call('hget', 'ql:r:' .. self.jid, 'queue'))
        local score = queue_obj.recurring.score(self.jid)
        queue_obj.recurring.remove(self.jid)
        Qless.queue(value).recurring.add(score, self.jid)
        redis.call('hset', 'ql:r:' .. self.jid, 'queue', value)
        if redis.call('zscore', 'ql:queues', value) == false then
          redis.call('zadd', 'ql:queues', now, value)
        end
      elseif key == 'backlog' then
        value = assert(tonumber(value),
          'Recur(): Arg "backlog" not a number: ' .. tostring(value))
        redis.call('hset', 'ql:r:' .. self.jid, 'backlog', value)
      else
        error('Recur(): Unrecognized option "' .. key .. '"')
      end
    end
    return true
  else
    error('Recur(): No recurring job ' .. self.jid)
  end
end

function QlessRecurringJob:tag(...)
  local tags = redis.call('hget', 'ql:r:' .. self.jid, 'tags')
  if tags then
    tags = cjson.decode(tags)
    local _tags = {}
    for i,v in ipairs(tags) do _tags[v] = true end

    for i=1,#arg do if _tags[arg[i]] == nil or _tags[arg[i]] == false then table.insert(tags, arg[i]) end end

    tags = cjson.encode(tags)
    redis.call('hset', 'ql:r:' .. self.jid, 'tags', tags)
    return tags
  else
    error('Tag(): Job ' .. self.jid .. ' does not exist')
  end
end

function QlessRecurringJob:untag(...)
  local tags = redis.call('hget', 'ql:r:' .. self.jid, 'tags')
  if tags then
    tags = cjson.decode(tags)
    local _tags    = {}
    for i,v in ipairs(tags) do _tags[v] = true end
    for i = 1,#arg do _tags[arg[i]] = nil end
    local results = {}
    for i, tag in ipairs(tags) do if _tags[tag] then table.insert(results, tag) end end
    tags = cjson.encode(results)
    redis.call('hset', 'ql:r:' .. self.jid, 'tags', tags)
    return tags
  else
    error('Untag(): Job ' .. self.jid .. ' does not exist')
  end
end

function QlessRecurringJob:unrecur()
  local queue = redis.call('hget', 'ql:r:' .. self.jid, 'queue')
  if queue then
    Qless.queue(queue).recurring.remove(self.jid)
    redis.call('del', 'ql:r:' .. self.jid)
    return true
  else
    return true
  end
end
function QlessWorker.deregister(...)
  redis.call('zrem', 'ql:workers', unpack(arg))
end

function QlessWorker.counts(now, worker)
  local interval = tonumber(Qless.config.get('max-worker-age', 86400))

  local workers  = redis.call('zrangebyscore', 'ql:workers', 0, now - interval)
  for index, worker in ipairs(workers) do
    redis.call('del', 'ql:w:' .. worker .. ':jobs')
  end

  redis.call('zremrangebyscore', 'ql:workers', 0, now - interval)

  if worker then
    return {
      jobs    = redis.call('zrevrangebyscore', 'ql:w:' .. worker .. ':jobs', now + 8640000, now),
      stalled = redis.call('zrevrangebyscore', 'ql:w:' .. worker .. ':jobs', now, 0)
    }
  else
    local response = {}
    local workers = redis.call('zrevrange', 'ql:workers', 0, -1)
    for index, worker in ipairs(workers) do
      table.insert(response, {
        name    = worker,
        jobs    = redis.call('zcount', 'ql:w:' .. worker .. ':jobs', now, now + 8640000),
        stalled = redis.call('zcount', 'ql:w:' .. worker .. ':jobs', 0, now)
      })
    end
    return response
  end
end

function QlessResource:data(...)
  local res = redis.call(
    'hmget', QlessResource.ns .. self.rid, 'rid', 'max')

  if not res[1] then
    return nil
  end

  local data = {
    rid          = res[1],
    max          = tonumber(res[2] or 0),
    pending      = self:pending(),
    locks        = self:locks(),
  }

  return data
end

function QlessResource:get(...)
  local res = redis.call(
    'hmget', QlessResource.ns .. self.rid, 'rid', 'max')

  if not res[1] then
    return nil
  end

  return tonumber(res[2] or 0)
end

function QlessResource:set(now, max)
  local max = assert(tonumber(max), 'Set(): Arg "max" not a number: ' .. tostring(max))

  local current_max = self:get()
  if current_max == nil then
    current_max = max
  end

  local keyLocks = self:prefix('locks')
  local current_locks = redis.pcall('scard', keyLocks)
  local confirm_limit = math.max(current_max,current_locks)
  local max_change = max - confirm_limit
  local keyPending = self:prefix('pending')

  redis.call('hmset', QlessResource.ns .. self.rid, 'rid', self.rid, 'max', max);

  if max_change > 0 then
    local jids = redis.call('zrevrange', keyPending, 0, max_change - 1, 'withscores')
    local jid_count = #jids
    if jid_count == 0 then
      return self.rid
    end

    for i = 1, jid_count, 2 do

      local newJid = jids[i]
      local score = jids[i + 1]

      if Qless.job(newJid):acquire_resources(now) then
        local data = Qless.job(newJid):data()
        local queue = Qless.queue(data['queue'])
        queue.work.add(score, 0, newJid)
      end
    end
  end

  return self.rid
end

function QlessResource:unset()
  return redis.call('del', QlessResource.ns .. self.rid);
end

function QlessResource:prefix(group)
  if group then
    return QlessResource.ns..self.rid..'-'..group
  end

  return QlessResource.ns..self.rid
end

function QlessResource:acquire(now, priority, jid)
  local keyLocks = self:prefix('locks')
  local max = self:get()
  if max == nil then
    error({code=1, msg='Acquire(): resource ' .. self.rid .. ' does not exist'})
  end

  if type(jid) ~= 'string' then
    error({code=2, msg='Acquire(): invalid jid; expected string, got \'' .. type(jid) .. '\''})
  end


  if redis.call('sismember', self:prefix('locks'), jid) == 1 then
    return true
  end

  local remaining = max - redis.pcall('scard', keyLocks)

  if remaining > 0 then
    redis.call('sadd', keyLocks, jid)
    redis.call('zrem', self:prefix('pending'), jid)

    return true
  end

  if redis.call('zscore', self:prefix('pending'), jid) == false then
    redis.call('zadd', self:prefix('pending'), priority - (now / 10000000000), jid)
  end

  return false
end

function QlessResource:release(now, jid)
  local keyLocks = self:prefix('locks')
  local keyPending = self:prefix('pending')

  redis.call('srem', keyLocks, jid)
  redis.call('zrem', keyPending, jid)

  local jids = redis.call('zrevrange', keyPending, 0, 0, 'withscores')
  if #jids == 0 then
    return false
  end

  local newJid = jids[1]
  local score = jids[2]

  if Qless.job(newJid):acquire_resources(now) then
    local data = Qless.job(newJid):data()
    local queue = Qless.queue(data['queue'])
    queue.work.add(score, 0, newJid)
  end

  return newJid
end

function QlessResource:locks()
  return redis.call('smembers', self:prefix('locks'))
end

function QlessResource:lock_count()
  return redis.call('scard', self:prefix('locks'))
end

function QlessResource:pending()
  return redis.call('zrevrange', self:prefix('pending'), 0, -1)
end

function QlessResource:pending_count()
  return redis.call('zcard', self:prefix('pending'))
end

function QlessResource:exists()
  return redis.call('exists', self:prefix()) == 1
end

function QlessResource.all_exist(resources)
  for _, res in ipairs(resources) do
    if redis.call('exists', QlessResource.ns .. res) == 0 then
      return false
    end
  end
  return true
end

function QlessResource.pending_counts(now)
  local search = QlessResource.ns..'*-pending'
  local reply = redis.call('keys', search)
  local response = {}
  for index, rname in ipairs(reply) do
    local count = redis.call('zcard', rname)
    local resStat = {name = rname, count = count}
    table.insert(response,resStat)
  end
  return response
end

function QlessResource.locks_counts(now)
  local search = QlessResource.ns..'*-locks'
  local reply = redis.call('keys', search)
  local response = {}
  for index, rname in ipairs(reply) do
    local count = redis.call('scard', rname)
    local resStat = {name = rname, count = count}
    table.insert(response,resStat)
  end
  return response
end-------------------------------------------------------------------------------
local QlessAPI = {}

local function tonil(value)
  if (value == '') then return nil else return value end
end

function QlessAPI.get(now, jid)
  local data = Qless.job(jid):data()
  if not data then
    return nil
  end
  return cjson.encode(data)
end

function QlessAPI.multiget(now, ...)
  local results = {}
  for i, jid in ipairs(arg) do
    table.insert(results, Qless.job(jid):data())
  end
  return cjson.encode(results)
end

QlessAPI['config.get'] = function(now, key)
  key = tonil(key)
  if not key then
    return cjson.encode(Qless.config.get(key))
  else
    return Qless.config.get(key)
  end
end

QlessAPI['config.set'] = function(now, key, value)
  key = tonil(key)
  return Qless.config.set(key, value)
end

QlessAPI['config.unset'] = function(now, key)
  key = tonil(key)
  return Qless.config.unset(key)
end

QlessAPI.queues = function(now, queue)
  return cjson.encode(QlessQueue.counts(now, queue))
end

QlessAPI.complete = function(now, jid, worker, queue, data, ...)
  data = tonil(data)
  return Qless.job(jid):complete(now, worker, queue, data, unpack(arg))
end

QlessAPI.failed = function(now, group, start, limit)
  group = tonil(group)
  return cjson.encode(Qless.failed(group, start, limit))
end

QlessAPI.fail = function(now, jid, worker, group, message, data)
  data = tonil(data)
  return Qless.job(jid):fail(now, worker, group, message, data)
end

QlessAPI.jobs = function(now, state, ...)
  return Qless.jobs(now, state, unpack(arg))
end

QlessAPI.retry = function(now, jid, queue, worker, delay, group, message)
  return Qless.job(jid):retry(now, queue, worker, delay, group, message)
end

QlessAPI.depends = function(now, jid, command, ...)
  return Qless.job(jid):depends(now, command, unpack(arg))
end

QlessAPI.heartbeat = function(now, jid, worker, data)
  data = tonil(data)
  return Qless.job(jid):heartbeat(now, worker, data)
end

QlessAPI.workers = function(now, worker)
  return cjson.encode(QlessWorker.counts(now, worker))
end

QlessAPI.track = function(now, command, jid)
  return cjson.encode(Qless.track(now, command, jid))
end

QlessAPI.tag = function(now, command, ...)
  return cjson.encode(Qless.tag(now, command, unpack(arg)))
end

QlessAPI.stats = function(now, queue, date)
  return cjson.encode(Qless.queue(queue):stats(now, date))
end

QlessAPI.priority = function(now, jid, priority)
  return Qless.job(jid):priority(priority)
end

QlessAPI.log = function(now, jid, message, data)
  assert(jid, "Log(): Argument 'jid' missing")
  assert(message, "Log(): Argument 'message' missing")
  if data then
    data = assert(cjson.decode(data),
      "Log(): Argument 'data' not cjson: " .. tostring(data))
  end

  local job = Qless.job(jid)
  assert(job:exists(), 'Log(): Job ' .. jid .. ' does not exist')
  job:history(now, message, data)
end

QlessAPI.peek = function(now, queue, count)
  local jids = Qless.queue(queue):peek(now, count)
  local response = {}
  for i, jid in ipairs(jids) do
    table.insert(response, Qless.job(jid):data())
  end
  return cjson.encode(response)
end

QlessAPI.pop = function(now, queue, worker, count)
  local jids = Qless.queue(queue):pop(now, worker, count)
  local response = {}
  for i, jid in ipairs(jids) do
    table.insert(response, Qless.job(jid):data())
  end
  return cjson.encode(response)
end

QlessAPI.pause = function(now, ...)
  return QlessQueue.pause(now, unpack(arg))
end

QlessAPI.unpause = function(now, ...)
  return QlessQueue.unpause(unpack(arg))
end

QlessAPI.paused = function(now, queue)
  return Qless.queue(queue):paused()
end

QlessAPI.cancel = function(now, ...)
  return Qless.cancel(now, unpack(arg))
end

QlessAPI.timeout = function(now, ...)
  for _, jid in ipairs(arg) do
    Qless.job(jid):timeout(now)
  end
end

QlessAPI.put = function(now, me, queue, jid, klass, data, delay, ...)
  data = tonil(data)
  return Qless.queue(queue):put(now, me, jid, klass, data, delay, unpack(arg))
end

QlessAPI.requeue = function(now, me, queue, jid, ...)
  local job = Qless.job(jid)
  assert(job:exists(), 'Requeue(): Job ' .. jid .. ' does not exist')
  return QlessAPI.put(now, me, queue, jid, unpack(arg))
end

QlessAPI.unfail = function(now, queue, group, count)
  return Qless.queue(queue):unfail(now, group, count)
end

QlessAPI.recur = function(now, queue, jid, klass, data, spec, ...)
  data = tonil(data)
  return Qless.queue(queue):recur(now, jid, klass, data, spec, unpack(arg))
end

QlessAPI.unrecur = function(now, jid)
  return Qless.recurring(jid):unrecur()
end

QlessAPI['recur.get'] = function(now, jid)
  local data = Qless.recurring(jid):data()
  if not data then
    return nil
  end
  return cjson.encode(data)
end

QlessAPI['recur.update'] = function(now, jid, ...)
  return Qless.recurring(jid):update(now, unpack(arg))
end

QlessAPI['recur.tag'] = function(now, jid, ...)
  return Qless.recurring(jid):tag(unpack(arg))
end

QlessAPI['recur.untag'] = function(now, jid, ...)
  return Qless.recurring(jid):untag(unpack(arg))
end

QlessAPI.length = function(now, queue)
  return Qless.queue(queue):length()
end

QlessAPI['worker.deregister'] = function(now, ...)
  return QlessWorker.deregister(unpack(arg))
end

QlessAPI['queue.forget'] = function(now, ...)
  QlessQueue.deregister(unpack(arg))
end

QlessAPI['resource.set'] = function(now, rid, max)
  return Qless.resource(rid):set(now, max)
end

QlessAPI['resource.get'] = function(now, rid)
  return Qless.resource(rid):get()
end

QlessAPI['resource.data'] = function(now, rid)
  local data = Qless.resource(rid):data()
  if not data then
    return nil
  end

  return cjson.encode(data)
end

QlessAPI['resource.exists'] = function(now, rid)
  return Qless.resource(rid):exists()
end

QlessAPI['resource.unset'] = function(now, rid)
  return Qless.resource(rid):unset()
end

QlessAPI['resource.locks'] = function(now, rid)
  local data = Qless.resource(rid):locks()
  if not data then
    return nil
  end

  return cjson.encode(data)
end

QlessAPI['resource.lock_count'] = function(now, rid)
  return Qless.resource(rid):lock_count()
end

QlessAPI['resource.pending'] = function(now, rid)
  local data = Qless.resource(rid):pending()
  if not data then
    return nil
  end

  return cjson.encode(data)

end

QlessAPI['resource.pending_count'] = function(now, rid)
  return Qless.resource(rid):pending_count()
end

QlessAPI['resource.stats_pending'] = function(now)
  return cjson.encode(QlessResource.pending_counts(now))
end

QlessAPI['resource.stats_locks'] = function(now)
  return cjson.encode(QlessResource.locks_counts(now))
end


if #KEYS > 0 then error('No Keys should be provided') end

local command_name = assert(table.remove(ARGV, 1), 'Must provide a command')
local command      = assert(
  QlessAPI[command_name], 'Unknown command ' .. command_name)

local now          = tonumber(table.remove(ARGV, 1))
local now          = assert(
  now, 'Arg "now" missing or not a number: ' .. (now or 'nil'))

return command(now, unpack(ARGV))
