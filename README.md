# nvim-sandman

Lightweight Neovim plugin to block network access from plugins.

## Features
- Works on macOS and Linux (no root required).
- Blocks network access inside the Neovim process.
- Supports “block all” or “block only some plugins” modes.

## Why this exists
Sometimes you want Neovim to be fully offline (security, focus, reproducibility) or to
allow only a small set of trusted plugins to talk to the network. `nvim-sandman` gives
you a simple, reversible switch without touching system firewalls.

## How it works
The plugin wraps common ways plugins reach the network or spawn network-capable
processes (`vim.system`, `vim.fn.jobstart`, `uv.spawn`, TCP/UDP connect/send).
Calls are allowed or blocked based on the current mode and the plugin detected
from the call stack.

## Typical use cases
- Run Neovim in “offline mode” by default and temporarily allow specific plugins.
- Audit which plugins try to access the network.
- Prevent accidental downloads during demos or tests.

## Installation (lazy.nvim)
```lua
{
  'stasfilin/nvim-sandman',
  config = function()
    require('nvim_sandman').setup({
      enabled = false,
      mode = 'block_all', -- block_all | blocklist | allowlist
    })
  end
}
```

## Commands
- `:NetworkBlock` — block network for all plugins.
- `:NetworkUnblock` — disable blocking.
- `:NetworkBlockOnly <p1> <p2>` — block only listed plugins.
- `:NetworkAllowOnly <p1> <p2>` — allow network only for listed plugins.
- `:NetworkStats` — show summary stats.
- `:NetworkStatsReset` — reset stats.

## Lua API
```lua
local nb = require('nvim_sandman')
nb.block()
nb.unblock()
nb.block_only({ 'nvim-treesitter', 'lazy.nvim' })
nb.allow_only({ 'plenary.nvim' })
print(vim.inspect(nb.stats()))
nb.stats_reset()
print(nb.stats_summary())
```

## Configuration
```lua
require('nvim_sandman').setup({
  enabled = false,
  mode = 'block_all', -- block_all | blocklist | allowlist
  allow = { 'plenary.nvim' },
  block = { 'nvim-treesitter' },
  commands = true, -- create commands
  on_block = function(info)
    -- info.action, info.plugin, info.message
    vim.notify(info.message, vim.log.levels.WARN)
  end,
  detect_plugin = function()
    -- custom plugin detection (return name or nil)
  end,
})
```

## Stats
Stats are collected per session in memory only. You can inspect them via
`nb.stats()` or `:NetworkStats`. A summary includes totals plus the top plugins
by attempts.

Example output:
```
nvim-sandman stats: attempts=7 blocked=5 allowed=2
plugin lazy.nvim: attempts=3 blocked=3 allowed=0
plugin nvim-treesitter: attempts=2 blocked=2 allowed=0
```

## Modes in practice
- `block_all`: everything is blocked, except plugins in `allow`.
- `blocklist`: only plugins in `block` are blocked.
- `allowlist`: everything is blocked, except plugins in `allow`.

## Tips
- Start with `block_all`, then add trusted plugins to `allow`.
- Use `:NetworkStats` to discover which plugins are attempting network access.

## Limitations
- This is not a system firewall. It only blocks calls inside the Neovim process.
- If a plugin uses an external process/daemon outside Neovim, it may bypass this.
- Stats are stored in memory only and reset when Neovim restarts.

## Plugin detection
The plugin name is detected from the call stack file path. Supported directories:
`site/pack/.../start`, `lazy/`, `plugged/`, `bundle/`.

## License
MIT
