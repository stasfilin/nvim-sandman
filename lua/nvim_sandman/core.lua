local M = {}

local uv = vim.loop

local policy_config = require('nvim_sandman.policy.config')
local policy_engine = require('nvim_sandman.policy.engine')
local policy_prompt = require('nvim_sandman.policy.prompt')
local policy_audit = require('nvim_sandman.policy.audit')

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
  policy = {
    enabled = false,
    config = nil,
  },
  stats_enabled = true,
  stats_storage = 'memory',
  stats_path = nil,
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

local DEFAULT_STATS_FILE = 'nvim-sandman-stats.json'

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

local function basename(path)
  if type(path) ~= 'string' then
    return ''
  end

  local normalized = path:gsub('\\', '/')
  return normalized:match('([^/]+)$') or normalized
end

local function current_cwd()
  if uv and type(uv.cwd) == 'function' then
    local ok, cwd = pcall(uv.cwd)
    if ok and type(cwd) == 'string' and cwd ~= '' then
      return cwd
    end
  end

  if vim and vim.fn and type(vim.fn.getcwd) == 'function' then
    local ok, cwd = pcall(vim.fn.getcwd)
    if ok and type(cwd) == 'string' and cwd ~= '' then
      return cwd
    end
  end

  return '.'
end

local function fresh_stats()
  return {
    total = { attempts = 0, blocked = 0, allowed = 0 },
    by_plugin = {},
    by_action = {},
  }
end

local function dirname(path)
  if type(path) ~= 'string' then
    return nil
  end

  local normalized = path:gsub('\\', '/')
  local parent = normalized:match('^(.*)/[^/]*$')
  if parent == '' then
    return nil
  end
  return parent
end

local function encode_json(value)
  if vim and vim.fn and type(vim.fn.json_encode) == 'function' then
    local ok, out = pcall(vim.fn.json_encode, value)
    if ok and type(out) == 'string' then
      return out
    end
  end

  if vim and vim.json and type(vim.json.encode) == 'function' then
    local ok, out = pcall(vim.json.encode, value)
    if ok and type(out) == 'string' then
      return out
    end
  end

  return nil
end

local function decode_json(content)
  if vim and vim.fn and type(vim.fn.json_decode) == 'function' then
    local ok, out = pcall(vim.fn.json_decode, content)
    if ok and type(out) == 'table' then
      return out
    end
  end

  if vim and vim.json and type(vim.json.decode) == 'function' then
    local ok, out = pcall(vim.json.decode, content)
    if ok and type(out) == 'table' then
      return out
    end
  end

  return nil
end

local function normalize_stats_bucket(value)
  value = type(value) == 'table' and value or {}
  return {
    attempts = tonumber(value.attempts) or 0,
    blocked = tonumber(value.blocked) or 0,
    allowed = tonumber(value.allowed) or 0,
  }
end

local function normalize_stats_value(value)
  value = type(value) == 'table' and value or {}
  local out = fresh_stats()
  out.total = normalize_stats_bucket(value.total)

  if type(value.by_plugin) == 'table' then
    for key, bucket in pairs(value.by_plugin) do
      if type(key) == 'string' and key ~= '' then
        out.by_plugin[key] = normalize_stats_bucket(bucket)
      end
    end
  end

  if type(value.by_action) == 'table' then
    for key, bucket in pairs(value.by_action) do
      if type(key) == 'string' and key ~= '' then
        out.by_action[key] = normalize_stats_bucket(bucket)
      end
    end
  end

  return out
end

local function default_stats_path()
  if vim and vim.fn and type(vim.fn.stdpath) == 'function' then
    local ok, state_path = pcall(vim.fn.stdpath, 'state')
    if ok and type(state_path) == 'string' and state_path ~= '' then
      return state_path .. '/' .. DEFAULT_STATS_FILE
    end
  end
  return DEFAULT_STATS_FILE
end

local function load_stats_from_file(path)
  if type(path) ~= 'string' or path == '' then
    return nil
  end

  local file = io.open(path, 'r')
  if not file then
    return nil
  end

  local ok, content = pcall(file.read, file, '*a')
  file:close()
  if not ok or type(content) ~= 'string' or content == '' then
    return nil
  end

  local decoded = decode_json(content)
  if not decoded then
    return nil
  end
  return normalize_stats_value(decoded)
end

