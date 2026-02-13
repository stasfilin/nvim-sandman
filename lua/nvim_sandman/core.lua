local M = {}

local uv = vim.loop

local state = {
  enabled = false,
  mode = 'block_all', -- block_all | blocklist | allowlist
  allow = {},
  block = {},
  ignore_notifications = {},
  installed = false,
  on_block = nil,
  detect_plugin = nil,
  env_block = true,
  env_backup = nil,
  temp_net_ms = 60000,
  stats = {
    total = { attempts = 0, blocked = 0, allowed = 0 },
    by_plugin = {},
    by_action = {},
  },
}

local PROXY_ENV_KEYS = {
  'http_proxy',
  'https_proxy',
  'HTTP_PROXY',
  'HTTPS_PROXY',
  'ALL_PROXY',
  'all_proxy',
  'NO_PROXY',
  'no_proxy',
}

local function pack(...)
  return { n = select('#', ...), ... }
end

local function unpack_values(t, i, j)
  i = i or 1
  j = j or t.n or #t
  if i > j then
    return
  end
  return t[i], unpack_values(t, i + 1, j)
end

local function set_from_list(list)
  local t = {}
  for _, v in ipairs(list) do
    if type(v) == 'string' and v ~= '' then
      t[v:lower()] = true
    end
  end
  return t
end

local function set_from_list_lower(list)
  local t = {}
  for _, v in ipairs(list) do
    if type(v) == 'string' and v ~= '' then
      t[v:lower()] = true
    end
  end
  return t
end

local function ignored_notification_for(plugin)
  plugin = plugin or 'unknown'
  local name = plugin:lower()

  if state.ignore_notifications[name] then
    return true
  end

  if name:sub(-5) == '.nvim' then
    local short = name:sub(1, -6)
    if state.ignore_notifications[short] then
      return true
    end
  else
    if state.ignore_notifications[name .. '.nvim'] then
      return true
    end
  end

  return false
end

local function set_contains_plugin(set, plugin)
  if not plugin then
    return false
  end

  local name = plugin:lower()
  if set[name] then
    return true
  end

  if name:sub(-5) == '.nvim' or name:sub(-4) == '.vim' then
    local short = name:gsub('%.nvim$', ''):gsub('%.vim$', '')
    if set[short] then
      return true
    end
  else
    if set[name .. '.nvim'] or set[name .. '.vim'] then
      return true
    end
  end

  return false
end

local function detect_plugin_default()
  -- Walk the stack looking for a plugin path
  for level = 3, 20 do
    local info = debug.getinfo(level, 'S')
    if not info then break end
    local src = info.source
    if type(src) == 'string' and src:sub(1, 1) == '@' then
      local path = src:sub(2)
      if not path:match('/nvim%-sandman/') then
        local name =
          path:match('/site/pack/[^/]+/start/([^/]+)/') or
          path:match('/site/pack/[^/]+/opt/([^/]+)/') or
          path:match('/pack/packer/start/([^/]+)/') or
          path:match('/pack/packer/opt/([^/]+)/') or
          path:match('/lazy/([^/]+)/') or
          path:match('/plugged/([^/]+)/') or
          path:match('/bundle/([^/]+)/')
        if name then return name end
      end
    end
  end
  return nil
end

local function set_env_blocked(blocked)
  if not state.env_block then
    return
  end

  if blocked then
    if not state.env_backup then
      state.env_backup = {}
      for _, k in ipairs(PROXY_ENV_KEYS) do
        state.env_backup[k] = vim.env[k]
      end
    end

    local invalid = '127.0.0.1:1'
    vim.env.http_proxy = invalid
    vim.env.https_proxy = invalid
    vim.env.HTTP_PROXY = invalid
    vim.env.HTTPS_PROXY = invalid
    vim.env.ALL_PROXY = invalid
    vim.env.all_proxy = invalid
    vim.env.NO_PROXY = nil
    vim.env.no_proxy = nil
  else
    if state.env_backup then
      for _, k in ipairs(PROXY_ENV_KEYS) do
        vim.env[k] = state.env_backup[k]
      end
      state.env_backup = nil
    else
      -- Clear any existing proxy vars if no backup was captured
      for _, k in ipairs(PROXY_ENV_KEYS) do
        vim.env[k] = nil
      end
    end
  end
