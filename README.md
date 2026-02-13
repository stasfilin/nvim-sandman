# nvim-sandman

Lightweight Neovim plugin to block network access from plugins.

## Features
- Works on macOS and Linux (no root required).
- Blocks network access inside the Neovim process.
- Supports `block_all`, `blocklist`, and `allowlist` modes.
- Optional built-in declarative policy engine (`allow` / `deny` / `prompt_once`).

## Why this exists
Sometimes you want Neovim to be fully offline (security, focus, reproducibility) or to
allow only a small set of trusted plugins to talk to the network. `nvim-sandman` gives
you a simple, reversible switch without touching system firewalls.

## How it works
The plugin wraps common ways plugins reach network-capable paths or spawn processes
(`vim.system`, `vim.fn.jobstart`, `uv.spawn`, TCP/UDP connect/send, etc.). Calls are
allowed or blocked based on current mode and the plugin detected from call stack.

Policy support is integrated into the same wrapper layer, so you do not need to run a
second plugin that patches the same APIs.

## Typical use cases
- Run Neovim in offline mode by default and temporarily allow specific plugins.
- Audit which plugins try to access the network.
- Prevent accidental downloads during demos or tests.
- Add rule-based controls for command execution (`curl`, `git`, `rg`, ...).

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

## Integrated Policy (Optional)
Enable this if you want declarative per-action rules in addition to Sandman core modes.

```lua
require('nvim_sandman').setup({
  enabled = true,
  mode = 'block_all',
  allow = { 'lazy.nvim' },

  policy = {
    enabled = true,
    mode = 'enforce', -- monitor | enforce
    default = 'prompt_once', -- allow | deny | prompt_once
    audit = {
      enabled = true,
      path = vim.fn.stdpath('state') .. '/nvim-sandman-policy-audit.jsonl',
    },
    rules = {
      { id = 'allow-rg', action = 'exec', exe = 'rg', decision = 'allow' },
      { id = 'deny-curl', action = 'exec', exe = 'curl', decision = 'deny' },
      { id = 'prompt-node', action = 'exec', exe = 'node', decision = 'prompt_once' },
    },
  },
})
```

Policy notes:
- Decision modes: `allow`, `deny`, `prompt_once`
- Enforcement modes: `monitor` (log only), `enforce` (deny blocks)
- Rule matching (MVP): `action`, `actor`, `exe`, `args_any`, `target_pattern`
- Action classes (current): `exec`, `socket` (best-effort)

## Policy Deep Dive

### Evaluation order
- A call is checked by Sandman mode (`block_all` / `blocklist` / `allowlist`).
- If policy is enabled, the same call is also checked by policy rules.
- If either system blocks, the final result is blocked.

### Rule matching behavior
- Rules are evaluated top-to-bottom.
- First matching rule wins.
- If nothing matches, `policy.default` is used.

### Fields for `exec` rules
- `id`: optional identifier for audit readability.
- `action`: currently `exec` or `socket`.
- `decision`: `allow`, `deny`, `prompt_once`.
- `actor`: plugin name/pattern (best-effort attribution).
- `exe`: executable basename (`curl`, `git`, `rg`, ...).
- `args_any`: match if any listed argument is present.
- `target_pattern`: pattern/regex-like check against normalized target.

### prompt_once semantics
- On first match, user is prompted with Allow/Deny.
- Decision is cached for current Neovim session by `(actor, action, target)`.
- Restarting Neovim clears this cache.

### monitor vs enforce
- `monitor`: no blocking from policy, but logs decision and matched rule.
- `enforce`: policy `deny` blocks the call.
- Sandman core mode still applies in both cases.

### Audit fields
Policy audit is JSONL, one event per line. Common fields:
- `ts`, `action`, `target`, `cwd`
- `actor`, `actor_confidence`
- `decision`, `rule_id`, `mode`, `result`

## Policy Recipes

Allow common dev tooling, deny risky fetch tools:
```lua
policy = {
  enabled = true,
  mode = 'enforce',
  default = 'deny',
  rules = {
    { id = 'allow-git', action = 'exec', exe = 'git', decision = 'allow' },
    { id = 'allow-rg', action = 'exec', exe = 'rg', decision = 'allow' },
    { id = 'deny-curl', action = 'exec', exe = 'curl', decision = 'deny' },
    { id = 'deny-wget', action = 'exec', exe = 'wget', decision = 'deny' },
  },
}
```

Prompt before running script runtimes:
```lua
policy = {
  enabled = true,
  mode = 'enforce',
  default = 'allow',
  rules = {
    { id = 'prompt-node', action = 'exec', exe = 'node', decision = 'prompt_once' },
    { id = 'prompt-python', action = 'exec', exe = 'python', decision = 'prompt_once' },
  },
}
```

