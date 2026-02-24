# dafny-nvim

A Neovim plugin for [Dafny](https://dafny.org/) verification, built on the native LSP client. All output renders inline using extmarks and virtual text — no floating windows.


https://github.com/user-attachments/assets/58cfe2c7-a2ce-4f63-b1e1-ce43b402c14c




## Features

**Per-method verification status** — EOL icons update live as dafny verifies:
```
method VerifyPayment(...)  returns (ok: bool)   ✔
method LuhnCheck(n: int)   returns (ok: bool)   ✘
method ChargeAmount(...)   returns (charged: bool)  ◌
```

| Icon | Meaning |
|------|---------|
| `✔`  | Verified correct |
| `✘`  | Verification error |
| `◌`  | Queued or running |
| `?`  | Stale (not yet verified) |

**Counter examples on failing contracts** — when a method fails, witness values appear as virtual lines under each `requires`/`ensures` clause:
```
method LuhnCheck(n: int) returns (ok: bool)  ✘
  requires n >= 0
  │ ✗ n := 0, ok := false
  ensures ok == (n % 10 != 0)
  │ ✗ n := 0, ok := false
```

**Call tree** — toggle an inline call tree showing verification status of all reachable callees:
```
method VerifyPayment(...)  ✔
│ ├─ [✔] ValidateCard
│ │  ├─ [✔] IsExpired
│ │  └─ [✘] LuhnCheck
│ ├─ [✔] ChargeAmount
│ └─ [✔] LogTransaction
```

## Requirements

- Neovim 0.11+
- [Dafny 4.x](https://github.com/dafny-lang/dafny/releases) with `dafny` in PATH
- [Z3](https://github.com/Z3Prover/z3) (the Dafny LSP will error without it)
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) with `dafny` server configured

## Installation

### lazy.nvim

```lua
{
  "CameronBadman/dafny-nvim-",
  ft     = "dafny",
  config = function()
    require("dafny").setup()
  end,
}
```

### LSP server config

Create `lua/plugins/lsp/servers/dafny.lua` (or equivalent for your config):

```lua
local dafny_bin = vim.fn.exepath("dafny")
local z3_bin    = vim.fn.exepath("z3")

local cmd = dafny_bin ~= "" and { dafny_bin, "server" } or { "dafny", "server" }
if z3_bin ~= "" then
  vim.list_extend(cmd, { "--solver-path", z3_bin })
end

return {
  cmd          = cmd,
  filetypes    = { "dafny" },
  root_markers = { "dfyconfig.toml", ".git" },
}
```

## Configuration

```lua
require("dafny").setup({
  counter_example_depth = 5,    -- depth passed to dafny/counterExample request
  counter_debounce_ms   = 1000, -- ms to wait after last symbolStatus before fetching counter examples
})
```

## Keymaps

Set automatically on `LspAttach` for dafny buffers:

| Key | Command | Action |
|-----|---------|--------|
| `<leader>ds` | `:DafnyStatus` | Notify with `✔ N  ✘ N  ◌ N` counts |
| `<leader>dt` | `:DafnyCallTree` | Toggle inline call tree at cursor |
| `<leader>dv` | `:DafnyVerifyTree` | Trigger verification for cursor method and all callees |

## Notes

- Counter examples are fetched automatically 1 second after verification settles on an error. They clear automatically when the method goes green.
- The call tree uses `textDocument/documentSymbol` and pattern-matches call sites in the source text — it won't follow calls through opaque abstractions.
- Dafny 4.x uses status codes `Correct=5`, `Error=4` (3 is unused). Older protocol docs showing `Correct=3` are wrong for 4.x.