end

local function should_block_env()
  if not state.env_block or not state.enabled then
    return false
  end

  -- Keep process-wide proxy lock for strict block_all mode.
  -- Allowed plugins can get per-call env restoration in wrappers.
  return state.mode == 'block_all'
end

local function refresh_env_block()
  set_env_blocked(should_block_env())
end

local function with_unblocked_env(fn)
  if not should_block_env() or not state.env_backup then
    return fn()
  end

  local poisoned = {}
  for _, k in ipairs(PROXY_ENV_KEYS) do
    poisoned[k] = vim.env[k]
    vim.env[k] = state.env_backup[k]
  end

  local result = pack(pcall(fn))

  for _, k in ipairs(PROXY_ENV_KEYS) do
    vim.env[k] = poisoned[k]
  end

  if not result[1] then
    error(result[2])
  end

  return unpack_values(result, 2, result.n)
end

local function current_plugin()
  if state.detect_plugin then
    local ok, name = pcall(state.detect_plugin)
    if ok then return name end
  end
  return detect_plugin_default()
end

local function is_blocked_for(plugin)
  if not state.enabled then return false end

  if state.mode == 'block_all' then
    if set_contains_plugin(state.allow, plugin) then return false end
    return true
  end

  if state.mode == 'blocklist' then
    if set_contains_plugin(state.block, plugin) then return true end
    return false
  end

  if state.mode == 'allowlist' then
    if set_contains_plugin(state.allow, plugin) then return false end
    return true
  end

  return false
end

local function record_stats(action, plugin, blocked)
  state.stats.total.attempts = state.stats.total.attempts + 1
  if blocked then
    state.stats.total.blocked = state.stats.total.blocked + 1
  else
    state.stats.total.allowed = state.stats.total.allowed + 1
  end

  plugin = plugin or 'unknown'
  state.stats.by_plugin[plugin] = state.stats.by_plugin[plugin] or { attempts = 0, blocked = 0, allowed = 0 }
  state.stats.by_plugin[plugin].attempts = state.stats.by_plugin[plugin].attempts + 1
  if blocked then
    state.stats.by_plugin[plugin].blocked = state.stats.by_plugin[plugin].blocked + 1
  else
    state.stats.by_plugin[plugin].allowed = state.stats.by_plugin[plugin].allowed + 1
  end

  state.stats.by_action[action] = state.stats.by_action[action] or { attempts = 0, blocked = 0, allowed = 0 }
  state.stats.by_action[action].attempts = state.stats.by_action[action].attempts + 1
  if blocked then
    state.stats.by_action[action].blocked = state.stats.by_action[action].blocked + 1
  else
    state.stats.by_action[action].allowed = state.stats.by_action[action].allowed + 1
  end
end

local function on_block(action, plugin)
  plugin = plugin or 'unknown'
  if ignored_notification_for(plugin) then
    return
  end
  local msg = string.format('nvim-sandman: blocked %s from %s', action, plugin)
  if type(state.on_block) == 'function' then
    pcall(state.on_block, { action = action, plugin = plugin, message = msg })
  else
    vim.schedule(function()
      vim.notify(msg, vim.log.levels.WARN)
    end)
  end
end

local function guard(action, fallback)
  local plugin = current_plugin()
  local blocked = is_blocked_for(plugin)
  record_stats(action, plugin, blocked)
  if blocked then
    on_block(action, plugin)
    return true, fallback
  end
  return false, plugin
end

local originals = {}

local function wrap_function(owner, name, action, fallback)
  if type(owner[name]) ~= 'function' then return end
  if originals[owner] == nil then originals[owner] = {} end
  if originals[owner][name] then return end
  originals[owner][name] = owner[name]
  owner[name] = function(...)
    local args = pack(...)
    local blocked, payload = guard(action, fallback)
    if blocked then
      return payload
    end
    return with_unblocked_env(function()
      return originals[owner][name](unpack_values(args, 1, args.n))
    end)
  end
