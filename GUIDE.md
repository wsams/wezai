# wezai guide

Practical examples for every major surface: Ask, the palette, `@git`, `@kube`, `@tf`, `@docker`, `@weather`, `@history`, and file edits.

---

## Mental model

| Pane | Role |
|------|------|
| **Left (shell)** | Your real terminal. cwd, git repo, commands you run. Stay focused here. |
| **Right (wezai)** | Output only — answers, diffs, `git status`, terraform validate, docker ps, weather, progress. Not a shell. While Ask/Edit or a catalog command waits, this pane scrolls a spinner / timed status so it does not look frozen. |

| Entry point | When to use it |
|-------------|----------------|
| `CTRL+I` | Free-form Ask (`@file`, `@dir/`, questions, `#` edits). Composer keeps the AI log visible |
| `CTRL+SHIFT+P` | Palette — jump to any action without typing a full Ask line |
| `CTRL+SHIFT+G` | Same palette, pre-filtered to `@git` |
| `CTRL+SHIFT+K` | Same palette, pre-filtered to `@kube` |
| `CTRL+SHIFT+D` | Same palette, pre-filtered to `@docker` |
| `CTRL+ALT+T` | Same palette, pre-filtered to `@tf` |
| `CTRL+ALT+W` | Same palette, pre-filtered to `@weather` |
| `CTRL+SHIFT+H` | Same palette, pre-filtered to `@history` |

You do **not** need `CTRL+I` before the palette. From the shell: `CTRL+SHIFT+P` → type → Enter.

---

## Ask (`CTRL+I`)

CTRL+I splits a **composer** under your shell. The right-hand wezai pane stays visible so you can copy from the last answer. Esc saves a draft; the next CTRL+I restores it. Type `@` or `#` to fuzzy-complete files and directories in the cwd — or start a path with `~/`, `/`, `./`, or `../` to list outside the cwd.

Pinned `@` / `#` files stay in context for follow-up questions until you **Clear**. **Compact** (palette, or type `compact`) shrinks the conversation and sticky selections but keeps those file refs.

### Plain questions

```
how do I list listening ports on macOS?
```

```
fish: recursively find files larger than 100M
```

### Selection

1. Select an error in the terminal  
2. `CTRL+I`  
3. Enter alone → explain/diagnose  
4. Or type: `what does this exit code mean?`

### Files — `@path` (read-only, pinned)

```
@README.md
```

```
@README.md is this accurate for newcomers?
```

```
@src/main.lua @src/util.lua how are these wired together?
```

```
@plugin/
how does module loading work?
```

`@directory/` walks the tree (skips `node_modules`, `.git`, wezai backups) and attaches source-like files up to the token budget. Huge packs ask for confirmation.

Paths are relative to the pane cwd unless absolute, `~/…`, or `../…`. File pins last until Clear. Composer and `@pick` can fuzzy-filter those outside-cwd forms too.

### Edit — `#path` (write)

`#` then path, then instruction (`@@path` still works):

```
#notes.txt sort the lines alphabetically
```

```
#config.toml add a comment above the [server] section explaining the port
```

```
#plugin/init.lua
```

The last form **pins** the file for edit; the next CTRL+I question is applied to it.

`#plugin/` pins every attachable file under that directory as edit targets (multi-file apply + one confirm).

Flow: model returns full file(s) → wezai prints a **unified diff** in the **right-hand pane** → a confirm split opens **under the shell** (the overlay no longer covers the diff) → **Apply** or **Cancel**. Apply writes the file and keeps a timestamped **dotfile** backup such as `.notes.txt.20260805-195530.wezai.bak` (searchable `*wezai*.bak`; configurable via `backup.*`; can be disabled).

Undo: palette → **Undo last edit**.

### Context tokens

