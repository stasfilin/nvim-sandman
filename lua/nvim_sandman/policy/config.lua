local M = {}

local VALID_DECISIONS = {
  allow = true,
  deny = true,
  prompt_once = true,
}

local VALID_MODES = {
  monitor = true,
  enforce = true,
}

local function deepcopy(value)
  if type(value) ~= 'table' then
    return value
  end

  local copy = {}
  for k, v in pairs(value) do
    copy[k] = deepcopy(v)
  end

  return copy
end

local function default_audit_path()
  local ok, path = pcall(vim.fn.stdpath, 'state')
  if ok and type(path) == 'string' and path ~= '' then
    return path .. '/nvim-sandman-policy-audit.jsonl'
  end

  return '/tmp/nvim-sandman-policy-audit.jsonl'
end

M.defaults = {
  enabled = false,
  mode = 'enforce',
  default = 'prompt_once',
  audit = {
    enabled = true,
    path = default_audit_path,
  },
  rules = {},
}

local function resolve_functions(tbl)
  for k, v in pairs(tbl) do
    if type(v) == 'function' then
      tbl[k] = v()
    elseif type(v) == 'table' then
      resolve_functions(v)
    end
  end
end

local function merge(dst, src)
  for k, v in pairs(src or {}) do
    if type(v) == 'table' and type(dst[k]) == 'table' then
      merge(dst[k], v)
    else
      dst[k] = deepcopy(v)
    end
  end
end

local function validate_rule(rule, idx)
  if type(rule) ~= 'table' then
    error(('nvim-sandman: policy rule #%d must be a table'):format(idx))
  end

  if not rule.action or type(rule.action) ~= 'string' then
    error(('nvim-sandman: policy rule #%d must contain string action'):format(idx))
  end

  if not VALID_DECISIONS[rule.decision] then
    error(('nvim-sandman: policy rule #%d has invalid decision'):format(idx))
  end

  if rule.args_any and type(rule.args_any) ~= 'table' then
    error(('nvim-sandman: policy rule #%d args_any must be a list'):format(idx))
  end
end

function M.normalize(user)
  local cfg = deepcopy(M.defaults)
  resolve_functions(cfg)
  merge(cfg, user or {})

  if not VALID_MODES[cfg.mode] then
    error('nvim-sandman: policy.mode must be monitor|enforce')
  end

  if not VALID_DECISIONS[cfg.default] then
    error('nvim-sandman: policy.default must be allow|deny|prompt_once')
  end

  if type(cfg.rules) ~= 'table' then
    error('nvim-sandman: policy.rules must be a list')
  end

  for idx, rule in ipairs(cfg.rules) do
    validate_rule(rule, idx)
  end

  if type(cfg.audit) ~= 'table' then
    error('nvim-sandman: policy.audit must be a table')
  end

  if cfg.audit.enabled and (type(cfg.audit.path) ~= 'string' or cfg.audit.path == '') then
    error('nvim-sandman: policy.audit.path must be non-empty when enabled')
  end

  return cfg
end

return M
