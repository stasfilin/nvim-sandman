# nvim-sandman Docs

`nvim-sandman` is a lightweight Neovim plugin that helps you control plugin network access.
It is useful for offline workflows, security hardening, and reproducible sessions.

## Quick Links

- [GitHub repository](https://github.com/stasfilin/nvim-sandman)
- [README (full reference)](../README.md)
- [Changelog](../CHANGELOG.md)

## Why Use It

- Block network calls inside Neovim process.
- Keep strict defaults and allow only trusted plugins.
- Audit which plugins tried to access network.
- Add optional rule-based policy for `exec`/`socket` actions.

## Installation

### lazy.nvim

```lua
{
  'stasfilin/nvim-sandman',
  config = function()
    require('nvim_sandman').setup({
      enabled = true,
      mode = 'block_all',
    })
  end
}
```

## Quick Start

```lua
require('nvim_sandman').setup({
  enabled = true,
  mode = 'block_all',
  allow = { 'lazy.nvim' },
})
```

Typical flow:
1. Start in `block_all`.
2. Use `:Sandman stats` to see who attempts network access.
3. Add trusted plugins to `allow`.
4. Use `:Sandman temp-net 30000` when you need short temporary access.

## Modes

- `block_all`: block all plugins except `allow`.
- `blocklist`: block only plugins listed in `block`.
- `allowlist`: allow only plugins listed in `allow`.

## Core Commands

- `:Sandman block` - enable global blocking.
- `:Sandman unblock` - disable blocking.
- `:Sandman block-only <p1> <p2>` - block only listed plugins.
- `:Sandman allow-only <p1> <p2>` - allow only listed plugins.
- `:Sandman stats` - show usage summary.
- `:Sandman stats-reset` - reset stats.
- `:Sandman temp-net [ms]` - temporary network window.
- `:Sandman env-clear` - restore/clear proxy env state.

## Policy Engine (Optional)

Policy can run together with core Sandman mode.

- Decision types: `allow`, `deny`, `prompt_once`.
- Enforcement:
  - `monitor`: logs only, does not block by policy.
  - `enforce`: policy `deny` blocks calls.

Rule matching is ordered top-to-bottom; first match wins.

### Example Policy

```lua
require('nvim_sandman').setup({
  enabled = true,
  mode = 'block_all',
  policy = {
    enabled = true,
    mode = 'enforce',
    default = 'prompt_once',
    rules = {
      { id = 'allow-rg', action = 'exec', exe = 'rg', decision = 'allow' },
      { id = 'deny-curl', action = 'exec', exe = 'curl', decision = 'deny' },
      { id = 'prompt-node', action = 'exec', exe = 'node', decision = 'prompt_once' },
    },
  },
})
```

## Example Full Config

```lua
require('nvim_sandman').setup({
  enabled = true,
  mode = 'block_all',
  allow = { 'lazy.nvim' },
  ignore_notifications = { 'nvim-treesitter' },
  env_block = true,
  temp_net_ms = 60000,
  stats = {
    enabled = true,
    storage = 'memory', -- or 'file'
    path = vim.fn.stdpath('state') .. '/nvim-sandman-stats.json',
  },
  policy = {
    enabled = false,
    mode = 'enforce',
    default = 'prompt_once',
    audit = {
      enabled = true,
      path = vim.fn.stdpath('state') .. '/nvim-sandman-policy-audit.jsonl',
    },
    rules = {},
  },
})
```

## Troubleshooting

### `blocked ... from unknown`

Attribution is stack-based and best-effort. For wrappers/timers/manual `:lua` calls, actor may be `unknown`.
Use custom `detect_plugin` if you need more reliable actor mapping.

### Policy does not block

Check:
1. `policy.enabled = true`
2. `policy.mode = 'enforce'`
3. Rule order and `policy.default`

### Too many `prompt_once` dialogs

Prompt cache key includes target. Slight command differences can trigger new prompts.
Use explicit stable `allow` / `deny` rules for frequent commands.

## FAQ

### Does it block tools started outside Neovim?

No. It intercepts calls inside Neovim process only.

### Can it replace a system firewall?

No. It is runtime control inside Neovim, not OS-level isolation.

### Does `prompt_once` persist after restart?

No. Cache is session-only.

## GitHub Pages

This site is built from `site/` via:

- `.github/workflows/pages.yml`
