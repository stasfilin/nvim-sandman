local M = {}

local MAGIC_PATTERN = '[%^%$%(%)%%%.%[%]%*%+%-%?]'

local function basename(path)
  if type(path) ~= 'string' then
    return ''
  end

  local normalized = path:gsub('\\', '/')
  return normalized:match('([^/]+)$') or normalized
end

local function match_value(expected, actual)
  if expected == nil then
    return true
  end

  if type(expected) ~= 'string' then
    return false
  end

  actual = tostring(actual or '')

  if expected:sub(1, 1) == '/' and expected:sub(-1, -1) == '/' and #expected > 2 then
    local pattern = expected:sub(2, -2)
    if vim.regex then
      local ok, re = pcall(vim.regex, pattern)
      if ok and re then
        return re:match_str(actual) ~= nil
      end
    end
  end

  if expected:find(MAGIC_PATTERN) then
    return actual:find(expected) ~= nil
  end

  return actual == expected
end

local function match_args_any(expected_args, actual_args)
  if not expected_args then
    return true
  end

  if type(expected_args) ~= 'table' or type(actual_args) ~= 'table' then
    return false
  end

  local set = {}
  for _, arg in ipairs(actual_args) do
    set[tostring(arg)] = true
  end

  for _, expected in ipairs(expected_args) do
    if set[tostring(expected)] then
      return true
    end
  end

  return false
end

local function match_rule(rule, req)
  if rule.action and rule.action ~= req.action then
    return false
  end

  if rule.actor and not match_value(rule.actor, req.actor) then
    return false
  end

  if rule.exe and basename(rule.exe) ~= basename(req.exe) then
    return false
  end

  if not match_args_any(rule.args_any, req.args) then
    return false
  end

  if rule.target_pattern and not match_value(rule.target_pattern, req.target) then
    return false
  end

  return true
end

function M.evaluate(req, cfg)
  for idx, rule in ipairs(cfg.rules or {}) do
    if match_rule(rule, req) then
      return {
        decision = rule.decision,
        rule_id = rule.id or ('policy-rule-' .. idx),
      }
    end
  end

  return {
    decision = cfg.default,
    rule_id = 'policy-default',
  }
end

return M
