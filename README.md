# wezai

**wezai** is a WezTerm plugin that puts an AI assistant, a command palette, and git/kube/terraform/weather/history shortcuts next to your shell — without leaving the terminal.

> **Alpha software.** wezai is in active development and under heavy testing. Behavior and APIs may change. If you hit a bug or have an idea, please [open an issue](https://github.com/wsams/wezai/issues) — reports are welcome and help shape the project. See [CONTRIBUTING.md](CONTRIBUTING.md) for what to include.

- Ask questions with file, directory, clipboard, git, kube, terraform, weather, and selection context  
- Edit files in one pass (`#path`, legacy `@@path`) with a unified diff confirm and wezai dotfile backups  
- CTRL+I composer keeps the AI log visible; `@` / `#` fuzzy-complete paths; context persists until Compact/Clear  
- One palette (`CTRL+SHIFT+P`) for Ask helpers, `@git:…`, `@kube:…`, `@tf:…`, `@weather:…`, and `@history`  

- Shell-aware suggestions, secret redaction, risky-command confirms  

Full walkthroughs and every palette action: **[GUIDE.md](GUIDE.md)**

---

## Install

Load it from GitHub in `~/.config/wezterm/wezterm.lua`. Customizations belong in **`~/.config/wezterm/wezai.env`** (or `$XDG_CONFIG_HOME/wezterm/wezai.env`) so you can copy this Lua as-is when wezai’s example changes:

```lua
local wezterm = require("wezterm")
local config = wezterm.config_builder()

local wezai = wezterm.plugin.require("https://github.com/wsams/wezai")
-- Local checkout (development):
-- local wezai = wezterm.plugin.require("/absolute/path/to/wezai")

wezai.apply_to_config(config)

return config
```

Defaults (no env file, no Lua table): **Ollama** at `http://127.0.0.1:11434/v1/chat/completions`, model `llama3.2`, timeout 300s, Ask on **`CTRL+I`**. Override anything via env — GUI / Flatpak WezTerm (including Bazzite) often **does not** see `.bashrc` variables, so the env **file** is the reliable place.

```bash
# ~/.config/wezterm/wezai.env  — see wezai.env.example in the repo
WEZAI_MODEL=llama3.2
WEZAI_WEATHER_ZIP=90210
# WEZAI_API_URL=https://api.openai.com/v1/chat/completions
# WEZAI_API_KEY=  # or export OPENAI_API_KEY in a login environment WezTerm inherits
```

Optional Lua table still wins over env if you pass one: `wezai.apply_to_config(config, { model = "qwen2.5:14b" })`.

WezTerm clones plugins into its cache on first `require`. To pull a new release: palette (`CTRL+SHIFT+P`) → **Update wezai plugin**. That `git fetch` + `pull --ff-only` in the wezai checkout, runs `wezterm.plugin.update_all()`, and reloads. **Show wezai install** prints the version and cache path. Palette titles show `wezai v1.12.0+…` so you can confirm the pull.

Do **not** leave `update_all()` / `reload_configuration()` at config file scope (reload loops). If the plugin cannot load at all, use the [Troubleshooting](#troubleshooting) git-in-cache steps — the palette is unavailable until `require` succeeds.

### Providers

| `type` (`WEZAI_TYPE`) | What you need |
|--------|----------------|
| `"http"` (default) | OpenAI-compatible `WEZAI_API_URL` + `WEZAI_MODEL` (`WEZAI_API_KEY` if required). For Ollama the default URL is already `http://127.0.0.1:11434/v1/chat/completions`. Raise `WEZAI_TIMEOUT` (e.g. 300–600) for large cold loads, and prefer instruct models over “thinking” GGUFs (Ask/`#` edits need JSON — see SPECS §4.4). |
| `"local"` | LM Studio CLI (`WEZAI_LMS_PATH`) |
| `"ollama"` | `WEZAI_OLLAMA_PATH` + `WEZAI_MODEL` (CLI, not HTTP) |
| `"google"` | Gemini `WEZAI_API_KEY` or `GEMINI_API_KEY` + `WEZAI_MODEL` (uses curl + WezTerm JSON) |

---

## Quick start

| Key | Action |
|-----|--------|
| `CTRL+I` | **Ask** — composer under the shell (`@` attach, `#` edit). Esc saves a draft |
| `CTRL+SHIFT+E` | **Ask** with pane scrollback attached as context |
| `CTRL+SHIFT+P` | **Palette** — type `@git`, `@kube`, `@tf`, `@weather`, `@history`, or `Ask` to filter |
| `CTRL+SHIFT+G` | Palette scoped to `@git` |
| `CTRL+SHIFT+K` | Palette scoped to `@kube` |
| `CTRL+ALT+T` | Palette scoped to `@tf` (not `CTRL+SHIFT+T` — that is WezTerm’s new tab) |
| `CTRL+ALT+W` | Palette scoped to `@weather` (not `CTRL+SHIFT+W` — that is WezTerm’s close tab) |
| `CTRL+SHIFT+H` | Palette scoped to `@history` |

Stay on your **shell** pane. The right split is **output only** (answers, diffs, git/kube/tf/weather status). Catalog commands print immediately and spin `waiting…` until output arrives, so a slow `@weather:now` does not look frozen. Don’t run git from that pane — wezai always uses your shell’s cwd.

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
| `@weather` / `@weather:now` | Current conditions (Open-Meteo; needs a zip) |
| `@weather:zip 90210` | Save zip from the plugin (`~/.local/share/wezai/weather.json`) |
| `@dir:path` | Directory listing |
| `@history …` | Attach recent history, or open the palette if used alone |

---

## Config sketch

Merge order: **plugin defaults** → **`wezai.env` file** → **process environment** → **`apply_to_config` Lua table** (last wins).

Most people never need the Lua table. Copy [wezai.env.example](wezai.env.example) to `~/.config/wezterm/wezai.env`.

| Variable | Sets | Default |
|----------|------|---------|
| `WEZAI_TYPE` | `type` | `http` |
| `WEZAI_API_URL` | `api_url` | `http://127.0.0.1:11434/v1/chat/completions` |
| `WEZAI_API_KEY` | `api_key` | unset; falls back to `OPENAI_API_KEY` then `GEMINI_API_KEY` |
| `WEZAI_MODEL` | `model` | `llama3.2` |
| `WEZAI_MODELS` | `models` (comma-separated) | empty |
| `WEZAI_TIMEOUT` | `timeout` (seconds) | `300` |
| `WEZAI_OLLAMA_PATH` | `ollama_path` | unset |
| `WEZAI_LMS_PATH` | `lms_path` | unset |
| `WEZAI_KUBE_NS` | `kube.namespace` | kubectl current ns |
| `WEZAI_WEATHER_ZIP` | `weather.zip` | unset (`@weather:zip` still works) |
| `WEZAI_WEATHER_COUNTRY` | `weather.country` | `US` |
| `WEZAI_WEATHER_UNITS` | `weather.units` | `auto` |
| `WEZAI_ENV_FILE` | path to the env file | `~/.config/wezterm/wezai.env` (see `settings.env_file_candidates`) |

Optional Lua overrides (win over env). `CTRL+I` / `CTRL+SHIFT+E` are already the defaults:

```lua
wezai.apply_to_config(config, {
  -- macOS: Cmd+I instead of CTRL+I
  -- keybinding = { key = "i", mods = "SUPER" },
  -- keybinding_with_pane = { key = "I", mods = "SUPER" },

  keybinding_palette = { key = "p", mods = "CTRL|SHIFT" },
  keybinding_history = { key = "h", mods = "CTRL|SHIFT" },
  keybinding_git = { key = "g", mods = "CTRL|SHIFT" },
  keybinding_kube = { key = "k", mods = "CTRL|SHIFT" },
  keybinding_tf = { key = "t", mods = "CTRL|ALT" },
  keybinding_weather = { key = "w", mods = "CTRL|ALT" },

  -- Optional: default ns + absolute kubectl if GUI PATH can't find it
  kube = { namespace = nil, kubectl = nil, confirm_mutate = true },

  -- Optional: absolute terraform if GUI PATH can't find it
  tf = { terraform = nil, confirm_mutate = true },

  -- Optional: ZIP for @weather (Open-Meteo). Prefer WEZAI_WEATHER_ZIP or @weather:zip
  -- (saved under ~/.local/share/wezai/weather.json — does not rewrite this file).
  weather = { zip = nil, country = "US", units = "auto" },

  -- Dialect (fish/zsh/bash/…) is auto-appended from the active shell pane / $SHELL.
  -- system_prompt = "You are a concise terminal assistant. …",

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
  weather.lua    -- @weather Open-Meteo catalog
  context.lua    -- @ / # parsing + dir walk + token budget
  edit.lua       -- wezai dotfile backups, diffs, apply confirm
  composer.lua / composer.py  -- CTRL+I ask pane (AI log stays visible)
  files.lua      -- fuzzy @pick / #pick
  shell.lua      -- dialect, risk gate, clipboard
  util.lua
  settings.lua   -- defaults + wezai.env / process env / user merge
  version.lua    -- bundled semver (palette / pane banner)
  stats.lua      -- token/model usage DB
  providers/     -- chat_http, gemini_api, ollama_bin, lms_bin
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Stale wezai / still on an old release | Palette → **Update wezai plugin**. Confirm the palette title / AI banner version changed. **Show wezai install** prints the cache path. |
| Config error `yield across a C-call boundary` | A load-time `run_child_process` bug (fixed after 1.12.0). Palette cannot run until `require` works — use the cache `git fetch` below, then reload. |
| Palette is WezTerm’s, not wezai | Reload; wezai binds `CTRL+SHIFT+P`. |
| Env vars from `.bashrc` ignored | GUI WezTerm often has a tiny environment. Use `~/.config/wezterm/wezai.env`. |

**If wezai fails to load**, the palette is gone. Sync the GitHub clone by hand, then reload (Debug Overlay → `wezterm.reload_configuration()`, or quit/reopen).

```bash
# Encoded clone of https://github.com/wsams/wezai
NAME='*githubsDscomsZswsamssZswezai*'

# macOS
CACHE="$HOME/Library/Application Support/wezterm/plugins"
# Linux
# CACHE="${XDG_DATA_HOME:-$HOME/.local/share}/wezterm/plugins"
# Flatpak WezTerm
# CACHE="$HOME/.var/app/org.wezfurlong.wezterm/data/wezterm/plugins"

REPO=$(find "$CACHE" -type d -name "$NAME" 2>/dev/null | head -1)
# If that path is already …/plugin, cd to its parent (the git root).
cd "$REPO"
git fetch origin && git pull --ff-only
```

Optional Debug Overlay (when config still loads): `wezterm.plugin.update_all()` then `wezterm.reload_configuration()`. Never leave those at file scope in `wezterm.lua`.

---

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 wsams.