local function persist_stats()
  if not state.stats_enabled or state.stats_storage ~= 'file' or type(state.stats_path) ~= 'string' or state.stats_path == '' then
    return
  end

  local data = encode_json(state.stats)
  if not data then
    return
  end

  local parent = dirname(state.stats_path)
  if parent and vim and vim.fn and type(vim.fn.mkdir) == 'function' then
    pcall(vim.fn.mkdir, parent, 'p')
  end

  local file = io.open(state.stats_path, 'w')
  if not file then
    return
  end

  file:write(data)
  file:close()
end

local function apply_stats_setup(stats_opts)
  if stats_opts == false then
    state.stats_enabled = false
    state.stats_storage = 'memory'
    state.stats_path = nil
    state.stats = fresh_stats()
    return
  end

  state.stats_enabled = true

  if type(stats_opts) ~= 'table' then
    state.stats_storage = 'memory'
    state.stats_path = nil
    return
  end

  if stats_opts.enabled == false then
    state.stats_enabled = false
    state.stats_storage = 'memory'
    state.stats_path = nil
    state.stats = fresh_stats()
    return
  end

  local storage = stats_opts.storage
  if storage ~= 'memory' and storage ~= 'file' then
    storage = 'memory'
  end
  state.stats_storage = storage

  if storage == 'file' then
    state.stats_path = type(stats_opts.path) == 'string' and stats_opts.path or default_stats_path()
    local loaded = load_stats_from_file(state.stats_path)
    if loaded then
      state.stats = loaded
    else
      persist_stats()
    end
    return
  end

  state.stats_path = nil
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
  if not state.stats_enabled then
    return
  end

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

  persist_stats()
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

