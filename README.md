# wezai

**wezai** is a WezTerm plugin that puts an AI assistant, a command palette, and git/history shortcuts next to your shell — without leaving the terminal.

- Ask questions with file, clipboard, git, and selection context  
- Edit files in one pass (`@@path`) with a diff confirm  
- One palette (`CTRL+SHIFT+P`) for Ask helpers, `@git:…`, and `@history`  
- Shell-aware suggestions, secret redaction, risky-command confirms  

Full walkthroughs and every palette action: **[GUIDE.md](GUIDE.md)**

---

## Install

Clone (or use the GitHub URL after you publish), then load it in `~/.config/wezterm/wezterm.lua`:

```lua
local wezterm = require("wezterm")
local config = wezterm.config_builder()

local wezai = wezterm.plugin.require("/Users/you/path/to/wezai.wezterm")
-- After publish:
-- local wezai = wezterm.plugin.require("https://github.com/wsams/wezai.wezterm")

wezai.apply_to_config(config, {
  type = "http",
  api_url = "https://your-endpoint/v1/chat/completions",
  api_key = "your-key",
  model = "your-model",
  keybinding = { key = "i", mods = "CTRL" },
})

return config
```

WezTerm caches plugin clones under its plugins directory. After local edits, copy/sync into that cache or `require` the local path and reload config.

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
| `CTRL+I` (configurable) | **Ask** — type a question or `@` / `@@` ref |
| `CTRL+SHIFT+P` | **Palette** — type `@git`, `@history`, or `Ask` to filter |
| `CTRL+SHIFT+G` | Palette scoped to `@git` |
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
| `@file` | Attach a file (read-only) |
| `@@file instruction` | Rewrite the file (diff + confirm) |
| `@clipboard` / `@selection` | Clipboard or terminal selection |
| `@git:status` + a question | Attach status and ask |
| `@git:status` alone | Run the **git status** action (no LLM) |
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
  max_file_bytes = 100000,
  backup_suffix = ".wezai.bak",
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
  context.lua    -- @ / @@ parsing + redaction
  edit.lua       -- backups, diffs, apply confirm
  shell.lua      -- dialect, risk gate, clipboard
  util.lua
  settings.lua   -- defaults + user merge
  providers/     -- chat_http, gemini_api, ollama_bin, lms_bin
```

---

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 wsams.