end

local function wrap_uv_handle(handle, kind)
  if type(handle) ~= 'userdata' then
    return handle
  end

  local proxy = { _handle = handle }
  local mt = {
    __index = function(_, key)
      if key == 'connect' and kind == 'tcp' then
        return function(_, host, port, cb)
          local blocked = guard('tcp_connect', nil)
          if blocked then
            return
          end
          return with_unblocked_env(function()
            return handle:connect(host, port, cb)
          end)
        end
      end
      if key == 'send' and kind == 'udp' then
        return function(_, data, host, port, cb)
          local blocked = guard('udp_send', nil)
          if blocked then
            return
          end
          return with_unblocked_env(function()
            return handle:send(data, host, port, cb)
          end)
        end
      end

      local v = handle[key]
      if type(v) == 'function' then
        return function(_, ...)
          return v(handle, ...)
        end
      end
      return v
    end,
    __newindex = function(_, key, value)
      handle[key] = value
    end,
    __tostring = function()
      return tostring(handle)
    end,
  }

  return setmetatable(proxy, mt)
end

local function install_uv_wrappers(uvlib)
  if not uvlib then
    return
  end

  wrap_function(uvlib, 'spawn', 'uv.spawn', nil)
  wrap_function(uvlib, 'tcp_connect', 'uv.tcp_connect', nil)
  wrap_function(uvlib, 'udp_send', 'uv.udp_send', nil)

  if type(uvlib.new_tcp) == 'function' then
    if originals[uvlib] == nil then originals[uvlib] = {} end
    if not originals[uvlib].new_tcp then
      originals[uvlib].new_tcp = uvlib.new_tcp
      uvlib.new_tcp = function(...)
        local h = originals[uvlib].new_tcp(...)
        return wrap_uv_handle(h, 'tcp')
      end
    end
  end

  if type(uvlib.new_udp) == 'function' then
    if originals[uvlib] == nil then originals[uvlib] = {} end
    if not originals[uvlib].new_udp then
      originals[uvlib].new_udp = uvlib.new_udp
      uvlib.new_udp = function(...)
        local h = originals[uvlib].new_udp(...)
        return wrap_uv_handle(h, 'udp')
      end
    end
  end
end

local function install_wrappers()
  if state.installed then return end
  state.installed = true

  wrap_function(vim, 'system', 'vim.system', nil)
  wrap_function(vim.fn, 'system', 'vim.fn.system', '')
  wrap_function(vim.fn, 'systemlist', 'vim.fn.systemlist', {})
  wrap_function(vim.fn, 'jobstart', 'vim.fn.jobstart', -1)
  wrap_function(vim.fn, 'termopen', 'vim.fn.termopen', -1)
  wrap_function(vim, 'jobstart', 'vim.jobstart', -1)
  wrap_function(os, 'execute', 'os.execute', false)
  wrap_function(io, 'popen', 'io.popen', nil)

  install_uv_wrappers(uv)
  if vim.uv and vim.uv ~= uv then
    install_uv_wrappers(vim.uv)
  end
end

