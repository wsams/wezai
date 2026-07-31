# wezai

**wezai** is a WezTerm plugin that puts an AI assistant, a command palette, and git/history shortcuts next to your shell — without leaving the terminal.

- Ask questions with file, clipboard, git, and selection context  
- Edit files in one pass (`@@path`) with a diff confirm  
- One palette (`CTRL+SHIFT+P`) for Ask helpers, `@git:…`, and `@history`  
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

WezTerm clones plugins into its cache on first `require`. After you pull new commits (or edit a local checkout), run `wezterm.plugin.update_all()` once — from the debug overlay, or temporarily from your config — then reload WezTerm so the cache picks up the changes.

### Providers

| `type` | What you need |
|--------|----------------|
| `"http"` | OpenAI-compatible `api_url` + `model` (+ `api_key` if required) |
| `"local"` | LM Studio CLI (`lms_path`) |
| `"ollama"` | `ollama_path` + `model` |
| `"google"` | Gemini `api_key` + `model` (uses curl + WezTerm JSON) |

---

## Quick start

| Key | Action |
|-----|--------|
| `CTRL+I` | **Ask** — type a question or `@` / `@@` ref |
| `CTRL+SHIFT+E` | **Ask** with pane scrollback attached as context |
| `CTRL+SHIFT+P` | **Palette** — type `@git`, `@history`, or `Ask` to filter |
| `CTRL+SHIFT+G` | Palette scoped to `@git` |
| `CTRL+SHIFT+K` | Palette scoped to `@kube` |
| `CTRL+SHIFT+H` | Palette scoped to `@history` |

Stay on your **shell** pane. The right split is **output only** (answers, diffs, git status). Don’t run git from that pane — wezai always uses your shell’s cwd.

```
CTRL+SHIFT+P  →  type @git:status  →  Enter
CTRL+SHIFT+P  →  type @git:log     →  Enter
CTRL+I        →  @README.md is this safe?  →  Enter
CTRL+I        →  @@notes.txt sort the lines  →  review diff → Apply
```

More examples: [GUIDE.md](GUIDE.md).

---

## What you can attach

| In the Ask prompt | Meaning |
|-------------------|---------|
| `@file` | Attach a file (read-only). Trailing `?!.` etc. are ignored (`@package.json?` works) |
| `@` / `@pick` | Fuzzy file picker (type to filter), then ask |
| `@@file instruction` | Create or rewrite the file (diff + confirm). New files OK if the parent dir exists |
| `@@` / `@@pick` | Fuzzy pick a file to edit, then type the instruction |
| `@clipboard` / `@selection` | Clipboard or terminal selection |
| `@git:status` + a question | Attach status and ask |
| `@git:status` alone | Run the **git status** action (no LLM) |
| `@kube` / `@kube:pods` | Kubernetes helpers against your **current** kubectl context (no `--kubeconfig` in catalog) |
| `@kube:pods` in a question | Attach `kubectl get pods` for the current ns |
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

  -- Optional: default ns + absolute kubectl if GUI PATH can't find it
  kube = { namespace = nil, kubectl = nil, confirm_mutate = true },

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
  chat_max_turns = 6,
  require_edit_confirm = true,
  require_risk_confirm = true,
  -- Soft attach budget. Larger @files are sent as head+tail (not rejected).
  -- @@edit still needs the full file under this limit (or split the file).
  max_file_bytes = 200000,
  files = {
    large_file = "head_tail", -- or "head" / "error"
    -- head_bytes = 120000,
    -- tail_bytes = 80000,
  },
  backup_suffix = ".wezai.bak",

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
  session.lua    -- chat memory + history events
  history.lua    -- shell/scrollback history
  git.lua        -- @git action catalog
  kube.lua       -- @kube kubectl catalog
  context.lua    -- @ / @@ parsing + redaction
  edit.lua       -- backups, diffs, apply confirm
  shell.lua      -- dialect, risk gate, clipboard
  util.lua
  settings.lua   -- defaults + user merge
  stats.lua      -- token/model usage DB
  files.lua      -- fuzzy @pick / @@pick via InputSelector
  providers/     -- chat_http, gemini_api, ollama_bin, lms_bin
```

---

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 wsams.
