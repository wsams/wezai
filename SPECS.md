# wezai — Product & Engineering Specs

**Audience:** humans and cloud agents working on this repo.  
**Repo:** [github.com/wsams/wezai](https://github.com/wsams/wezai)  
**License:** MIT (Copyright 2026 wsams)  
**Stack:** WezTerm Lua plugin + Node only for release tooling (semantic-release / Renovate).

This document is the canonical description of what wezai **is**, how it is **structured**, and the **behaviors / constraints** that must be preserved when changing code. Prefer this file over chat history.

Agent working notes (reserved shortcuts, load-path pitfalls): [AGENTS.md](AGENTS.md).  
User-facing walkthroughs: [GUIDE.md](GUIDE.md). Install / config sketch: [README.md](README.md).

---

## 1. Product summary

**wezai** is a WezTerm plugin that puts an AI assistant and utility catalogs next to the user’s shell:

- **Ask** — natural-language CLI help with attachable context (`@file`, `@dir/`, selection, git, kube, tf, weather, history). CTRL+I opens a **composer pane** under the shell so the right-hand AI log stays visible; drafts persist if you Esc.
- **Edit** — create/rewrite via `#path` (legacy `@@path`) with unified diff + confirm. `#dir/` pins a tree of editable files.
- **Palette** — fuzzy `InputSelector` (`CTRL+SHIFT+P`) for Ask helpers, `@git`, `@kube`, `@tf`, `@weather`, `@history`, Compact, Clear, plugin update.
- **AI output pane** — right-side keep-alive pane for answers, diffs, git/kube/tf/weather show output (not for running shell/git).

- **Safety** — secret redaction, risky-command confirms, mutate confirms for git/kube/tf/edit.

Brand string in UI/logs: **`wezai`**. Never introduce third-party product branding in UI strings.

**Install version** is shown in every command-palette title and the AI output-pane banner (also logged on load). Prefer bundled `plugin/version.lua` (kept in sync with semantic-release / `package.json`) so Flatpak/Bazzite installs still show a semver when `package.json` sits outside the Lua dir. Append a 7-char git sha by **reading** `.git/HEAD` (and ref files) — never `git` / `run_child_process` here, because `version_label()` runs inside plugin `require()` and WezTerm cannot yield across that C-call. Format via `util.brand_with_version()` — e.g. `wezai v1.10.0+fc6d5b5`. Last resort is `dev`, never a bare `?`.

---

## 2. Install & load

```lua
-- Published:
local wezai = wezterm.plugin.require("https://github.com/wsams/wezai")
-- Local checkout (preferred while developing — avoids update_all clobbering unreleased fixes):
-- local wezai = wezterm.plugin.require("/absolute/path/to/wezai")

wezai.apply_to_config(config)
-- Optional Lua table still wins over wezai.env / process env:
-- wezai.apply_to_config(config, { model = "qwen2.5:14b" })
```

User customizations (provider, weather zip, kube ns, …) belong in **`~/.config/wezterm/wezai.env`** (see [wezai.env.example](wezai.env.example)). GUI/Flatpak WezTerm often does not inherit `.bashrc` environment.

To refresh a **GitHub** install: command palette → **Update wezai plugin** (`wezterm.plugin.update_all()` + `wezterm.reload_configuration()`). Do **not** call those at config file scope — `reload_configuration()` loops, and `update_all()` overwrites a local checkout. Debug Overlay remains an optional alternative.

WezTerm stores plugins under its plugin cache (encoded URLs / paths). After editing a **GitHub-required** install: use the palette update action, or sync the working tree into that cache dir, then reload. For day-to-day Lua work, `plugin.require("/absolute/path/…")` and skip `update_all()`.

Public entrypoint: `plugin/init.lua` → `apply_to_config(wezterm_config, user_config)`.

---

## 3. Repository layout

```
plugin/
  init.lua          -- bootstrap, keybindings, ask/edit orchestration, palette hooks
  settings.lua      -- defaults + wezai.env / process env / user merge (nested: ai_pane, history, git, kube, tf, weather, stats, files, backup, composer, context)
  version.lua       -- bundled semver for UI (semantic-release writes this)
  util.lua          -- paths, files, JSON parse, run_cmd (pcall), resolve_executable, large-file read, version_label

  ui.lua            -- AI pane lifecycle, styling, InputSelector, usage banner
  session.lua       -- per-tab chat memory + pinned @/# files + draft + last edit
  shell.lua         -- shell detect, OS platform hint, risk gate, clipboard, send_command
  context.lua       -- @ / # parsing (@@ alias), dir walk, token budget, redaction
  edit.lua          -- wezai dotfile backups, unified diff, apply/undo
  files.lua         -- fuzzy file+dir list (fd → git ls-files → find) + @pick / #pick
  composer.lua      -- CTRL+I split composer (does not cover the AI pane)
  composer.py       -- readline-less TUI: live @/# fuzzy paths, draft, OSC user vars
  history.lua       -- fish/zsh/bash history + scrollback + session events
  git.lua           -- @git action catalog
  kube.lua          -- @kube action catalog
  tf.lua            -- @tf terraform action catalog
  weather.lua       -- @weather Open-Meteo catalog (zip overlay)
  palette.lua       -- unified CTRL+SHIFT+P palette
  stats.lua         -- persistent token/model usage DB
  providers/
    init.lua        -- type → backend; ask()/ready(); usage meta finalize
    proc.lua        -- curl / child_process helpers
    chat_http.lua   -- OpenAI-compatible chat completions
    gemini_api.lua  -- Google Gemini generateContent
    ollama_bin.lua  -- ollama CLI
    lms_bin.lua     -- LM Studio `lms` CLI
README.md GUIDE.md SPECS.md AGENTS.md LICENSE wezai.env.example
package.json .releaserc.json renovate.json
.github/workflows/release.yml
.github/workflows/renovate.yml
```

Node/`package.json` is for semantic-release tooling. At runtime the Lua plugin prefers `plugin/version.lua` (always on the Lua path) and walks up from the plugin dir for `package.json` / git HEAD when labeling palettes and the AI pane.

---

## 4. Architecture rules (non-negotiable)

### 4.1 Shell pane vs AI pane

- All git/kube/tf/history/cwd work must use the **shell** pane, never the AI output pane.
- `ui.shell_pane_for(window, pane)` resolves the real shell when focus is on the AI pane.
- AI pane is output-only (keep-alive `sh`/`sleep` loop marked `WEZAI_OUTPUT_PANE`).

### 4.2 AI pane reuse

- `ui.ensure_ai_pane` must **never** spawn a second AI pane if one already exists in the tab.
- Detection: remembered pane id + process fingerprint (`WEZAI_OUTPUT_PANE` / sleep loop) + scrollback heuristics.
- `spawn_ai_pane` must re-scan the tab and skip split if an AI pane is found.

### 4.3 Provider API

```text
providers.ask(cfg, user_text) → ok, text, err, meta
providers.ready(cfg) → boolean
meta = { model, prompt_tokens, completion_tokens, estimated? }
```

- HTTP/Gemini: prefer real usage fields when present.
- CLI backends: estimate tokens (~4 chars/token) and set `estimated = true`.
- User-facing `config.type`: `"http"` | `"google"` | `"ollama"` | `"local"`.

### 4.4 Model JSON contract

Ask responses are parsed as JSON with:

- `message` (string)
- `command` (string or null)

Edit responses:

- `message`, `file` (full file contents), `command` (null)
- Aliases accepted for the file body if `file` is missing/empty: `content`, `new_content` (models often invent these).

`settings.REPLY_CONTRACT` is appended to custom `system_prompt` if it does not already mention `"message"`. Edit requests replace `system_prompt` with `context.EDIT_SYSTEM_PROMPT` (user style prompt is not used for `#` / `@@`). Multi-file edits accept a `files` array (`path` + `content`); a single `file` field still works.

Parsing (`util.parse_json_response`): try raw → fenced body → fence-stripped → first top-level `{…}` via `util.extract_json_object` (handles prose wrappers from chatty/thinking models). Prefer **instruct** models that emit JSON only; thinking models are a poor fit (see [AGENTS.md](AGENTS.md)).

### 4.4.1 HTTP `timeout` (local LLMs)

`timeout` (seconds) maps to curl `--max-time` (default **300**, sized for local Ollama cold loads). Cloud chat APIs usually finish sooner — set `WEZAI_TIMEOUT` or `timeout` lower if you want a tighter cap. Local OpenAI-compatible servers (notably **Ollama**) may send **no response bytes** until the model runner finishes loading and warmup. If the client disconnects mid-load, Ollama aborts the load (`client connection closed before llama-server finished loading`), so the model never stays warm and every attempt looks cold. For large local models set `timeout` to **300–600**, or pre-warm the model. Transport errors that look like curl timeouts get an explanatory hint from `providers.chat_http`.

While Ask/Edit wait, `ui.start_progress` (when `show_loading` is true) scrolls status lines in the AI pane: model + endpoint, elapsed vs timeout with %, remaining time, and rotating phase hints (cold load / warmup / approaching timeout). Pulses use `wezterm.time.call_after` so they keep printing during long `run_child_process` yields.
### 4.5 Dialect + platform injection

On every ask (`with_dialect` in `init.lua`):

1. Detect shell from the **shell pane** (fish / zsh / bash / powershell), else `$SHELL`.
2. Detect OS via `wezterm.target_triple` / `uname` (macos / linux / windows).
3. Append `shell.dialect_hint` + `shell.platform_hint` to `system_prompt`.

Fish rules must forbid trailing `; end` without a block. macOS rules must forbid GNU-only flags (e.g. `du --exclude`).

Command labels print as `(fish/macos)` style when showing suggested commands.

### 4.6 Safety

- `context.redact` strips common secrets (keys, tokens, JWTs, private keys) before prompts/history.
- `shell.is_risky` + confirm before sending dangerous commands (includes kubectl mutate/exec patterns, terraform apply/destroy/import/state-rm/force-unlock, and git force/push/reset/etc.).
- Edit apply and kube/tf mutate actions confirm unless config disables confirms. Edit confirm embeds the unified diff in the overlay (WezTerm InputSelector covers the tab).
- Edit backups are timestamped **dotfiles** with `wezai` in the name (`backup.enabled` / `backup.dir` / `backup.suffix` / `backup.dotfile`). Default: `.notes.txt.<YYYYMMDD-HHMMSS>.wezai.bak` next to the target. Undo uses the bak file or in-memory prior content. Directory walks skip `*wezai*.bak`.
- Kube AI helpers must prefer **read-only** next steps (get/describe/logs); never bake org-specific cluster/namespace names into the catalog.
- Terraform AI helpers must prefer **read-only** next steps (validate/fmt/plan/state list) and `#` file edits; never bake account/org-specific names into the catalog.

### 4.7 Child processes & Lua returns

- `util.run_cmd(args)` wraps `wezterm.run_child_process` in `pcall` and always returns `ok, stdout, stderr` (never throws).
- `util.resolve_executable(name, opts)` finds tools despite a thin GUI PATH (absolute candidates + login shell).
- APIs that return `(value, err)` must use **`err = nil` on success**. Do not use `ok and nil or stderr` when `stderr` may be `""` — empty string is truthy in Lua and will be treated as failure by callers.

---

## 5. Features

### 5.1 Ask (`keybinding`, default often remapped to CTRL+I by users)

Flow: **composer pane** (split of the shell, AI log stays visible) → parse refs → `context.prepare_request` → `providers.ask` → print message/command → optional `shell.send_command`.

If `composer.enabled = false` or python3/`composer.py` is missing, fall back to WezTerm `PromptInputLine` (full-window overlay). Esc in the composer **saves a draft** and restores it on the next CTRL+I.

Supports:

| Token | Behavior |
|-------|----------|
| `@path` / `@"./path with spaces"` | Attach file (read-only); **pinned** for the tab until Clear |
| `@dir/` (trailing slash or a directory path) | Walk the tree, attach relevant files up to the token budget |
| `#path instruction` | Create or rewrite file (unified diff + confirm). New files OK if the parent dir exists |
| `#dir/` | Pin every attachable file under the directory as **edit** targets |
| `@@path` | Legacy alias of `#path` |
| `@` / `@pick` / `#` / `#pick` / `@@` / `@@pick` | Fuzzy file picker (`files.lua`) |
| `@clipboard` / `@selection` | Clipboard / selection (selection is sticky until Compact) |
| `@git` / `@git:id` | Git picker or action (see §5.4) |
| `@kube` / `@kube:id` / `@kube:pods/<ns>` | Kube picker, action, or attach with optional ns (see §5.5) |
| `@tf` / `@tf:id` / `@terraform:id` | Terraform picker, action, or attach (see §5.6) |
| `@weather` / `@weather:id` | Weather picker, current/forecast, or attach (see §5.9) |
| `@history` / bare history ref | History palette / attach |
| `@dir:path` | Shallow directory **listing** only (not file contents) |
| `compact` / `/compact` | Compact conversation + sticky selection; keep `@`/`#` pins |
| `clear` / `/clear` | Wipe turns, selections, drafts, and file pins |

**Composer autocomplete:** typing `@` or `#` lists files and directories under the shell cwd (prefix then fuzzy). Tab inserts the highlighted path; Enter accepts an incomplete match, or sends the line when the token is already exact / the cursor is outside a ref. `@git:` / `@kube:` / `@tf:` / `@history` are reserved and do not open the file list.

**Path parsing:** unquoted `@`/`#` refs strip trailing sentence punctuation (`?!. ,;:)` …) so `@package.json?` works. Quoted paths are literal. `#` is only a ref at token start when the next character is path-like (not `# heading` with a space).

**New files:** `#newfile.txt …` creates if parent dir exists (`is_new`, empty original, Create confirm).

**Edit confirm:** WezTerm `InputSelector` covers the tab, so the unified diff is embedded in the selector choices (Apply / Cancel first; colored diff preview below). The full diff is also printed in the AI pane. Selecting a preview row re-opens the selector. Multi-file `#dir/` edits print every diff in the AI pane and use one Apply-all confirm.

**Backups:** On Apply, write a timestamped **dotfile** unless `backup.enabled = false`. Default name: `.file.<YYYYMMDD-HHMMSS>.wezai.bak` next to the target (`backup.dotfile = true`), or under `backup.dir` when set. Undo restores the last apply (all files in a multi-edit batch).

**Large `@` files / directories:** soft budget `max_file_bytes` (default 200000) per file; directory walks also honor `context.max_dir_files` / `context.max_dir_bytes` / `context.max_prompt_tokens`. Oversized attaches use head+tail (`files.large_file = "head_tail"`). `#` edit still requires the full file under the per-file limit. If the packed prompt exceeds `context.confirm_tokens`, wezai warns and asks for confirmation (once per session until Clear).

**Session:** `@` and `#` pins persist across CTRL+I turns in the same tab. Compact does **not** drop file pins — only conversation turns and sticky selection/scrollback extras. Clear drops everything.

**Share pane history:** `keybinding_with_pane` attaches scrollback to the prompt.

### 5.2 Palette (`CTRL+SHIFT+P`)

Unified fuzzy `InputSelector` with scopes:

- full (Ask helpers + git + kube + tf + weather + history rows)
- `git` (`CTRL+SHIFT+G`)
- `kube` (`CTRL+SHIFT+K`)
- `tf` (`CTRL+ALT+T` — not `CTRL+SHIFT+T`, which is WezTerm SpawnTab)
- `weather` (`CTRL+ALT+W` — not `CTRL+SHIFT+W`, which is WezTerm CloseCurrentTab)
- `history` (`CTRL+SHIFT+H`) and filtered history scopes

Core palette rows include: Ask, Ask+pane, Fix last error, Explain last command, Attach/Edit file (fuzzy), Undo edit, Copy last command, Shorter re-ask, Pick model, **Compact chat (keep @/# files)**, **Clear chat + file context**, **Update wezai plugin**.

### 5.3 History

- Sources: fish/zsh/bash history files (tailed), optional scrollback, session events (ask/ai-cmd/edit).
- Config: `history.max_shell`, `palette_n`, `tail_bytes`, `attach_n`, `include_scrollback`, `max_session`.
- Row actions: Run / Insert / Explain / Attach & ask / Copy.
- Attach limits: `@history:40` (all, N entries), `@history:shell:40` / `@history:ai:20` / `@history:failed:15` (filter + N). Default limit = `attach_n` (40). Bare `@history` / `@history:shell` open the palette.

### 5.4 `@git` catalog (`git.lua`)

Kinds: `show` (print in AI pane), `shell` (run/insert in shell), `ai` (LLM with git context).

Show: `status`, `diff`, `logN` (default 15), `branch`, `stash`, `remote`, `whoami`.  
Shell: `rebaseN`/`softN` (any positive N, or bare `rebase`/`soft` with prompt), unstage/restore/latest/fetch/pull/push/pushu/sync/stash-*/switch/newbranch/add/commit/amend/identity/ignore.  
AI: `msg`, `explain`, `review`, `pr`, `resolve`, `fixup`.

Bare `@git:status` = run action; `@git:status what should I commit?` = attach + ask (via context synthetics where supported).  
`@git:rebase15` / `@git:soft3` / `@git:log30` embed N in the id; space form (`@git:log 30`) also works. Bare `@git:rebase` / `@git:soft` prompt for N; bare `@git:log` defaults to 15.

Always `ui.shell_pane_for` for cwd. Force git color off for AI-pane readability.

### 5.5 `@kube` catalog (`kube.lua`)

Placeholders only (`<namespace>`, `<pod>`, `<name>`, `<file>`, …) — **no** org-specific names.

#### Cluster / binary / namespace

- **Cluster selection is outside wezai.** Catalog commands never pass `--kubeconfig`; they use the user’s current `kubectl` context / `KUBECONFIG`. Document one example in GUIDE only; do not clutter action templates with kubeconfig flags.
- **Binary resolution:** Show/AI/attach call `wezterm.run_child_process` from the GUI process (Dock/Spotlight PATH is often incomplete). Resolve via `config.kube.kubectl` or `util.resolve_executable` (Homebrew/Docker/asdf/mise candidates + `zsh`/`bash -lc 'command -v …'`). Cache the absolute path in-module. Shell-kind actions still **insert** bare `kubectl …` into the user’s shell (their PATH/KUBECONFIG apply).
- **`util.run_cmd`:** always `pcall`s `run_child_process` — missing binaries become `ok=false` + error string, never throw into the palette.
- **Namespace resolution** (`resolve_namespace`): action/attach extra → `config.kube.namespace` → kubectl current-context namespace. Extra may be a ns name, or `-A` / `--all-namespaces`.

#### Invocation forms

| Form | Meaning |
|------|---------|
| `@kube` / `@kube:` | Open kube palette |
| `@kube:pods` | Show pods in resolved namespace |
| `@kube:pods kube-system` | One-shot ns override (Ask bare action / `parse_line` extra) |
| `@kube:pods/kube-system` or `@kube:pods:kube-system` | Same override (inline `/` or `:`) |
| `@kube:pods -A` | All namespaces (`-A` on the get) |
| `@kube:pods-all` | Explicit all-ns pods action |
| `@kube:use-ns` / `@kube:use-ns myns` | Prompt or set current-context namespace |

Bare `@kube:id` with trailing text that is **not** only an action run may attach + ask when routed through Ask/`prepare_request` synthetics (same idea as `@git:status …`).

#### Catalog kinds

- Show: `ctx`, `ns`, `nodes`, `pods`, `pods-all`, `all`, `deploy`, `sts`, `svc`, `ing`, `cm`, `secrets` (names only), `pvc`, `events`, `top-nodes`, `top-pods`, `api-resources`, `can-i`.
- Shell: `describe`, `logsN` / `logs-fN` / `logs-deployN` (`--tail=N`; defaults 200 / 100 / 200), `exec`, `pf`, `pf-svc`, `rollout`, `restart`, `scale`, `wait`, `diff`, `apply`, `delete-f`, `get-yaml`, `use-ns`.
- AI (careful): `diagnose`, `explain-sel`, `not-ready` — gather read-only kubectl output; steer toward get/describe/logs; honor ns extra when present.
- Mutate confirms when `kube.confirm_mutate` (default true). Empty successful gets print a clear “(no resources…)” line instead of a blank body.
- Logs count: `@kube:logs500`, `@kube:logs-f50`, `@kube:logs 500` (numeric-only extra = tail). Do **not** use `:N` — colon/slash extras are namespace overrides.

#### Ask attach tokens

Supported synthetics (optional ns via `/` or `:`):

- `@kube:pods`, `@kube:pods/kube-system`, `@kube:events`, `@kube:events/-A`, `@kube:all`, `@kube:nodes`, `@kube:ctx`

`collect_attach` splits `pods/<ns>` with a plain `/` or `:` cut (not a fragile pattern). **Return contract:** `(content, err)` where success is `err == nil` — never return `""` as `err`. In Lua only `nil`/`false` are falsy; empty stderr used to look like failure (`failed:` with no message). `context.lua` also treats `err == ""` as success for defense in depth.

### 5.6 `@tf` catalog (`tf.lua`)

Kinds: `show` (print in AI pane), `shell` (run/insert in shell), `ai` (LLM for generate/debug).

Uses the shell pane cwd via `-chdir=`. Binary resolution mirrors kube: `config.tf.terraform` or `util.resolve_executable` (Homebrew/asdf/mise + login shell). Shell-kind actions insert bare `terraform …` into the user’s shell.

#### Invocation forms

| Form | Meaning |
|------|---------|
| `@tf` / `@tf:` / `@terraform` | Open terraform palette |
| `@tf:validate` | Show `terraform validate` in AI pane |
| `@tf:plan` | Insert/run `terraform plan` in shell |
| `@tf:generate add an S3 bucket` | AI generate (extra = instruction) |
| `@tf:state what’s orphaned?` | Attach state list + ask (show → attach mode) |

Bare `@tf:id` = run action; show actions with trailing text fall through to attach + ask (same idea as `@git:status …`). `@terraform:id` is accepted as an alias for `@tf:id`.

#### Catalog kinds

- Show (no model): `version`, `validate`, `providers`, `workspace`/`ws`, `state`, `output`, `fmt-check`.
- Shell (no model): `init`, `fmt`, `plan`, `apply`, `destroy`, `refresh`, `import`, `workspace-select`, `workspace-new`, `state-rm`, `unlock`.
- AI: `generate`/`gen` — HCL from description (+ existing `*.tf` context); `debug`/`diagnose`/`fix` — selection/scrollback + validate/state/sources; `explain`; `review`.

Mutate confirms when `tf.confirm_mutate` (default true) for apply/destroy/import/state-rm; unlock always confirms. AI helpers steer toward validate/fmt/plan/`#` edits — never bake apply/destroy into suggested commands unless the user clearly asked to mutate.

#### Ask attach tokens

Supported synthetics:

- `@tf:version`, `@tf:validate`, `@tf:providers`, `@tf:workspace`, `@tf:state`, `@tf:output`, `@tf:fmt-check`, `@tf:sources`

### 5.7 Stats / usage

- DB: `~/.local/share/wezai/stats.json` (override `stats.path`; disable with `stats.enabled = false`).
- Tracks totals, per-model, last call (prompt/completion tokens, model).
- Banner on **new** AI pane create; per-turn line after each successful ask/edit.

### 5.8 Session

Per-tab:

- Chat turns (safety-capped; use **Compact** to shrink — not a silent 6-turn trim)
- Pinned `@` attach paths and `#` edit targets (re-read from disk each turn; survive Compact)
- Sticky selection / extra context (cleared by Compact)
- Composer draft (Esc in CTRL+I)
- Last question/command, last edit batch (for undo), history events

**Compact** folds older turns into a recap and drops sticky selection text. **Clear** wipes pins, draft, turns, and extras.

### 5.9 `@weather` catalog (`weather.lua`)

Kinds: `show` (print in AI pane), `shell` (prompt / persist zip). No model. Forecast from **Open-Meteo** (no API key). ZIP / postal codes geocode via Zippopotam.us, then Open-Meteo geocoding, then Nominatim.

#### Zip resolution

1. Plugin overlay `~/.local/share/wezai/weather.json` (`weather.path` override) when `@weather:zip` has saved a zip.
2. Else `weather.zip` / `weather.country` from `apply_to_config`.

`@weather:zip` **does not rewrite** `wezterm.lua`. It writes the overlay so the zip can be changed from the palette without editing config. `@weather:zip clear` (or `none`) drops the overlay; the wezterm.lua value applies again. Coords are cached in the same JSON.

`weather.units`: `"auto"` (US → imperial °F/mph/in; otherwise metric), `"imperial"`, or `"metric"`. Default country `"US"`.

#### Invocation forms

| Form | Meaning |
|------|---------|
| `@weather` / `@weather:` | Open weather palette |
| `@weather:now` | Current conditions + next hours + today/tomorrow (AI pane) |
| `@weather:forecast` | Current + 7-day daily |
| `@weather:zip` / `@weather:zip 90210` | Prompt or set zip (optional `, US` / trailing ISO country) |
| `@weather:where` | Show effective zip, overlay vs wezterm.lua, resolved place |
| `@weather should I bring a jacket?` | Attach current weather + ask |
| `@weather:forecast what’s the weekend look like?` | Attach 7-day + ask |

#### Catalog kinds

- Show: `now` (`current` alias), `forecast`, `where`.
- Shell: `zip` — persist overlay; extra is the postal code.

#### Ask attach tokens

- `@weather`, `@weather:now`, `@weather:forecast`

---

## 6. Default keybindings

| Binding | Default | Action |
|---------|---------|--------|
| Ask | `CTRL+i` | Prompt (set `SUPER` in Lua if you want Cmd+I on macOS) |
| Ask + pane history | `CTRL+SHIFT+e` | Prompt with scrollback |
| Palette | `CTRL\|SHIFT+p` | Full palette (includes **Update wezai plugin**) |
| History scope | `CTRL\|SHIFT+h` | History palette |
| Git scope | `CTRL\|SHIFT+g` | Git palette |
| Kube scope | `CTRL\|SHIFT+k` | Kube palette |
| Terraform scope | `CTRL\|ALT+t` | Terraform palette |
| Weather scope | `CTRL\|ALT+w` | Weather palette |

**Reserved:** `CTRL+SHIFT+T` is WezTerm **`SpawnTab`** — never bind wezai to it. `CTRL+SHIFT+W` is WezTerm **`CloseCurrentTab`** — weather uses `CTRL+ALT+W`. See [AGENTS.md](AGENTS.md).

Single-letter keys are also bound with opposite case for WezTerm quirks.

---

## 7. Configuration surface

Merged in `settings.finalize`. Order: **BASE defaults** < **`wezai.env` file** < **process environment** < **`apply_to_config` table**. Nested keys deep-merged: `ai_pane`, `history`, `git`, `kube`, `tf`, `weather`, `stats`, `files`, `backup`, `composer`, `context`.

Env file (first existing): `$WEZAI_ENV_FILE`, `$XDG_CONFIG_HOME/wezterm/wezai.env`, `~/.config/wezterm/wezai.env`, `~/.local/share/wezai/wezai.env`. Simple `KEY=VALUE` (`#` comments, optional `export`, quotes). GUI/Flatpak often has no shell env — the file is the supported path for secrets and zip/model.

Copy-paste BASE (no env, no Lua table): `type=http`, Ollama `api_url`, `model=llama3.2`, `timeout=300`, Ask `CTRL+I`.

Important fields (see `settings.lua` for full defaults):

| Key | Role |
|-----|------|
| `type`, `model`, `models`, `api_url`, `api_key`, `headers`, `timeout` | Provider (`timeout` default 300s; raise further for huge local loads — §4.4.1). Env: `WEZAI_TYPE`, `WEZAI_MODEL`, `WEZAI_MODELS`, `WEZAI_API_URL`, `WEZAI_API_KEY` (`OPENAI_API_KEY` / `GEMINI_API_KEY` fallback), `WEZAI_TIMEOUT` |
| `show_loading` | When true (default), Ask/Edit scroll timed status in the AI pane while waiting (model, endpoint, elapsed/timeout %, phase hints). Set `false` to silence. |
| `ollama_path`, `lms_path` | CLI backends (`WEZAI_OLLAMA_PATH`, `WEZAI_LMS_PATH`) |
| `system_prompt` | Style; dialect/OS appended per request; JSON contract appended if needed |
| `max_file_bytes`, `files.*`, `context.*` | Attach budget, large-file policy, dir-walk / token confirm |
| `composer.enabled`, `composer.size_percent` | CTRL+I split composer (default on; ~32% of the shell pane) |
| `ai_pane.*` | Split direction/size/pad |
| `backup.enabled`, `backup.suffix`, `backup.dir`, `backup.dotfile` | Edit backups (default on; suffix `.wezai.bak`; `dotfile` default true → `.name.<ts>.wezai.bak`). `backup = false` disables. Legacy `backup_suffix` still maps to `backup.suffix` |
| `require_edit_confirm`, `require_risk_confirm` | Safety toggles |
| `kube.namespace`, `kube.kubectl`, `kube.confirm_mutate`, `kube.max_attach_bytes` | kubectl defaults / binary / attach cap (`WEZAI_KUBE_NS`) |
| `tf.terraform`, `tf.confirm_mutate`, `tf.max_attach_bytes` | terraform binary / mutate confirms / attach cap |
| `weather.zip`, `weather.country`, `weather.units`, `weather.path` | Open-Meteo location (plugin `@weather:zip` overlay beats `zip` / `WEZAI_WEATHER_ZIP`) |
| `git.default_branch`, `git.confirm_push`, `git.max_attach_bytes` | git catalog |
| `history.*` | Shell/session history limits |
| `stats.*` | Usage DB |
| `rocks_bin` | Optional luarocks LUA_PATH (rarely needed) |

---

## 8. Providers

| `type` | Module | Notes |
|--------|--------|-------|
| `http` | `providers.chat_http` | OpenAI-compatible `/v1/chat/completions` (includes Ollama at `http://host:11434/v1/chat/completions`) |
| `google` | `providers.gemini_api` | Gemini `generateContent` + JSON schema |
| `ollama` | `providers.ollama_bin` | `ollama run … --format json` |
| `local` | `providers.lms_bin` | `lms chat …` |

Shared transport: `providers.proc`.

For `http` + Ollama: pick an **instruct** model that obeys §4.4; set a high `timeout` for cold loads (§4.4.1). `type = "ollama"` uses the CLI path instead of HTTP and has different latency characteristics.
---

## 9. Bootstrap / module path

WezTerm Lua has no `debug.getinfo`. `init.lua` locates the plugin dir by scanning `wezterm.plugin.list()` for fingerprint files (`settings.lua`, `stats.lua`, `providers/init.lua`, `palette.lua`). Each listed `plugin_dir` is tried as **clone-root/`plugin/`** and as **the Lua dir itself** (Flatpak/Bazzite sometimes report the latter). Among matches it **prefers the most complete install** (counts `git.lua` / `kube.lua` / `tf.lua` / `weather.lua` / `version.lua` / `composer.lua` / …) so a stale local checkout cannot shadow an updated GitHub cache that has newer catalogs. Local/`wsams` paths win only as a tie-breaker. Then extends `package.path` for `?.lua` and `?/init.lua`, and passes `plugin_dir` + repo root into `util.set_install_dirs` so `util.version_label()` can `require("version")` and walk up for `package.json` / git HEAD. `@tf` and `@weather` are soft-required — a missing `tf.lua` / `weather.lua` logs a warning and disables that catalog instead of failing the whole plugin.

---

## 10. Release & dependency automation

### semantic-release (direct npm — not a third-party GitHub Action wrapper)

- Workflow: `.github/workflows/release.yml` on push to `main`.
- Config: `.releaserc.json` — changelog + version bump in git + GitHub Release; **`npmPublish: false`**. `@semantic-release/exec` writes `plugin/version.lua` during prepare so WezTerm installs that cannot see `package.json` still show a semver.
- Conventional Commits required (`feat:`, `fix:`, `BREAKING CHANGE`, etc.).
- Node: `^22.14.0 || >=24.10.0`.

### Renovate (self-hosted nightly GHA)

- Workflow: `.github/workflows/renovate.yml` — cron `0 13 * * *` (≈06:00 America/Los_Angeles) + `workflow_dispatch`.
- Config: `renovate.json` — schedule `at any time` (workflow is the gate), `platformAutomerge`, semantic `chore(deps)`.
- Secret: `RENOVATE_TOKEN` (classic PAT with `repo` + `workflow`).

---

## 11. Development conventions

1. **Preserve behaviors in §4** unless the change explicitly revises this spec.
2. Match existing Lua style (local modules, small helpers, `wezterm.log_*`).
3. Do not add unnecessary markdown files; update README/GUIDE/SPECS when user-facing behavior changes.
4. Prefer established tools (`fd`/`git`/`find`, system `diff -u`, `kubectl`, `terraform`) over reinvention.
5. Local WezTerm testing: prefer `plugin.require("/absolute/path/to/checkout")` and **do not** call `update_all()` on every reload. GitHub installs: palette **Update wezai plugin**, or sync the working tree into the matching cache dir then reload.
6. Multi-return APIs that use an error slot must return **`nil` on success**, never `""` (Lua truthiness).
7. Never commit secrets (API keys in `wezterm.lua` stay user-local).
8. UI copy and logs say **wezai**, not other product names.
9. Do not call `wezterm.run_child_process` from a module main chunk (`require`). Config load will fail with `attempt to yield across a C-call boundary`.

---

## 12. Testing checklist (manual)

- [ ] Ask with `@package.json?` attaches `package.json` (punctuation stripped).
- [ ] `@plugin/` walks the directory; oversized packs confirm before send.
- [ ] `#notes.txt sort lines` (and legacy `@@notes.txt`) shows diff confirm.
- [ ] `#newfile.txt create lorem` creates file after Apply/Create.
- [ ] CTRL+I composer splits the **shell** pane (AI log on the right stays visible); Esc restores a draft.
- [ ] Typing `@` / `#` in the composer lists cwd files/dirs; Tab completes.
- [ ] Compact keeps `@`/`#` pins and drops conversation / sticky selection.
- [ ] Clear drops pins and chat.
- [ ] `@pick` / palette Attach file opens fuzzy selector.
- [ ] Large `@file` attaches as truncated head+tail, not hard error.
- [ ] Pick model / palette actions reuse **one** AI pane (no second split).
- [ ] Palette title and AI pane banner show install version (`wezai v…` / sha), never `wezai ?` when `plugin/version.lua` is present. Config load must not error with `yield across a C-call boundary`.
- [ ] `wezai.apply_to_config(config)` with no table binds keys using Ollama HTTP defaults; `wezai.env` / `WEZAI_*` overlay model, zip, and keys.
- [ ] Palette **Update wezai plugin** pulls the GitHub cache and reloads (do not put `update_all()` at config file scope).
- [ ] Fish dialect: no bogus `; end` on one-liners; macOS: no `du --exclude`.
- [ ] `@git:status` prints in AI pane; mutating git confirms.
- [ ] `@kube:pods` shows current ns (or “(no resources…)”); kubectl found even when WezTerm was Dock-launched.
- [ ] `@kube:pods kube-system` / `@kube:pods/kube-system` override ns; `@kube:pods -A` lists all ns.
- [ ] Ask `@kube:pods/kube-system what’s running?` attaches pods (no empty `failed:`).
- [ ] `@kube:use-ns myns` / `@kube:diagnose`; mutates confirm.
- [ ] `@tf:validate` prints in AI pane; `@tf:plan` runs in shell; `@tf:apply` confirms.
- [ ] `@tf:generate …` / `@tf:debug` use the model; attach `@tf:state what’s orphaned?` works.
- [ ] `@weather:zip 90210` persists overlay; `@weather:now` prints Open-Meteo in the AI pane; `@weather:zip clear` falls back to `weather.zip`.
- [ ] Ask `@weather should I bring a jacket?` attaches current conditions (needs a zip).
- [ ] Stats banner/line appears; `~/.local/share/wezai/stats.json` updates.
- [ ] Git/kube/tf/weather/history always use shell cwd (not AI pane).
- [ ] Local Ollama HTTP: with an unloaded large model, `timeout` ≥ load+warmup still returns JSON (not curl 28 / 0 bytes); second Ask is fast while model stays loaded.
- [ ] During a multi-minute Ask wait, AI pane scrolls progress with model/endpoint, elapsed vs timeout %, and rotating hints (not only a bare “thinking…” line).
- [ ] Chatty model wrapping JSON in prose still parses via `extract_json_object` when a single object is present.
- [ ] `#` / `@@` edit accepting `content` alias when `file` is missing still shows diff confirm (diff visible inside the overlay).
- [ ] Apply writes `.file.<YYYYMMDD-HHMMSS>.wezai.bak`; `backup.enabled = false` skips bak and Undo still works; `backup.dir` relocates bak files; `backup.dotfile = false` drops the leading dot.
---

## 13. Out of scope / non-goals

- Publishing the Lua plugin to npm (package is private; release is GitHub tags/changelog only).
- Requiring luarocks/dkjson for Gemini (uses WezTerm JSON + curl).
- Embedding customer-specific cluster, namespace, or host names in catalogs.
- Making the AI pane a general-purpose shell.

---

## 14. Quick pointers for agents

| Goal | Start here |
|------|------------|
| Reserved shortcuts / agent pitfalls | `AGENTS.md` |
| Local Ollama timeout / thinking models / JSON contract | `AGENTS.md` (§ Local HTTP), SPECS §4.4–4.4.1 |
| Ask / keys / orchestration | `plugin/init.lua` |
| Defaults / merge | `plugin/settings.lua` |
| `@` / `#` parsing / prepare / attach errors | `plugin/context.lua` |
| CTRL+I composer (AI pane stays visible) | `plugin/composer.lua`, `plugin/composer.py` |
| `run_cmd` / `resolve_executable` | `plugin/util.lua` |
| Pane / UI | `plugin/ui.lua` |
| Install version label | `plugin/version.lua`, `plugin/util.lua` (`version_label` / `brand_with_version`) |
| Settings / env overlay | `plugin/settings.lua` (`wezai.env`, `WEZAI_*`) |
| Providers | `plugin/providers/` |
| Git / Kube / Terraform catalogs | `plugin/git.lua`, `plugin/kube.lua`, `plugin/tf.lua` |
| Weather / zip overlay | `plugin/weather.lua` (`set_zip`, `resolved_location`, `collect_attach`) |
| Kube ns / kubectl bin / attach | `plugin/kube.lua` (`resolve_namespace`, `kubectl_bin`, `collect_attach`) |
| Terraform bin / attach / AI | `plugin/tf.lua` (`terraform_bin`, `collect_attach`, `generate`/`debug`) |
| Fuzzy files | `plugin/files.lua` |
| Usage DB | `plugin/stats.lua` |
| User docs | `README.md`, `GUIDE.md` |
