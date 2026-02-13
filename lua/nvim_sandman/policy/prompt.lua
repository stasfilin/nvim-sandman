local M = {
  cache = {},
}

local function key_for(req)
  return table.concat({
    req.actor or 'unknown',
    req.action or 'unknown',
    req.target or '',
  }, '|')
end

function M.resolve(req)
  local key = key_for(req)
  local cached = M.cache[key]
  if cached then
    return cached, true
  end

  local lines = {
    'nvim-sandman policy prompt_once',
    'actor: ' .. (req.actor or 'unknown'),
    'action: ' .. (req.action or 'unknown'),
    'target: ' .. (req.target or ''),
    '',
    'Allow for this session?',
  }

  local choice = 2
  local ok, result = pcall(vim.fn.confirm, table.concat(lines, '\n'), '&Allow\n&Deny', 2)
  if ok and result == 1 then
    choice = 1
  end

  local decision = choice == 1 and 'allow' or 'deny'
  M.cache[key] = decision
  return decision, false
end

function M.clear()
  M.cache = {}
end

return M