Silent rollout first, then enforce:
```lua
policy = {
  enabled = true,
  mode = 'monitor',
  default = 'allow',
  rules = {
    { id = 'deny-curl', action = 'exec', exe = 'curl', decision = 'deny' },
  },
}
-- switch mode to 'enforce' after audit review
```

## Commands
- `:Sandman block` - block network for all plugins.
- `:Sandman unblock` - disable blocking.
- `:Sandman block-only <p1> <p2>` - block only listed plugins.
- `:Sandman allow-only <p1> <p2>` - allow network only for listed plugins.
- `:Sandman stats` - show summary stats.
- `:Sandman stats-reset` - reset stats.
- `:Sandman env-clear` - restore/clear proxy env values.
- `:Sandman temp-net [ms]` - temporarily enable network for N ms (default 60000).
- `:Sandman policy-status` - show policy status/mode.
- `:Sandman policy-audit [N]` - show last N policy audit lines.

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

print(vim.inspect(nb.policy_status()))
print(table.concat(nb.policy_audit_tail(20), '\n'))
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

  policy = {
    enabled = false,
    mode = 'enforce', -- monitor | enforce
    default = 'prompt_once', -- allow | deny | prompt_once
    audit = {
      enabled = true,
      path = vim.fn.stdpath('state') .. '/nvim-sandman-policy-audit.jsonl',
    },
    rules = {
      -- ordered top-to-bottom, first match wins
      -- { id = 'deny-curl', action = 'exec', exe = 'curl', decision = 'deny' },
    },
  },
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

env_block note:
- Proxy env vars are process-wide, so they cannot be applied per plugin.
- In strict `block_all`, proxy env vars are poisoned process-wide for hard blocking.
- For plugins listed in `allow`, wrapped calls temporarily restore original proxy env
  values only for that call, then restore the global lock.
- In `blocklist` and `allowlist`, Sandman relies on call interception only.

## Troubleshooting

`nvim-sandman: blocked ... from unknown`:
- This means actor attribution could not map stack frames to a known plugin path.
- Common reasons: manual `:lua` calls, timer/callback boundaries, C frames, generic wrappers.
- You can provide custom `detect_plugin` to improve attribution.

Manual command testing is blocked in `block_all`:
- `:lua print(vim.fn.system('curl ...'))` is usually actor `unknown` and will be blocked.
- Use `:Sandman temp-net 10000` for temporary allowance.

Policy appears not to block:
- Verify `policy.enabled = true`.
- Verify `policy.mode = 'enforce'` (not `monitor`).
- Check rule ordering and `policy.default` fallback.
- Inspect audit with `:Sandman policy-audit 50`.

Too many prompts with `prompt_once`:
- Cache key includes `target`, so command variations can create new prompts.
- Use more explicit `allow/deny` rules for stable high-volume commands.

## FAQ

### Will this block `curl` / `wget` / etc started outside Neovim?
No. It only intercepts calls made inside the Neovim process.

### A plugin already started a background process. Will blocking stop it?
Usually no. Restart Neovim or stop that process for full effect.

### Can I use it only for a single plugin?
Yes.
- Use `blocklist` with one plugin in `block`.
- Or use `allowlist` with one plugin in `allow`.

### How do I temporarily allow network?
Use `:Sandman temp-net [ms]`.

### Should I use this together with another wrapper plugin?
No. Prefer one wrapper layer to avoid monkey-patch stacking conflicts.

### What does policy `monitor` mode do?
It never blocks by policy, but logs what policy would decide.

### What does policy `enforce` mode do?
Policy `deny` blocks the call. Sandman core mode still applies.

### Does `prompt_once` persist across restarts?
No. Cache is session-only.

### How do I roll out policy safely?
Start with `policy.mode = "monitor"`, inspect audit logs, then switch to `enforce`.

### Why do I see actor `unknown`?
Attribution is best-effort and stack-based; some call paths are not attributable.

### Can I allow manual `:lua` testing while still blocking plugins?
Yes. Use custom `detect_plugin` and map manual calls to a synthetic actor (for example `manual`), then add it to `allow`.

### Can this replace a system firewall?
No. It improves runtime control inside Neovim, not OS-level isolation.

## Tips
- Start with `block_all`, then add trusted plugins to `allow`.
- Use `:Sandman stats` to discover which plugins are attempting network access.
- If you need policy rules, enable integrated `policy` instead of stacking another wrapper plugin.
- For policy rollout, use `monitor` first, then `enforce`.

## Limitations
- This is not a system firewall. It only blocks calls inside the Neovim process.
- If a plugin uses an external process/daemon outside Neovim, it may bypass this.
- Stats are stored in memory only and reset when Neovim restarts.
- Blocking after a long-lived background process is already running may not stop it.
  Restart Neovim or stop that process to fully enforce blocking.
- Actor attribution and socket classification are heuristic.

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