local function parse_exec_command(cmd)
  if type(cmd) == 'table' then
    local out = {}
    for idx = 2, #cmd do
      out[#out + 1] = tostring(cmd[idx])
    end

    local exe = basename(tostring(cmd[1] or ''))
    local target = table.concat(vim.tbl_map(tostring, cmd), ' ')
    return exe, out, target
  end

  if type(cmd) == 'string' then
    local first = cmd:match('^%s*(%S+)') or ''
    return basename(first), {}, cmd
  end

  return '', {}, ''
end

local function build_policy_request(action, args)
  local req = nil

  if action == 'vim.system' then
    local cmd = args[1]
    local opts = args[2]
    local exe, cmd_args, target = parse_exec_command(cmd)
    req = {
      action = 'exec',
      exe = exe,
      args = cmd_args,
      target = target,
      cwd = type(opts) == 'table' and opts.cwd or current_cwd(),
    }
  elseif
    action == 'vim.fn.system'
    or action == 'vim.fn.systemlist'
    or action == 'vim.fn.jobstart'
    or action == 'vim.jobstart'
    or action == 'vim.fn.termopen'
  then
    local cmd = args[1]
    local opts = args[2]
    local exe, cmd_args, target = parse_exec_command(cmd)
    req = {
      action = 'exec',
      exe = exe,
      args = cmd_args,
      target = target,
      cwd = type(opts) == 'table' and opts.cwd or current_cwd(),
    }
  elseif action == 'uv.spawn' then
    local path = args[1]
    local opts = type(args[2]) == 'table' and args[2] or {}
    local cmd_args = {}
    for _, arg in ipairs(opts.args or {}) do
      cmd_args[#cmd_args + 1] = tostring(arg)
    end
    local exe = basename(tostring(path or ''))
    local target = exe
    if #cmd_args > 0 then
      target = target .. ' ' .. table.concat(cmd_args, ' ')
    end
    req = {
      action = 'exec',
      exe = exe,
      args = cmd_args,
      target = target,
      cwd = opts.cwd or current_cwd(),
    }
  elseif action == 'os.execute' or action == 'io.popen' then
    local exe, cmd_args, target = parse_exec_command(args[1])
    req = {
      action = 'exec',
      exe = exe,
      args = cmd_args,
      target = target,
      cwd = current_cwd(),
    }
  elseif action == 'tcp_connect' then
    req = {
      action = 'socket',
      target = string.format('%s:%s', tostring(args[1]), tostring(args[2])),
      cwd = current_cwd(),
    }
  elseif action == 'udp_send' then
    req = {
      action = 'socket',
      target = string.format('%s:%s', tostring(args[2]), tostring(args[3])),
      cwd = current_cwd(),
    }
  end

  return req
end

local function now_iso()
  return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

local function evaluate_policy(req)
  if not state.policy.enabled or not state.policy.config or not req then
    return false
  end

  local verdict = policy_engine.evaluate(req, state.policy.config)
  local decision = verdict.decision

  if decision == 'prompt_once' then
    decision = policy_prompt.resolve(req)
  end

  local blocked = state.policy.config.mode == 'enforce' and decision == 'deny'
  local result = blocked and 'blocked' or 'allowed'

  if state.policy.config.mode == 'monitor' and decision == 'deny' then
    result = 'allowed_monitor'
  end

  policy_audit.append({
    ts = now_iso(),
    action = req.action,
    actor = req.actor,
    actor_confidence = req.actor_confidence,
    target = req.target,
    cwd = req.cwd,
    decision = decision,
    rule_id = verdict.rule_id,
    mode = state.policy.config.mode,
    result = result,
  })

  return blocked
end

local function guard(action, fallback, raw_args)
  local plugin = current_plugin()
  local legacy_blocked = is_blocked_for(plugin)

  local req = build_policy_request(action, raw_args or {})
  if req then
    req.actor = plugin or 'unknown'
    req.actor_confidence = plugin and 0.8 or 0.0
    req.cwd = req.cwd or current_cwd()
  end

  local policy_blocked = evaluate_policy(req)
  local blocked = legacy_blocked or policy_blocked

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
    local blocked, payload = guard(action, fallback, args)
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
          local blocked = guard('tcp_connect', nil, { host, port, cb })
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
          local blocked = guard('udp_send', nil, { data, host, port, cb })
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

local function apply_policy_setup(policy_opts)
  if type(policy_opts) ~= 'table' then
    state.policy.enabled = false
    state.policy.config = nil
    policy_prompt.clear()
    return
  end

  local normalized = policy_config.normalize(policy_opts)
  state.policy.enabled = normalized.enabled == true
  state.policy.config = normalized

  policy_audit.setup(normalized.audit)
  policy_prompt.clear()
end

function M.setup(opts)
  opts = opts or {}
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
    apply_stats_setup(opts.stats)
  end

  if opts.policy ~= nil then
    apply_policy_setup(opts.policy)
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
        vim.notify(summary, vim.log.levels.INFO)
        return
      end
      if sub == 'stats-reset' then
        M.stats_reset()
        vim.notify('nvim-sandman: stats reset', vim.log.levels.INFO)
        return
      end
      if sub == 'env-clear' then
        M.env_clear()
        vim.notify('nvim-sandman: env proxy vars restored/cleared', vim.log.levels.INFO)
        return
      end
      if sub == 'temp-net' then
        M.temp_net(tonumber(cmd.fargs[2]))
        return
      end
      if sub == 'policy-status' then
        local p = M.policy_status()
        if not p.enabled then
          vim.notify('nvim-sandman policy: disabled', vim.log.levels.INFO)
          return
        end
        local status_msg = string.format(
          'nvim-sandman policy: enabled mode=%s default=%s rules=%d',
          p.mode,
          p.default,
          p.rules
        )
        vim.notify(status_msg, vim.log.levels.INFO)
        return
      end
      if sub == 'policy-audit' then
        local lines = M.policy_audit_tail(tonumber(cmd.fargs[2]) or 20)
        if #lines == 0 then
          vim.notify('nvim-sandman policy: audit log is empty', vim.log.levels.INFO)
          return
        end
        vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO)
        return
      end

      local usage_msg = table.concat({
        'nvim-sandman: unknown subcommand. Use :Sandman',
        'block|unblock|block-only|allow-only|stats|stats-reset|env-clear|temp-net|policy-status|policy-audit',
      }, ' ')
      vim.notify(usage_msg, vim.log.levels.WARN)
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
          'policy-status',
          'policy-audit',
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
  state.stats = fresh_stats()
  persist_stats()
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

function M.policy_status()
  if not state.policy.enabled or not state.policy.config then
    return { enabled = false }
  end

  return {
    enabled = true,
    mode = state.policy.config.mode,
    default = state.policy.config.default,
    rules = #state.policy.config.rules,
    audit_path = state.policy.config.audit and state.policy.config.audit.path or nil,
  }
end

function M.policy_audit_tail(n)
  return policy_audit.tail(n)
end

return M
