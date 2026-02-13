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

## Quickstart
```lua
require('nvim_sandman').setup({
  enabled = true,
  mode = 'block_all',
  allow = { 'lazy.nvim' },
  ignore_notifications = { 'nvim-treesitter', 'mason.nvim' },
})
```

Common flows:
- Block everything (default), then allow a trusted plugin:
  `:Sandman allow-only lazy.nvim`
- Temporarily enable network for 30 seconds:
  `:Sandman temp-net 30000`
- See what tried to reach the network:
  `:Sandman stats`

## Commands
- `:Sandman block` — block network for all plugins.
- `:Sandman unblock` — disable blocking.
- `:Sandman block-only <p1> <p2>` — block only listed plugins.
- `:Sandman allow-only <p1> <p2>` — allow network only for listed plugins.
- `:Sandman stats` — show summary stats.
- `:Sandman stats-reset` — reset stats.
- `:Sandman temp-net [ms]` — temporarily enable network for N ms (default 60000).

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
nb.temp_net(30000)
```

## Configuration
```lua
require('nvim_sandman').setup({
  enabled = false,
  mode = 'block_all', -- block_all | blocklist | allowlist
  allow = { 'plenary.nvim' },
  block = { 'nvim-treesitter' },
  ignore_notifications = { 'nvim-treesitter' }, -- suppress blocked notifications for listed plugins
  env_block = true, -- strict block_all: poison HTTP(S)/ALL proxy env vars process-wide
  temp_net_ms = 60000, -- default duration for :Sandman temp-net
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

`ignore_notifications` matching is case-insensitive and accepts both `plugin` and
`plugin.nvim` forms (for example, `gitsigns` or `gitsigns.nvim`).
For ignored plugins, both built-in notifications and `on_block` callback execution
are suppressed.

## Stats
Stats are collected per session in memory only. You can inspect them via
`nb.stats()` or `:Sandman stats`. A summary includes totals plus the top plugins
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

`env_block` note:
- Proxy env vars are process-wide, so they cannot be applied per plugin.
- In strict `block_all`, proxy env vars are poisoned process-wide for hard blocking.
- For plugins listed in `allow`, wrapped calls temporarily restore original proxy env
  values only for that call, then restore the global lock.
- In `blocklist` and `allowlist`, Sandman relies on call interception only.

## FAQ
**Will this block curl/wget/etc started outside Neovim?**  
No. This only intercepts network-related calls made inside the Neovim process.

**A plugin already started a background process. Will blocking stop it?**  
Not necessarily. Restart Neovim or stop that process to fully enforce blocking.

**Can I use it only for a single plugin?**  
Yes. Use `blocklist` and set `block` to that plugin, or `allowlist` and only allow a small set.

**How do I temporarily allow network?**  
Use `:Sandman temp-net [ms]`. It enables network for the given duration (default `60000` ms).

## Tips
- Start with `block_all`, then add trusted plugins to `allow`.
- Use `:Sandman stats` to discover which plugins are attempting network access.

## Limitations
- This is not a system firewall. It only blocks calls inside the Neovim process.
- If a plugin uses an external process/daemon outside Neovim, it may bypass this.
- Stats are stored in memory only and reset when Neovim restarts.
- Blocking after a long-lived background process is already running may not stop it.
  Restart Neovim or stop that process to fully enforce blocking.

## Plugin detection
The plugin name is detected from the call stack file path. Supported directories:
`site/pack/.../start`, `lazy/`, `plugged/`, `bundle/`.

## Contributing
Issues and PRs are welcome. Please keep changes focused and include a short description
of the behavior you expect. If your change affects behavior, add or update a test
if applicable.

## Testing
- Run `npm test` (uses `luajit tests/run.lua .`).
- Current suite focuses on `env_block` behavior across modes, including
  strict `block_all + allow` to ensure allowed plugins can pass while global
  proxy lock remains active.

## License
Apache License 2.0
