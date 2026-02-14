local ROOT = (... and ... ~= '' and ...) or '.'

package.path = table.concat({
  ROOT .. '/lua/?.lua',
  ROOT .. '/lua/?/init.lua',
  package.path,
}, ';')

local function tbl_deepcopy(orig, seen)
  if type(orig) ~= 'table' then
    return orig
  end
  if seen and seen[orig] then
    return seen[orig]
  end
  local s = seen or {}
  local copy = {}
  s[orig] = copy
  for k, v in pairs(orig) do
    copy[tbl_deepcopy(k, s)] = tbl_deepcopy(v, s)
  end
  return setmetatable(copy, getmetatable(orig))
end

local function to_lua_literal(value)
  local tv = type(value)
  if tv == 'nil' then
    return 'nil'
  end
  if tv == 'number' or tv == 'boolean' then
    return tostring(value)
  end
  if tv == 'string' then
    return string.format('%q', value)
  end
  if tv == 'table' then
    local parts = {}
    for k, v in pairs(value) do
      local key
      if type(k) == 'string' and k:match('^[%a_][%w_]*$') then
        key = k
      else
        key = '[' .. to_lua_literal(k) .. ']'
      end
      parts[#parts + 1] = key .. ' = ' .. to_lua_literal(v)
    end
    return '{' .. table.concat(parts, ', ') .. '}'
  end
  error('unsupported value type for test serializer: ' .. tv)
end

local function reset_vim()
  _G.vim = {
    loop = {},
    uv = {},
    env = {},
    fn = {
      stdpath = function() return '/tmp' end,
      mkdir = function() return 1 end,
      system = function() return '' end,
      systemlist = function() return {} end,
      jobstart = function() return 1 end,
      termopen = function() return 1 end,
      json_encode = function(value)
        return to_lua_literal(value)
      end,
      json_decode = function(content)
        local chunk, err = load('return ' .. content, 'stats_decode', 't', {})
        if not chunk then
          error(err)
        end
        return chunk()
      end,
    },
    system = function() return true end,
    tbl_map = function(fn, list)
      local out = {}
      for i, v in ipairs(list) do
        out[i] = fn(v)
      end
      return out
    end,
    jobstart = function() return 1 end,
    schedule = function(cb) cb() end,
    defer_fn = function(cb, _) cb() end,
    notify = function(_, _) end,
    list_slice = function(list, first)
      local out = {}
      for i = first, #list do
        out[#out + 1] = list[i]
      end
      return out
    end,
    split = function(str, _)
      local out = {}
      for part in string.gmatch(str, '%S+') do
        out[#out + 1] = part
      end
      return out
    end,
    deepcopy = tbl_deepcopy,
    api = {
      nvim_create_user_command = function(_, _, _) end,
      nvim__get_runtime = function() return {} end,
    },
    log = {
      levels = {
        INFO = 1,
        WARN = 2,
      },
    },
  }
end

local function load_core()
  package.loaded['nvim_sandman.core'] = nil
  return require('nvim_sandman.core')
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format('%s\nexpected: %s\nactual: %s', msg, tostring(expected), tostring(actual)))
  end
end

local tests = {}

local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

test('block_all without allow poisons proxy env vars', function()
  reset_vim()
  local core = load_core()

  core.setup({ enabled = true, mode = 'block_all', env_block = true, commands = false })

  assert_eq(vim.env.http_proxy, '127.0.0.1:1', 'http_proxy should be poisoned')
  assert_eq(vim.env.https_proxy, '127.0.0.1:1', 'https_proxy should be poisoned')
end)

test('block_all with allow keeps proxy env vars poisoned (strict lock)', function()
  reset_vim()
  local core = load_core()

  core.setup({
    enabled = true,
    mode = 'block_all',
    allow = { 'lazy.nvim' },
    env_block = true,
    commands = false,
  })

  assert_eq(vim.env.http_proxy, '127.0.0.1:1', 'http_proxy should stay poisoned in strict block_all')
  assert_eq(vim.env.https_proxy, '127.0.0.1:1', 'https_proxy should stay poisoned in strict block_all')
end)

test('allowed plugin gets clean env for wrapped call in strict block_all', function()
  reset_vim()
  local captured_proxy = nil
  vim.fn.system = function()
    captured_proxy = vim.env.http_proxy
    return 'ok'
  end

  local core = load_core()

  core.setup({
    enabled = true,
    mode = 'block_all',
    allow = { 'lazy.nvim' },
    detect_plugin = function() return 'lazy.nvim' end,
    env_block = true,
    commands = false,
  })

  local out = vim.fn.system('echo test')

  assert_eq(out, 'ok', 'allowed plugin call should pass through')
  assert_eq(captured_proxy, nil, 'allowed plugin should see original proxy env')
  assert_eq(vim.env.http_proxy, '127.0.0.1:1', 'global proxy lock should be restored after call')
end)

test('blocked plugin remains blocked in strict block_all', function()
  reset_vim()
  local called = false
  vim.fn.system = function()
    called = true
    return 'ok'
  end

  local core = load_core()

  core.setup({
    enabled = true,
    mode = 'block_all',
    allow = { 'gitsigns.nvim' },
    detect_plugin = function() return 'lazy.nvim' end,
    env_block = true,
    commands = false,
  })

  local out = vim.fn.system('echo test')

  assert_eq(out, '', 'blocked plugin should receive fallback from vim.fn.system wrapper')
  assert_eq(called, false, 'blocked plugin should not execute original function')
end)

test('allow matching supports short/full plugin name variants', function()
  reset_vim()
  local called = false
  vim.fn.system = function()
    called = true
    return 'ok'
  end

  local core = load_core()

  core.setup({
    enabled = true,
    mode = 'block_all',
    allow = { 'gitsigns.nvim' },
    detect_plugin = function() return 'gitsigns' end,
    env_block = true,
    commands = false,
  })

  local out = vim.fn.system('echo test')
  assert_eq(out, 'ok', 'short detected name should match full allowlist entry')
  assert_eq(called, true, 'allowed plugin should execute original function')
end)

test('allowed plugin via vim.uv.spawn gets unblocked env', function()
  reset_vim()
  local seen_proxy = nil
  vim.uv.spawn = function(_, _, _)
    seen_proxy = vim.env.http_proxy
    return true
  end

  local core = load_core()
  core.setup({
    enabled = true,
    mode = 'block_all',
    allow = { 'lazy.nvim' },
    detect_plugin = function() return 'lazy.nvim' end,
    env_block = true,
    commands = false,
  })

  local ok = vim.uv.spawn('git', {}, function() end)
  assert_eq(ok, true, 'allowed vim.uv.spawn call should pass through')
  assert_eq(seen_proxy, nil, 'allowed vim.uv.spawn should see original proxy env')
  assert_eq(vim.env.http_proxy, '127.0.0.1:1', 'global proxy lock should be restored after vim.uv.spawn')
end)

test('stats=false keeps legacy behavior and disables collection', function()
  reset_vim()
  local core = load_core()
  core.setup({
    stats = false,
    commands = false,
  })

  vim.fn.system('echo test')

  local stats = core.stats()
  assert_eq(stats.total.attempts, 0, 'stats=false should disable stats collection')
  assert_eq(stats.total.blocked, 0, 'stats=false should keep blocked count at zero')
  assert_eq(stats.total.allowed, 0, 'stats=false should keep allowed count at zero')
end)

test('file stats storage persists between setup calls', function()
  reset_vim()
  local stats_path = os.tmpname()
  os.remove(stats_path)

  local core = load_core()
  core.setup({
    commands = false,
    stats = {
      storage = 'file',
      path = stats_path,
    },
  })

  vim.fn.system('echo test')
  assert_eq(core.stats().total.attempts, 1, 'first session should record an attempt')

  reset_vim()
  local core_reloaded = load_core()
  core_reloaded.setup({
    commands = false,
    stats = {
      storage = 'file',
      path = stats_path,
    },
  })

  assert_eq(core_reloaded.stats().total.attempts, 1, 'second session should restore attempts from file')
  os.remove(stats_path)
end)

local passed = 0
for _, t in ipairs(tests) do
  local ok, err = pcall(t.fn)
  if ok then
    passed = passed + 1
    io.write(string.format('ok - %s\n', t.name))
  else
    io.write(string.format('not ok - %s\n%s\n', t.name, err))
  end
end

if passed ~= #tests then
  io.write(string.format('\n%d/%d tests passed\n', passed, #tests))
  os.exit(1)
end

io.write(string.format('\n%d/%d tests passed\n', passed, #tests))
