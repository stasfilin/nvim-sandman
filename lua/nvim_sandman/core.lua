local M = {}

local uv = vim.loop

local state = {
  enabled = false,
  mode = 'block_all', -- block_all | blocklist | allowlist
  allow = {},
  block = {},
  installed = false,
  on_block = nil,
  detect_plugin = nil,
  env_block = true,
  env_backup = nil,
  stats = {
    total = { attempts = 0, blocked = 0, allowed = 0 },
    by_plugin = {},
    by_action = {},
  },
}

local function set_from_list(list)
  local t = {}
  for _, v in ipairs(list) do
    if type(v) == 'string' and v ~= '' then
      t[v] = true
    end
  end
  return t
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
      state.env_backup = {
        http_proxy = vim.env.http_proxy,
        https_proxy = vim.env.https_proxy,
        HTTP_PROXY = vim.env.HTTP_PROXY,
        HTTPS_PROXY = vim.env.HTTPS_PROXY,
        ALL_PROXY = vim.env.ALL_PROXY,
        all_proxy = vim.env.all_proxy,
        NO_PROXY = vim.env.NO_PROXY,
        no_proxy = vim.env.no_proxy,
      }
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
      for k, v in pairs(state.env_backup) do
        vim.env[k] = v
      end
      state.env_backup = nil
    end
  end
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
    if plugin and state.allow[plugin] then return false end
    return true
  end

  if state.mode == 'blocklist' then
    if plugin and state.block[plugin] then return true end
    return false
  end

  if state.mode == 'allowlist' then
    if plugin and state.allow[plugin] then return false end
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
    return fallback
  end
  return nil
end

local originals = {}

local function wrap_function(owner, name, action, fallback)
  if type(owner[name]) ~= 'function' then return end
  if originals[owner] == nil then originals[owner] = {} end
  if originals[owner][name] then return end
  originals[owner][name] = owner[name]
  owner[name] = function(...)
    local blocked = guard(action, fallback)
    if blocked ~= nil then
      return blocked
    end
    return originals[owner][name](...)
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
          if blocked ~= nil then
            return
          end
          return handle:connect(host, port, cb)
        end
      end
      if key == 'send' and kind == 'udp' then
        return function(_, data, host, port, cb)
          local blocked = guard('udp_send', nil)
          if blocked ~= nil then
            return
          end
          return handle:send(data, host, port, cb)
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

  if uv then
    wrap_function(uv, 'spawn', 'uv.spawn', nil)
    wrap_function(uv, 'tcp_connect', 'uv.tcp_connect', nil)
    wrap_function(uv, 'udp_send', 'uv.udp_send', nil)

    if type(uv.new_tcp) == 'function' then
      if originals[uv] == nil then originals[uv] = {} end
      if not originals[uv].new_tcp then
        originals[uv].new_tcp = uv.new_tcp
        uv.new_tcp = function(...)
          local h = originals[uv].new_tcp(...)
          return wrap_uv_handle(h, 'tcp')
        end
      end
    end

    if type(uv.new_udp) == 'function' then
      if originals[uv] == nil then originals[uv] = {} end
      if not originals[uv].new_udp then
        originals[uv].new_udp = uv.new_udp
        uv.new_udp = function(...)
          local h = originals[uv].new_udp(...)
          return wrap_uv_handle(h, 'udp')
        end
      end
    end
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
  if opts.on_block then
    state.on_block = opts.on_block
  end
  if opts.detect_plugin then
    state.detect_plugin = opts.detect_plugin
  end
  if opts.env_block ~= nil then
    state.env_block = opts.env_block == true
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
    vim.api.nvim_create_user_command('NetworkBlock', function()
      M.block_all()
    end, {})

    vim.api.nvim_create_user_command('NetworkUnblock', function()
      M.unblock()
    end, {})

    vim.api.nvim_create_user_command('NetworkBlockOnly', function(cmd)
      M.block_only(cmd.fargs)
    end, { nargs = '*', complete = 'file' })

    vim.api.nvim_create_user_command('NetworkAllowOnly', function(cmd)
      M.allow_only(cmd.fargs)
    end, { nargs = '*', complete = 'file' })

    vim.api.nvim_create_user_command('NetworkStats', function()
      local summary = M.stats_summary()
      vim.schedule(function()
        vim.notify(summary, vim.log.levels.INFO)
      end)
    end, {})

    vim.api.nvim_create_user_command('NetworkStatsReset', function()
      M.stats_reset()
    end, {})
  end

  set_env_blocked(state.enabled)
end

function M.block_all()
  state.enabled = true
  state.mode = 'block_all'
  state.allow = {}
  state.block = {}
  set_env_blocked(true)
end

function M.unblock()
  state.enabled = false
  set_env_blocked(false)
end

function M.block_only(list)
  state.enabled = true
  state.mode = 'blocklist'
  state.block = set_from_list(list)
  set_env_blocked(true)
end

function M.allow_only(list)
  state.enabled = true
  state.mode = 'allowlist'
  state.allow = set_from_list(list)
  set_env_blocked(true)
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

  return table.concat(lines, '\\n')
end

return M
