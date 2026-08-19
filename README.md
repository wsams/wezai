# wezai

**wezai** is a WezTerm plugin that puts an AI assistant, a command palette, and git/kube/terraform/history shortcuts next to your shell — without leaving the terminal.

> **Alpha software.** wezai is in active development and under heavy testing. Behavior and APIs may change. If you hit a bug or have an idea, please [open an issue](https://github.com/wsams/wezai/issues) — reports are welcome and help shape the project. See [CONTRIBUTING.md](CONTRIBUTING.md) for what to include.

- Ask questions with file, directory, clipboard, git, kube, terraform, and selection context  
- Edit files in one pass (`#path`, legacy `@@path`) with a unified diff confirm and wezai dotfile backups  
- CTRL+I composer keeps the AI log visible; `@` / `#` fuzzy-complete paths; context persists until Compact/Clear  
- One palette (`CTRL+SHIFT+P`) for Ask helpers, `@git:…`, `@kube:…`, `@tf:…`, and `@history`  
- Shell-aware suggestions, secret redaction, risky-command confirms  

Full walkthroughs and every palette action: **[GUIDE.md](GUIDE.md)**

---

## Install

Load it from GitHub in `~/.config/wezterm/wezterm.lua`:

```lua
local wezterm = require("wezterm")
local config = wezterm.config_builder()

local wezai = wezterm.plugin.require("https://github.com/wsams/wezai")
-- Local checkout (development):
-- local wezai = wezterm.plugin.require("/Users/you/path/to/wezai")

wezai.apply_to_config(config, {
  type = "http",
  api_url = "https://your-endpoint/v1/chat/completions",
  api_key = "your-key",
  model = "your-model",

  -- Ask prompt
  keybinding = {
    key = "i",
    mods = "CTRL", -- CTRL+I (use "SUPER" for Cmd+I on macOS if you prefer)
  },

  -- Ask with shared pane scrollback as context
  keybinding_with_pane = {
    key = "e",
    mods = "CTRL|SHIFT",
  },

  -- Optional style notes. Shell dialect (fish/zsh/bash/PowerShell) is detected from the
  -- active pane (or $SHELL) and appended automatically — no need to hardcode Fish/zsh/etc.
  system_prompt = "You are a concise terminal assistant. Provide direct commands or brief explanations. "
    .. "Warn of dangerous commands. Avoid unnecessary verbosity. Prefer interactive commands that require "
    .. "user verification before proceeding when possible.",
})

return config
```

WezTerm clones plugins into its cache on first `require`. After you pull new commits (or edit a local checkout), run `wezterm.plugin.update_all()` once — from the debug overlay, or temporarily from your config — then reload WezTerm so the cache picks up the changes. Palette titles and the AI pane banner show the installed version (e.g. `wezai v1.7.0+fc6d5b5`) so you can confirm the update landed.

### Providers

| `type` | What you need |
|--------|----------------|
| `"http"` | OpenAI-compatible `api_url` + `model` (+ `api_key` if required). For Ollama: `http://127.0.0.1:11434/v1/chat/completions`, raise `timeout` (e.g. 300–600) for large cold loads, and prefer instruct models over “thinking” GGUFs (Ask/`#` edits need JSON — see SPECS §4.4). |
| `"local"` | LM Studio CLI (`lms_path`) |
| `"ollama"` | `ollama_path` + `model` |
| `"google"` | Gemini `api_key` + `model` (uses curl + WezTerm JSON) |
---

## Quick start

| Key | Action |
|-----|--------|
| `CTRL+I` | **Ask** — composer under the shell (`@` attach, `#` edit). Esc saves a draft |
| `CTRL+SHIFT+E` | **Ask** with pane scrollback attached as context |
| `CTRL+SHIFT+P` | **Palette** — type `@git`, `@kube`, `@tf`, `@history`, or `Ask` to filter |
| `CTRL+SHIFT+G` | Palette scoped to `@git` |
| `CTRL+SHIFT+K` | Palette scoped to `@kube` |
| `CTRL+ALT+T` | Palette scoped to `@tf` (not `CTRL+SHIFT+T` — that is WezTerm’s new tab) |
| `CTRL+SHIFT+H` | Palette scoped to `@history` |

Stay on your **shell** pane. The right split is **output only** (answers, diffs, git/kube/tf status). Don’t run git from that pane — wezai always uses your shell’s cwd.

```
CTRL+SHIFT+P  →  type @git:status  →  Enter
CTRL+SHIFT+P  →  type @tf:validate →  Enter
CTRL+I        →  @README.md is this safe?  →  Enter
CTRL+I        →  #notes.txt sort the lines  →  review diff → Apply
CTRL+I        →  @plugin/   (pins the tree) →  how is loading wired?
```

More examples: [GUIDE.md](GUIDE.md).

---

## What you can attach

| In the Ask prompt | Meaning |
|-------------------|---------|
| `@file` | Attach a file (read-only, **pinned** until Clear). Trailing `?!.` etc. are ignored (`@package.json?` works) |
| `@dir/` | Walk the directory and attach files (token budget + confirm if large) |
| `@` / `@pick` | Fuzzy file picker (type to filter), then ask |
| `#file instruction` | Create or rewrite the file (diff + confirm). New files OK if the parent dir exists |
| `#dir/` | Pin files in that directory as edit targets |
| `#` / `#pick` | Fuzzy pick a file to edit, then type the instruction |
| `@@file` | Legacy alias of `#file` |
| `@clipboard` / `@selection` | Clipboard or terminal selection |
| `@git:status` + a question | Attach status and ask |
| `@git:status` alone | Run the **git status** action (no LLM) |
| `@kube` / `@kube:pods` | Kubernetes helpers against your **current** kubectl context (no `--kubeconfig` in catalog) |
| `@kube:pods` in a question | Attach `kubectl get pods` for the current ns |
| `@tf` / `@tf:validate` | Terraform helpers in the shell cwd (`terraform` binary auto-resolved) |
| `@tf:state` in a question | Attach `terraform state list` and ask |
| `@tf:generate …` / `@tf:debug` | AI helpers to generate or debug HCL |
| `@dir:path` | Directory listing |
| `@history …` | Attach recent history, or open the palette if used alone |

---

## Config sketch

```lua
wezai.apply_to_config(config, {
  type = "http",
  api_url = "https://api.openai.com/v1/chat/completions",
  api_key = os.getenv("OPENAI_API_KEY"),
  model = "gpt-4o-mini",
  models = { "gpt-4o-mini", "gpt-4o" },

  keybinding = { key = "i", mods = "CTRL" },
  keybinding_with_pane = { key = "e", mods = "CTRL|SHIFT" },
  keybinding_palette = { key = "p", mods = "CTRL|SHIFT" },
  keybinding_history = { key = "h", mods = "CTRL|SHIFT" },
  keybinding_git = { key = "g", mods = "CTRL|SHIFT" },
  keybinding_kube = { key = "k", mods = "CTRL|SHIFT" },
  keybinding_tf = { key = "t", mods = "CTRL|ALT" },

  -- Optional: default ns + absolute kubectl if GUI PATH can't find it
  kube = { namespace = nil, kubectl = nil, confirm_mutate = true },

  -- Optional: absolute terraform if GUI PATH can't find it
  tf = { terraform = nil, confirm_mutate = true },

  -- Dialect (fish/zsh/bash/…) is auto-appended from the active shell pane / $SHELL.
  system_prompt = "You are a concise terminal assistant. Provide direct commands or brief explanations. "
    .. "Warn of dangerous commands. Avoid unnecessary verbosity. Prefer interactive commands that require "
    .. "user verification before proceeding when possible.",

  ai_pane = { enabled = true, direction = "Right", size_percent = 35, pad_cols = 2 },
  history = {
    max_shell = 500,
    palette_n = 200,
    tail_bytes = 4 * 1024 * 1024,
    include_scrollback = true,
  },
  git = { default_branch = nil, max_attach_bytes = 80000 },
  chat_max_turns = 40,
  require_edit_confirm = true,
  require_risk_confirm = true,
  -- Soft attach budget. Larger @files are sent as head+tail (not rejected).
  -- #edit still needs the full file under this limit (or split the file).
  max_file_bytes = 200000,
  files = {
    large_file = "head_tail", -- or "head" / "error"
    -- head_bytes = 120000,
    -- tail_bytes = 80000,
  },
  context = {
    max_prompt_tokens = 24000,
    confirm_tokens = 12000,
    max_dir_files = 80,
  },
  -- # edit backups: sibling dotfile `.name.<timestamp>.wezai.bak`
  backup = { enabled = true, suffix = ".wezai.bak", dotfile = true, dir = nil },

  -- Token/model usage (shown when the AI pane opens; persisted under ~/.local/share/wezai/stats.json)
  stats = { enabled = true },
})
```

---

## Layout

```
plugin/
  init.lua       -- entry, keybindings, ask/edit orchestration
  palette.lua    -- CTRL+SHIFT+P unified palette
  ui.lua         -- output pane, styling, InputSelector
  session.lua    -- chat memory + pinned @/# files + drafts
  history.lua    -- shell/scrollback history
  git.lua        -- @git action catalog
  kube.lua       -- @kube kubectl catalog
  tf.lua         -- @tf terraform catalog
  context.lua    -- @ / # parsing + dir walk + token budget
  edit.lua       -- wezai dotfile backups, diffs, apply confirm
  composer.lua / composer.py  -- CTRL+I ask pane (AI log stays visible)
  files.lua      -- fuzzy @pick / #pick
  shell.lua      -- dialect, risk gate, clipboard
  util.lua
  settings.lua   -- defaults + user merge
  stats.lua      -- token/model usage DB
  providers/     -- chat_http, gemini_api, ollama_bin, lms_bin
```

---

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 wsams.
