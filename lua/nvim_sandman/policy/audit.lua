local M = {
  enabled = false,
  path = nil,
}

local function ensure_parent(path)
  local dir = vim.fs.dirname(path)
  if dir and dir ~= '' then
    pcall(vim.fn.mkdir, dir, 'p')
  end
end

function M.setup(cfg)
  M.enabled = cfg and cfg.enabled == true
  M.path = cfg and cfg.path or nil

  if M.enabled and M.path then
    ensure_parent(M.path)
  end
end

function M.append(event)
  if not M.enabled or not M.path then
    return false
  end

  local ok, line = pcall(vim.json.encode, event)
  if not ok then
    return false
  end

  local fd = vim.uv.fs_open(M.path, 'a', 420)
  if not fd then
    return false
  end

  vim.uv.fs_write(fd, line .. '\n', -1)
  vim.uv.fs_close(fd)
  return true
end

function M.tail(n)
  if not M.path then
    return {}
  end

  local limit = tonumber(n) or 20
  limit = math.max(1, limit)

  local file = io.open(M.path, 'r')
  if not file then
    return {}
  end

  local lines = {}
  for line in file:lines() do
    lines[#lines + 1] = line
  end
  file:close()

  local start = math.max(1, #lines - limit + 1)
  local out = {}
  for idx = start, #lines do
    out[#out + 1] = lines[idx]
  end

  return out
end

return M
