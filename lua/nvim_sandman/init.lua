local core = require('nvim_sandman.core')

local M = {}

function M.setup(opts)
  core.setup(opts or {})
end

function M.block()
  core.block_all()
end

function M.unblock()
  core.unblock()
end

function M.block_only(plugins)
  core.block_only(plugins or {})
end

function M.allow_only(plugins)
  core.allow_only(plugins or {})
end

function M.stats()
  return core.stats()
end

function M.stats_reset()
  core.stats_reset()
end

function M.stats_summary()
  return core.stats_summary()
end

function M.temp_net(ms)
  core.temp_net(ms)
end

function M.env_clear()
  core.env_clear()
end

return M
