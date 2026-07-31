# wezai — Product & Engineering Specs

**Audience:** humans and cloud agents working on this repo.  
**Repo:** [github.com/wsams/wezai](https://github.com/wsams/wezai)  
**License:** MIT (Copyright 2026 wsams)  
**Stack:** WezTerm Lua plugin + Node only for release tooling (semantic-release / Renovate).

This document is the canonical description of what wezai **is**, how it is **structured**, and the **behaviors / constraints** that must be preserved when changing code. Prefer this file over chat history.

User-facing walkthroughs live in [GUIDE.md](GUIDE.md). Install / config sketch: [README.md](README.md).

---

## 1. Product summary

**wezai** is a WezTerm plugin that puts an AI assistant and utility catalogs next to the user’s shell:

- **Ask** — natural-language CLI help with attachable context (`@file`, selection, git, kube, history).
- **Edit** — one-shot file create/rewrite via `@@path` with unified diff + confirm.
- **Palette** — fuzzy `InputSelector` (`CTRL+SHIFT+P`) for Ask helpers, `@git`, `@kube`, `@history`.
- **AI output pane** — right-side keep-alive pane for answers, diffs, git/kube show output (not for running shell/git).
- **Safety** — secret redaction, risky-command confirms, mutate confirms for git/kube/edit.

Brand string in UI/logs: **`wezai`**. Never introduce third-party product branding in UI strings.

---

## 2. Install & load

```lua
local wezai = wezterm.plugin.require("https://github.com/wsams/wezai")
-- local wezai = wezterm.plugin.require("/absolute/path/to/wezai")

wezai.apply_to_config(config, { --[[ user options ]] })
```

WezTerm clones plugins into its cache. After local edits: sync into the cache **or** `wezterm.plugin.update_all()` then reload config.

Public entrypoint: `plugin/init.lua` → `apply_to_config(wezterm_config, user_config)`.

---

## 3. Repository layout

```
plugin/
  init.lua          -- bootstrap, keybindings, ask/edit orchestration, palette hooks
  settings.lua      -- defaults + merge (nested tables: ai_pane, history, git, kube, stats, files)
  util.lua          -- paths, files, JSON parse helpers, truncation, smart large-file read
  ui.lua            -- AI pane lifecycle, styling, InputSelector, usage banner
  session.lua       -- per-tab chat memory + history events + last edit
  shell.lua         -- shell detect, OS platform hint, risk gate, clipboard, send_command
  context.lua       -- @ / @@ parsing, redaction, request preparation
  edit.lua          -- backup, unified diff, apply/undo
  files.lua         -- fuzzy file list (fd → git ls-files → find) + @pick
  history.lua       -- fish/zsh/bash history + scrollback + session events
  git.lua           -- @git action catalog
  kube.lua          -- @kube action catalog
  palette.lua       -- unified CTRL+SHIFT+P palette
  stats.lua         -- persistent token/model usage DB
  providers/
    init.lua        -- type → backend; ask()/ready(); usage meta finalize
    proc.lua        -- curl / child_process helpers
    chat_http.lua   -- OpenAI-compatible chat completions
    gemini_api.lua  -- Google Gemini generateContent
    ollama_bin.lua  -- ollama CLI
    lms_bin.lua     -- LM Studio `lms` CLI
README.md GUIDE.md SPECS.md LICENSE
package.json .releaserc.json renovate.json
.github/workflows/release.yml
.github/workflows/renovate.yml
```

Node/`package.json` is **only** for semantic-release (not a runtime dependency of the Lua plugin).

---

## 4. Architecture rules (non-negotiable)

### 4.1 Shell pane vs AI pane

- All git/kube/history/cwd work must use the **shell** pane, never the AI output pane.
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

`settings.REPLY_CONTRACT` is appended to custom `system_prompt` if it does not already mention `"message"`.

### 4.5 Dialect + platform injection

On every ask (`with_dialect` in `init.lua`):

1. Detect shell from the **shell pane** (fish / zsh / bash / powershell), else `$SHELL`.
2. Detect OS via `wezterm.target_triple` / `uname` (macos / linux / windows).
3. Append `shell.dialect_hint` + `shell.platform_hint` to `system_prompt`.

Fish rules must forbid trailing `; end` without a block. macOS rules must forbid GNU-only flags (e.g. `du --exclude`).

Command labels print as `(fish/macos)` style when showing suggested commands.

### 4.6 Safety

- `context.redact` strips common secrets (keys, tokens, JWTs, private keys) before prompts/history.
- `shell.is_risky` + confirm before sending dangerous commands (includes kubectl mutate/exec patterns and git force/push/reset/etc.).
- Edit apply and kube mutate actions confirm unless config disables confirms.
- Kube AI helpers must prefer **read-only** next steps (get/describe/logs); never bake org-specific cluster/namespace names into the catalog.

---

## 5. Features

### 5.1 Ask (`keybinding`, default often remapped to CTRL+I by users)

Flow: `PromptInputLine` → parse refs → `context.prepare_request` → `providers.ask` → print message/command → optional `shell.send_command`.

Supports:

| Token | Behavior |
|-------|----------|
| `@path` / `@"./path with spaces"` | Attach file (read-only) |
| `@@path instruction` | Create or rewrite file (diff + confirm) |
| `@` / `@pick` / `@@` / `@@pick` | Fuzzy file picker (`files.lua`) |
| `@clipboard` / `@selection` | Clipboard / selection |
| `@git` / `@git:id` | Git picker or action (see §5.4) |
| `@kube` / `@kube:id` | Kube picker or action (see §5.5) |
| `@history` / bare history ref | History palette / attach |
| `@dir:path` | Shallow directory listing |

**Path parsing:** unquoted `@refs` strip trailing sentence punctuation (`?!. ,;:)` …) so `@package.json?` works. Quoted paths are literal.

**New files:** `@@newfile.txt …` creates if parent dir exists (`is_new`, empty original, Create confirm).

**Large `@` files:** soft budget `max_file_bytes` (default 200000). Oversized attaches use head+tail (`files.large_file = "head_tail"`) with truncation markers. `@@` edit still requires the full file under the limit.

**Share pane history:** `keybinding_with_pane` attaches scrollback to the prompt.

### 5.2 Palette (`CTRL+SHIFT+P`)

Unified fuzzy `InputSelector` with scopes:

- full (Ask helpers + git + kube + history rows)
- `git` (`CTRL+SHIFT+G`)
- `kube` (`CTRL+SHIFT+K`)
- `history` (`CTRL+SHIFT+H`) and filtered history scopes

Core palette rows include: Ask, Ask+pane, Fix last error, Explain last command, Attach/Edit file (fuzzy), Undo edit, Copy last command, Shorter re-ask, Pick model, Clear chat memory.

### 5.3 History

- Sources: fish/zsh/bash history files (tailed), optional scrollback, session events (ask/ai-cmd/edit).
- Config: `history.max_shell`, `palette_n`, `tail_bytes`, `attach_n`, `include_scrollback`, `max_session`.
- Row actions: Run / Insert / Explain / Attach & ask / Copy.

### 5.4 `@git` catalog (`git.lua`)

Kinds: `show` (print in AI pane), `shell` (run/insert in shell), `ai` (LLM with git context).

Show: `status`, `diff`, `log`, `branch`, `stash`, `remote`, `whoami`.  
Shell: rebase/soft reset/unstage/restore/latest/fetch/pull/push/pushu/sync/stash-*/switch/newbranch/add/commit/amend/identity/ignore.  
AI: `msg`, `explain`, `review`, `pr`, `resolve`, `fixup`.

Bare `@git:status` = run action; `@git:status what should I commit?` = attach + ask (via context synthetics where supported).

Always `ui.shell_pane_for` for cwd. Force git color off for AI-pane readability.

### 5.5 `@kube` catalog (`kube.lua`)

Placeholders only (`<namespace>`, `<pod>`, `<name>`, `<file>`, …) — **no** org-specific names.

- **Cluster selection is outside wezai.** Catalog commands never pass `--kubeconfig`; they use the user’s current `kubectl` context / `KUBECONFIG`. Document one example in GUIDE only; do not clutter action templates with kubeconfig flags.
- Namespace: `config.kube.namespace` or kubectl current-context namespace.
- Show: `ctx`, `ns`, `nodes`, `pods`, `pods-all`, `all`, `deploy`, `sts`, `svc`, `ing`, `cm`, `secrets` (names only), `pvc`, `events`, `top-nodes`, `top-pods`, `api-resources`, `can-i`.
- Shell: `describe`, `logs`, `logs-f`, `logs-deploy`, `exec`, `pf`, `pf-svc`, `rollout`, `restart`, `scale`, `wait`, `diff`, `apply`, `delete-f`, `get-yaml`, `use-ns`.
- AI (careful): `diagnose`, `explain-sel`, `not-ready` — gather read-only kubectl output; steer toward get/describe/logs.
- Mutate confirms when `kube.confirm_mutate` (default true).
- Ask attach tokens: `@kube:pods`, `@kube:events`, `@kube:all`, `@kube:nodes`, `@kube:ctx`.

### 5.6 Stats / usage

- DB: `~/.local/share/wezai/stats.json` (override `stats.path`; disable with `stats.enabled = false`).
- Tracks totals, per-model, last call (prompt/completion tokens, model).
- Banner on **new** AI pane create; per-turn line after each successful ask/edit.

### 5.7 Session

Per-tab: chat turns (capped by `chat_max_turns`), last question/command, last edit (for undo), history events.

---

## 6. Default keybindings

| Binding | Default | Action |
|---------|---------|--------|
| Ask | `SUPER+i` | Prompt (users often set `CTRL+i`) |
| Ask + pane history | `SUPER+I` | Prompt with scrollback |
| Palette | `CTRL\|SHIFT+p` | Full palette |
| History scope | `CTRL\|SHIFT+h` | History palette |
| Git scope | `CTRL\|SHIFT+g` | Git palette |
| Kube scope | `CTRL\|SHIFT+k` | Kube palette |

Single-letter keys are also bound with opposite case for WezTerm quirks.

---

## 7. Configuration surface

Merged in `settings.finalize`. Nested keys deep-merged: `ai_pane`, `history`, `git`, `kube`, `stats`, `files`.

Important fields (see `settings.lua` for full defaults):

| Key | Role |
|-----|------|
| `type`, `model`, `models`, `api_url`, `api_key`, `headers`, `timeout` | Provider |
| `ollama_path`, `lms_path` | CLI backends |
| `system_prompt` | Style; dialect/OS appended per request; JSON contract appended if needed |
| `max_file_bytes`, `files.*` | Attach budget + large-file policy |
| `ai_pane.*` | Split direction/size/pad |
| `backup_suffix` | Default `.wezai.bak` |
| `require_edit_confirm`, `require_risk_confirm` | Safety toggles |
| `kube.namespace`, `kube.confirm_mutate` | kubectl defaults |
| `stats.*` | Usage DB |
| `rocks_bin` | Optional luarocks LUA_PATH (rarely needed) |

---

## 8. Providers

| `type` | Module | Notes |
|--------|--------|-------|
| `http` | `providers.chat_http` | OpenAI-compatible `/v1/chat/completions` |
| `google` | `providers.gemini_api` | Gemini `generateContent` + JSON schema |
| `ollama` | `providers.ollama_bin` | `ollama run … --format json` |
| `local` | `providers.lms_bin` | `lms chat …` |

Shared transport: `providers.proc`.

---

## 9. Bootstrap / module path

WezTerm Lua has no `debug.getinfo`. `init.lua` locates the plugin dir by scanning `wezterm.plugin.list()` for fingerprint files (`settings.lua`, `stats.lua`, `providers/init.lua`, `palette.lua`) and prefers local/`wsams` clones. Then extends `package.path` for `?.lua` and `?/init.lua`.

---

## 10. Release & dependency automation

### semantic-release (direct npm — not a third-party GitHub Action wrapper)

- Workflow: `.github/workflows/release.yml` on push to `main`.
- Config: `.releaserc.json` — changelog + version bump in git + GitHub Release; **`npmPublish: false`**.
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
4. Prefer established tools (`fd`/`git`/`find`, system `diff -u`, `kubectl`) over reinvention.
5. After editing plugin Lua for local WezTerm testing, sync into WezTerm’s plugin cache or run `wezterm.plugin.update_all()` and reload.
6. Never commit secrets (API keys in `wezterm.lua` stay user-local).
7. UI copy and logs say **wezai**, not other product names.

---

## 12. Testing checklist (manual)

- [ ] Ask with `@package.json?` attaches `package.json` (punctuation stripped).
- [ ] `@pick` / palette Attach file opens fuzzy selector.
- [ ] `@@newfile.txt create lorem` creates file after Apply/Create.
- [ ] Large `@file` attaches as truncated head+tail, not hard error.
- [ ] Pick model / palette actions reuse **one** AI pane (no second split).
- [ ] Fish dialect: no bogus `; end` on one-liners; macOS: no `du --exclude`.
- [ ] `@git:status` prints in AI pane; mutating git confirms.
- [ ] `@kube:pods` / `@kube:diagnose` work with current kubectl context; mutates confirm.
- [ ] Stats banner/line appears; `~/.local/share/wezai/stats.json` updates.
- [ ] Git/kube/history always use shell cwd (not AI pane).

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
| Ask / keys / orchestration | `plugin/init.lua` |
| Defaults / merge | `plugin/settings.lua` |
| `@` parsing / prepare | `plugin/context.lua` |
| Pane / UI | `plugin/ui.lua` |
| Providers | `plugin/providers/` |
| Git / Kube catalogs | `plugin/git.lua`, `plugin/kube.lua` |
| Fuzzy files | `plugin/files.lua` |
| Usage DB | `plugin/stats.lua` |
| User docs | `README.md`, `GUIDE.md` |