| Token | Example |
|-------|---------|
| `@clipboard` | `@clipboard summarize this` |
| `@selection` | `@selection fix this error` |
| `@git:status` | `@git:status what should I commit?` |
| `@git:diff` | `@git:diff write a PR summary` |
| `@tf:state` | `@tf:state what’s orphaned?` |
| `@tf:validate` | `@tf:validate why is this failing?` |
| `@docker:ps` | `@docker:ps what’s using port 5432?` |
| `@weather:now` | `@weather should I bring a jacket?` |
| `@dir:.` | `@dir:src what modules exist?` |
| `@history` | `@history what docker commands did I run?` |
| `@history:40` | `@history:40 summarize recent work` |
| `@history:shell:30` | `@history:shell:30 which docker cmds?` |
| `@git:log30` | `@git:log30 what changed recently?` |

Bare `@git:status` / `@tf:validate` / `@history` (nothing else) run **actions** / open the palette — they do not call the model. Add a question after the token to attach + ask.

---

## Command palette (`CTRL+SHIFT+P`)

Palette titles and the AI output pane show the installed wezai version (bundled `plugin/version.lua`, plus a short git sha when the checkout is visible — e.g. `wezai v1.10.0+fc6d5b5`). After **Update wezai plugin** (or `wezterm.plugin.update_all()` + config reload), that label should change so you can confirm you pulled the new checkout. If you ever saw `wezai ?`, the plugin Lua loaded but `package.json` / git were not on the path (common on Flatpak / Bazzite); current wezai ships `version.lua` next to the Lua modules so the semver still shows.

Type to fuzzy-filter. Labels start with namespaces so filtering is easy:

| You type | You see |
|----------|---------|
| `@git` | All git actions |
| `@git:soft` / `@git:rebase` | Soft reset / interactive rebase (any N) |
| `@kube` | All kubectl actions |
| `@tf` | All terraform actions |
| `@docker` | Docker / Compose actions |
| `@weather` | Open-Meteo current / forecast / set zip |
| `@history` | Unique shell history (detected fish/zsh/bash), type to fuzzy-filter |
| `Ask` / `Fix` / `model` | Core helpers |

### Core actions