function M.setup(opts)
  install_wrappers()

  if opts.enabled ~= nil then
    state.enabled = opts.enabled
  end
  if opts.mode then
    state.mode = opts.mode
  end
  if opts.allow then
    state.allow = set_from_list(opts.allow)
  end
  if opts.block then
    state.block = set_from_list(opts.block)
  end
  if opts.ignore_notifications then
    state.ignore_notifications = set_from_list_lower(opts.ignore_notifications)
  end
  if opts.on_block then
    state.on_block = opts.on_block
  end
  if opts.detect_plugin then
    state.detect_plugin = opts.detect_plugin
  end
  if opts.env_block ~= nil then
    state.env_block = opts.env_block == true
  end
  if opts.temp_net_ms ~= nil then
    state.temp_net_ms = tonumber(opts.temp_net_ms) or state.temp_net_ms
  end
  if opts.stats ~= nil then
    if opts.stats == false then
      state.stats = {
        total = { attempts = 0, blocked = 0, allowed = 0 },
        by_plugin = {},
        by_action = {},
      }
    end
  end

  if opts.commands ~= false then
    vim.api.nvim_create_user_command('Sandman', function(cmd)
      local sub = cmd.fargs[1]
      if sub == 'block' then
        M.block_all()
        return
      end
      if sub == 'unblock' then
        M.unblock()
        return
      end
      if sub == 'block-only' then
        M.block_only(vim.list_slice(cmd.fargs, 2))
        return
      end
      if sub == 'allow-only' then
        M.allow_only(vim.list_slice(cmd.fargs, 2))
        return
      end
      if sub == 'stats' then
        local summary = M.stats_summary()
        vim.schedule(function()
          vim.notify(summary, vim.log.levels.INFO)
        end)
        return
      end
      if sub == 'stats-reset' then
        M.stats_reset()
        return
      end
      if sub == 'env-clear' then
        M.env_clear()
        return
      end
      if sub == 'temp-net' then
        local ms = tonumber(cmd.fargs[2]) or state.temp_net_ms
        M.temp_net(ms)
        return
      end

      vim.schedule(function()
        local msg =
          'nvim-sandman: unknown subcommand. Use :Sandman ' ..
          'block|unblock|block-only|allow-only|stats|stats-reset|env-clear|temp-net [ms]'
        vim.notify(msg, vim.log.levels.WARN)
      end)
    end, {
      nargs = '+',
      complete = function(_, line)
        local subs = {
          'block',
          'unblock',
          'block-only',
          'allow-only',
          'stats',
          'stats-reset',
          'env-clear',
          'temp-net',
        }
        local args = vim.split(line, '%s+')
        if #args <= 2 then
          return subs
        end
        return {}
      end,
    })
  end

  refresh_env_block()
end

function M.block_all()
  state.enabled = true
  state.mode = 'block_all'
  state.allow = {}
  state.block = {}
  refresh_env_block()
end

function M.unblock()
  state.enabled = false
  M.env_clear()
end

function M.block_only(list)
  state.enabled = true
  state.mode = 'blocklist'
  state.block = set_from_list(list)
  refresh_env_block()
end

function M.allow_only(list)
  state.enabled = true
  state.mode = 'allowlist'
  state.allow = set_from_list(list)
  refresh_env_block()
end

function M.env_clear()
  state.env_backup = nil
  set_env_blocked(false)
end

function M.temp_net(ms)
  local duration = tonumber(ms) or state.temp_net_ms
  if duration <= 0 then
    return
  end

  local was_enabled = state.enabled
  M.unblock()

  vim.schedule(function()
    vim.notify(string.format('nvim-sandman: network ON for %d ms', duration), vim.log.levels.INFO)
  end)

  vim.defer_fn(function()
    if was_enabled then
      M.block_all()
    end
    vim.schedule(function()
      vim.notify('nvim-sandman: network OFF', vim.log.levels.INFO)
    end)
  end, duration)
end

function M.stats()
  return vim.deepcopy(state.stats)
end

function M.stats_reset()
  state.stats = {
    total = { attempts = 0, blocked = 0, allowed = 0 },
    by_plugin = {},
    by_action = {},
  }
end

function M.stats_summary()
  local t = state.stats
  local lines = {
    string.format(
      'nvim-sandman stats: attempts=%d blocked=%d allowed=%d',
      t.total.attempts,
      t.total.blocked,
      t.total.allowed
    ),
  }

  local plugins = {}
  for name, s in pairs(t.by_plugin) do
    table.insert(
      plugins,
      { name = name, attempts = s.attempts, blocked = s.blocked, allowed = s.allowed }
    )
  end
  table.sort(plugins, function(a, b) return a.attempts > b.attempts end)

  for i = 1, math.min(#plugins, 10) do
    local p = plugins[i]
    table.insert(
      lines,
      string.format('plugin %s: attempts=%d blocked=%d allowed=%d', p.name, p.attempts, p.blocked, p.allowed)
    )
  end

  return table.concat(lines, '\n')
end

return M