| Palette label | What it does |
|---------------|----------------|
| **Ask…** | Same as `CTRL+I` |
| **Ask (with pane history)…** | Ask + attach scrollback |
| **Fix last error** | Diagnose selection or recent scrollback; propose a fix |
| **Explain last command** | Explain last command + output from scrollback |
| **Edit file (`#path …`)** | Opens Ask so you can type an edit |
| **Undo last edit** | Restore last `#` write from its wezai backup (or in-memory prior text if backups are off) |
| **Copy last command** | Clipboard: last AI command, else shell history, else scrollback |
| **Re-ask last question (shorter)** | Same question, shorter answer |
| **Pick model…** | Switch model for next requests (`models` list / `WEZAI_MODELS`) |
| **Compact chat (keep @/# files)** | Shrink conversation + sticky selection; keep pinned files |
| **Clear chat + file context** | Wipe turns, selections, drafts, and `@`/`#` pins |
| **Show wezai install** | Version + `plugin_dir` / git cache path |
| **Update wezai plugin** | `git fetch` + `pull --ff-only` in the wezai checkout, then `wezterm.plugin.update_all()` + reload |

---

## `@git` actions

Open via `CTRL+SHIFT+P` → `@git`, or `CTRL+SHIFT+G`, or Ask → `@git` / `@git:status`.

Mutating actions confirm, then run in your **shell** pane. Inspect actions print in the **wezai** pane (default terminal colors).

### Show (no model)

| Action | Example / meaning |
|--------|-------------------|
| `@git:status` | `git status -sb` |
| `@git:diff` | Staged + worktree diff |
| `@git:log` / `@git:logN` | Last 15 commits (or N, e.g. `@git:log30`) |
| `@git:branch` | `git branch -vv` |
| `@git:stash` | `git stash list` |
| `@git:remote` | `git remote -v` |
| `@git:whoami` | `user.name` / `user.email` |

### Everyday shell shortcuts

| Action | Runs |
|--------|------|
| `@git:rebaseN` | `git rebase -i HEAD~N` (any positive N, e.g. `@git:rebase15`) |
| `@git:softN` | `git reset --soft HEAD~N` (any positive N, e.g. `@git:soft1`) |
| `@git:unstage` | Pick staged files → `git restore --staged …` |
| `@git:restore` | Pick a file → discard worktree changes |
| `@git:latest` | Checkout default branch + `pull --ff-only` |
| `@git:fetch` | `git fetch --all --prune` |
| `@git:pull` | `git pull --ff-only` |
| `@git:push` / `@git:pushu` | `git push` / `push -u origin HEAD` |
| `@git:sync` | Fetch, then show status |
| `@git:stash-push` / `@git:stash-pop` | Stash push `-u` / pop |
| `@git:switch` | Prompt → `git switch <branch>` |
| `@git:newbranch` | Prompt → `git switch -c <name>` |
| `@git:add` | `git add -A` (confirm) |
| `@git:commit` | `git commit` (your editor) |
| `@git:amend` | `git commit --amend --no-edit` |
| `@git:identity` | Set global `user.name` / `user.email` |
| `@git:ignore` | Append a pattern to `.gitignore` |

### AI-assisted git

| Action | What you get |
|--------|----------------|
| `@git:msg` | Conventional commit from **staged** diff; suggests `git commit -m "…"` |
| `@git:explain` | Plain-English status + diff |
| `@git:review` | Bugs / secrets / missing tests |
| `@git:pr` | PR title + bullets vs default branch |
| `@git:resolve` | Help on conflicted files; optional `#` edit |
| `@git:fixup` | Suggested clean-up sequence for a dirty tree |

Extra instruction after the action:

```
@git:msg make the subject under 50 chars
```

```
@git:pr emphasize the migration risk
```

### Bare vs ask-with-context

| You type | Result |
|----------|--------|
| `@git:status` | Show status (no LLM) |
| `@git:status what should I stage?` | Attach status + ask the model |
| `@git` alone | Open palette scoped to git |

---

## `@kube` actions

Open via `CTRL+SHIFT+P` → `@kube`, or `CTRL+SHIFT+K`, or Ask → `@kube` / `@kube:pods`.

Commands use whatever cluster **`kubectl` already points at** (current context). wezai never adds `--kubeconfig` to catalog commands — switch clusters yourself before running `@kube` actions.

Show/AI actions run `kubectl` from WezTerm’s process (not your shell pane). If WezTerm was opened from Dock/Spotlight, its PATH may miss Homebrew/Docker — wezai resolves common install locations, or set `kube.kubectl = "/usr/local/bin/kubectl"` explicitly.

**Namespace (pick one):**

| How | Example |
|-----|---------|
| Per action (one-shot) | Ask → `@kube:pods kube-system` or `@kube:pods/kube-system` |
| All namespaces | `@kube:pods -A` or `@kube:pods-all` |
| Persist in kubectl | `@kube:use-ns kube-system` (sets current-context namespace) |
| Persist in wezai config | `WEZAI_KUBE_NS=kube-system` in `wezai.env`, or `kube = { namespace = "kube-system" }` |

Default is the kubectl current-context namespace (`default` on docker-desktop unless you change it). Placeholders like `<pod>` / `<file>` are prompted. **Mutating** actions (`apply`, `delete-f`, `restart`, `scale`) always confirm. AI helpers only gather read-only output (`get` / events) and steer toward safe next steps.

Attach in a question: `@kube:pods/kube-system what’s crashlooping?`

**Switching clusters (you do this, not wezai):**

```fish
# one-off
kubectl --kubeconfig ./path/to/kubeconfig get nodes

# or for the session / shell
set -x KUBECONFIG ./path/to/kubeconfig
kubectl config use-context <context-name>
```

### Show (no model)

| Action | Meaning |
|--------|---------|
| `@kube:ctx` | Current context + namespace + `get-contexts` |
| `@kube:ns` | List namespaces |
| `@kube:nodes` | `get nodes -o wide` |
| `@kube:pods` / `@kube:pods-all` | Pods in current ns / all ns |
| `@kube:all` | `get all` (current ns) |
| `@kube:deploy` / `sts` / `svc` / `ing` / `cm` / `pvc` | Common resources |
| `@kube:secrets` | Secret **names** only |
| `@kube:events` | Events sorted by time |
| `@kube:top-nodes` / `top-pods` | Metrics (needs metrics-server) |
| `@kube:can-i` | `auth can-i --list` |

### Shell helpers

| Action | Notes |
|--------|--------|
| `@kube:describe` / `logs` / `logs-f` / `logs-deploy` | Prompt for names; logs accept `--tail` N (`@kube:logs500`) |
| `@kube:exec` / `pf` / `pf-svc` | Interactive / port-forward |
| `@kube:rollout` / `restart` / `scale` / `wait` | Rollout + wait; mutate confirms |
| `@kube:diff` / `apply` / `delete-f` | Manifest workflows (confirm mutates) |
| `@kube:use-ns` | `config set-context --current --namespace=…` |

### Careful AI

| Action | What it does |
|--------|----------------|
| `@kube:diagnose` | Attach pods + events (+ selection) → diagnose; prefers get/describe/logs |
| `@kube:explain-sel` | Explain selected kubectl error/output |
| `@kube:not-ready` | Focus on pods that aren’t Ready |

Ask-with-context attach tokens: `@kube:pods`, `@kube:events`, `@kube:all`, `@kube:nodes`, `@kube:ctx`.

---

## `@tf` actions

Open via `CTRL+SHIFT+P` → type `@tf`, or `CTRL+ALT+T`, or Ask → `@tf` / `@tf:validate`.

> **Not seeing `@tf`?** The catalog ships in wezai ≥ 1.5.0. Palette → **Update wezai plugin** (or `wezterm.plugin.update_all()` from the debug overlay), then type `tf`. Check the log for `wezai: load path … (tf.lua ok)`. `CTRL+SHIFT+T` is WezTerm’s **new tab** — the tf shortcut is `CTRL+ALT+T`.

Commands use the **shell pane cwd** (`terraform -chdir=…` for show/AI). wezai resolves the `terraform` binary the same way as kubectl (Homebrew/asdf/mise + login shell), or set `tf.terraform = "/usr/local/bin/terraform"`.

**Mutating** actions (`apply`, `destroy`, `import`, `state-rm`) confirm when `tf.confirm_mutate` is true (default). `unlock` (`force-unlock`) always confirms. AI helpers gather read-only context and steer toward validate / fmt / plan / `#` edits — not apply/destroy.

### Show (no model)

| Action | Meaning |
|--------|---------|
| `@tf:version` | `terraform version` |
| `@tf:validate` | `terraform validate -no-color` |
| `@tf:providers` | `terraform providers` |
| `@tf:workspace` / `ws` | Current workspace + list |
| `@tf:state` | `terraform state list` |
| `@tf:output` | `terraform output` |
| `@tf:fmt-check` | `terraform fmt -check -diff -recursive` |

### Shell helpers (no model)

| Action | Notes |
|--------|--------|
| `@tf:init` / `fmt` / `plan` | Everyday workflow |
| `@tf:apply` / `destroy` | Confirm before run |
| `@tf:refresh` | `apply -refresh-only` |
| `@tf:import` | Prompts for address + id |
| `@tf:workspace-select` / `workspace-new` | Optional name after the action |
| `@tf:state-rm` | Remove from state only (confirm) |
| `@tf:unlock` | `force-unlock <LOCK_ID>` (always confirm) |

### AI — generate & debug

| Action | What it does |
|--------|----------------|
| `@tf:generate …` | Generate HCL from a description (+ existing `*.tf` context) |
| `@tf:debug` | Diagnose selection/scrollback + validate/state/sources |
| `@tf:explain` | Explain selection or cwd sources |
| `@tf:review` | Bugs / insecure defaults / missing providers |

```
CTRL+ALT+T → @tf:validate
CTRL+I → @tf:generate S3 bucket with versioning and block public access
CTRL+I → @tf:debug   (after a failed plan — select the error first)
```

Ask-with-context attach tokens: `@tf:state`, `@tf:validate`, `@tf:output`, `@tf:workspace`, `@tf:providers`, `@tf:sources`.

---

## `@docker` actions

Open via `CTRL+SHIFT+P` → type `@docker`, or `CTRL+SHIFT+D`, or Ask → `@docker` / `@docker:ps`.

Commands use the **shell pane cwd** for Compose (`docker compose` in that directory). wezai resolves the `docker` binary the same way as kubectl/terraform (Homebrew + login shell), or set `docker.docker = "/usr/bin/docker"`.

**Mutating** actions (`restart`, `rm`, `compose-down`) confirm when `docker.confirm_mutate` is true (default). AI helpers gather read-only context (ps / compose ps / selection) and steer toward logs / inspect — not `rm` / `compose down` unless you asked.

### Show (no model)

These print the command in the wezai pane immediately, then a spinner until docker returns.

| Action | Meaning |
|--------|---------|
| `@docker:ps` | Running containers |
| `@docker:ps-a` | All containers (`ps -a`) |
| `@docker:images` | Local images |
| `@docker:compose-ps` | `docker compose ps` in the shell cwd |
| `@docker:df` | `docker system df` |

### Shell helpers

| Action | Notes |
|--------|--------|
| `@docker:logs` / `logs-f` | Prompt for container; `--tail=N` via `@docker:logs200` |
| `@docker:exec` | `docker exec -it <container> sh` |
| `@docker:compose-up` / `compose-down` | Detached up; down confirms |
| `@docker:compose-logs` | Compose logs `--tail=N` |
| `@docker:pull` | Prompt for image |
| `@docker:restart` / `rm` | Confirm before run |

### AI

| Action | What it does |
|--------|----------------|
| `@docker:diagnose` | Attach `ps -a` + compose ps (+ selection) → diagnose |
| `@docker:explain-sel` | Explain selected docker/compose output |

```
CTRL+SHIFT+D → @docker:ps
CTRL+I → @docker:ps what's using 5432?
CTRL+I → @docker:diagnose   (select a crash log first)
```

Ask-with-context attach tokens: `@docker:ps`, `@docker:ps-a`, `@docker:images`, `@docker:compose-ps`, `@docker:df`. Bare `@docker` opens the palette. `@docker should I restart?` attaches `ps`.

---

## `@weather` actions

Open via `CTRL+SHIFT+P` → type `@weather`, or `CTRL+ALT+W`, or Ask → `@weather` / `@weather:now`.

Forecast comes from **Open-Meteo** (no API key). You only need a ZIP / postal code.

**Set the zip from the plugin** (this is the intended way to change it later):

```
CTRL+ALT+W → @weather:zip
```

Enter `90210`, or `90210, US`, or `M5V 2T6, CA`. wezai geocodes it, then saves `~/.local/share/wezai/weather.json`. That overlay **overrides** `weather.zip` in `wezterm.lua` and survives reloads. It does **not** rewrite your WezTerm config.

Optional seed before the first `@weather:zip` — prefer `WEZAI_WEATHER_ZIP` in `~/.config/wezterm/wezai.env` (Flatpak/Bazzite GUI apps often miss `.bashrc` env):

```bash
WEZAI_WEATHER_ZIP=90210
WEZAI_WEATHER_COUNTRY=US
WEZAI_WEATHER_UNITS=auto
```

Lua still works if you want it in `wezterm.lua`: `weather = { zip = "90210", country = "US", units = "auto" }`.

`@weather:zip clear` (or `none`) drops the overlay so the wezterm.lua value applies again. `@weather:where` shows effective zip, overlay vs config, and resolved place.

`CTRL+SHIFT+W` is WezTerm’s **close tab** — the weather shortcut is `CTRL+ALT+W`.

### Show (no model)

These print the command in the wezai pane immediately, then a spinner until the forecast (or geocode) returns.

| Action | Meaning |
|--------|---------|
| `@weather:now` | Current conditions, next hours, today/tomorrow |
| `@weather:forecast` | Current + 7-day daily |
| `@weather:where` | Configured zip / resolved coordinates |

### Config from the plugin

| Action | Notes |
|--------|--------|
| `@weather:zip` | Prompt for postal code |
| `@weather:zip 90210` | One-shot set |

```
CTRL+ALT+W → @weather:now
CTRL+I → @weather should I bring a jacket?
CTRL+I → @weather:forecast what’s the weekend look like?
```

Bare `@weather` opens the weather palette. Add a question after `@weather` / `@weather:now` / `@weather:forecast` to attach conditions and ask the model.

---

## `@history`

The history palette uses the **detected shell** (fish / zsh / bash) with the same actions on those shells.

1. `CTRL+SHIFT+H` (or `CTRL+SHIFT+P` → type `@history`)  
2. Type to fuzzy-filter unique commands (newest first)  
3. Pick a row → **Run** / **Insert** / **Explain** / **Attach & ask** / **Copy** / **Delete**

PowerShell (and unknown shells) still list scrollback / session events, but histfile search and **Delete** are not offered.

**Search:** the history-scoped palette loads up to `search_n` unique commands (default 12 000) so WezTerm’s fuzzy matcher can reach far back. For the rest of a huge histfile, pick **Search entire history…** and type a query (`fzf -f` if installed, otherwise subsequence matching). The unified `CTRL+SHIFT+P` list stays at `palette_n` (200) recent rows.

**Delete** removes **all copies** of that command, like fish’s history pager:

- **fish** — `history delete --exact --case-sensitive` in the live pane (session + `fish_history`)
- **bash** — `history -a`, rewrite `HISTFILE`, `history -c && history -r`
- **zsh** — `fc -W`, rewrite `HISTFILE`, `fc -p`

| You type in Ask | Result |
|-----------------|--------|
| `@history` alone | Palette scoped to history |
| `@history:failed` | Rows near error-looking output |
| `@history:shell` / `@history:ai` | Filter by source |
| `@history:40` | Attach last 40 entries (any positive N) |
| `@history:shell:40` / `@history:failed:20` | Filter + limit |
| `@history how did I deploy?` | Attach history chunk + ask |
| `@history:shell:30 what docker cmds?` | Attach 30 shell rows + ask |

Histfiles are read from the **tail** (default last 8 MiB) and **deduplicated newest-first**. On Linux, bash/zsh `HISTFILE` is taken from the pane process environment when `/proc/pid/environ` is readable.

---
---

## Recipes

### “What’s dirty and what should I commit?”

```
CTRL+SHIFT+G → @git:status
CTRL+SHIFT+G → @git:diff
CTRL+I → @git:status @git:diff suggest a commit message
```

Or stage, then:

```
CTRL+SHIFT+G → @git:msg
```

### “Interactive rebase last N commits”

```
Ask / palette → @git:rebase15 → confirm
```

Or pick `@git:rebase` from the palette and enter `15` when prompted. Editor opens in your shell pane.

### “Undo my last commit but keep the changes”

```
Ask / palette → @git:soft1 → confirm
```

Or pick `@git:soft` and enter `1` when prompted.

### “New laptop — set git identity”

```
CTRL+SHIFT+G → @git:identity
```

Enter name, then email (global config).

### “Explain this stack trace”

Select the trace → `CTRL+I` → Enter  
or palette → **Fix last error**

### “Rewrite a messy file”

```
CTRL+I → #scripts/bootstrap.sh make this idiomatic fish and add set -e
```

Review the diff → Apply.

### “Re-run that kubectl from earlier”

```
CTRL+SHIFT+H → type kubectl → pick row → Insert (edit) or Run
```

### “Validate and debug this Terraform module”

```
CTRL+ALT+T → @tf:validate
CTRL+ALT+T → @tf:plan
# select the error output, then:
CTRL+ALT+T → @tf:debug
```

Or generate new HCL:

```
CTRL+I → @tf:generate aws_s3_bucket with versioning enabled
```

Then write it with `#main.tf …` after reviewing the suggestion.

### “What's running locally?”

```
CTRL+SHIFT+D → @docker:ps
CTRL+I → @docker:ps what's using 5432?
```

Or diagnose a crash (select the log first):

```
CTRL+SHIFT+D → @docker:diagnose
```

### “What's the weather?”

```
CTRL+ALT+W → @weather:zip     # once — e.g. 90210
CTRL+ALT+W → @weather:now
```

Or attach it to a question:

```
CTRL+I → @weather should I bring a jacket tonight?
```

---

## Safety

- Secrets (API keys, tokens, private keys) are redacted before send / memory  
- Risky shell commands confirm before send (includes `terraform apply` / `destroy` / `force-unlock` and `docker rm` / `compose down`)  
- `#` / `@@` edits always show a unified diff in the right-hand pane, with Apply/Cancel in a shell split (not a full-window overlay) unless you disable `require_edit_confirm`  
- Edit backups are timestamped wezai **dotfiles** (`backup.suffix` / `backup.dir` / `backup.dotfile`); set `backup.enabled = false` to skip writing `.bak` files  
- No force-push action in v1  
- `@git:latest` uses `--ff-only` only  
- Terraform AI helpers prefer validate/fmt/plan — not apply/destroy  

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `no pane cwd` | Focus the **shell** pane, not the wezai pane; then open the palette again |
| Overlay covers the diff / right pane | Edit confirm should split under the shell. Palette → **Update wezai plugin**. Fallback InputSelector (no python3) still covers the tab. |
| Composer/confirm is a full-window overlay | Needs `python3` plus `plugin/composer.py` / `confirm.py`. The AI pane prints a warning; overlay still works. |
| Palette is WezTerm’s, not wezai | Reload config; wezai overrides `CTRL+SHIFT+P`. Or set `keybinding_palette` |
| Empty `@history` | Run commands in fish/zsh/bash first; check `history.tail_bytes` / `search_n`. Bash often needs `histappend` (or a `history -a` in `PROMPT_COMMAND`) so the current session is on disk. |
| `@history` says histfile unsupported | PowerShell (and unknown shells) have no histfile search/delete. Scrollback and session events still list. Use fish/zsh/bash for Delete. |
| No `@tf` in palette | Need wezai ≥ 1.5.0 with `plugin/tf.lua`. Palette → **Update wezai plugin**, then reload. Log should say `tf.lua ok`. Shortcut is `CTRL+ALT+T` (not `CTRL+SHIFT+T`) |
| No `@docker` in palette | Need `plugin/docker.lua`. Palette → **Update wezai plugin**, then reload. Log should say `docker.lua ok`. Shortcut is `CTRL+SHIFT+D`. |
| No `@weather` / “No zip set” | Need `plugin/weather.lua`. Set `@weather:zip 90210` or `WEZAI_WEATHER_ZIP=90210` in `wezai.env`. Shortcut is `CTRL+ALT+W` (not `CTRL+SHIFT+W`) |
| Palette title is `wezai ?` | Stale plugin without `plugin/version.lua`. Palette → **Update wezai plugin**; log should show `wezai v1.12.0…` not `?` |
| Config error `yield across a C-call boundary` | Load-time process spawn (fixed after 1.12.0). Palette is unavailable — `git fetch` in the WezTerm plugin cache (see README Troubleshooting), then reload |
| Plugin not updating / still looks old | Palette → **Show wezai install** (path + version) then **Update wezai plugin**. If `require` fails, fetch in the cache dir (README) |
| Plugin not loading | `require` local path or publish URL; ensure cache has `plugin/palette.lua` |
| Env vars from `.bashrc` ignored | GUI / Flatpak WezTerm (Bazzite) often has a tiny environment. Put keys in `~/.config/wezterm/wezai.env` instead |

---

## See also

- [README.md](README.md) — install & config overview  
- [LICENSE](LICENSE) — MIT  
