# wezai guide

Practical examples for every major surface: Ask, the palette, `@git`, `@kube`, `@tf`, `@history`, and file edits.

---

## Mental model

| Pane | Role |
|------|------|
| **Left (shell)** | Your real terminal. cwd, git repo, commands you run. Stay focused here. |
| **Right (wezai)** | Output only — answers, diffs, `git status`, terraform validate, progress. Not a shell. |

| Entry point | When to use it |
|-------------|----------------|
| `CTRL+I` | Free-form Ask (`@file`, questions, `@@` edits) |
| `CTRL+SHIFT+P` | Palette — jump to any action without typing a full Ask line |
| `CTRL+SHIFT+G` | Same palette, pre-filtered to `@git` |
| `CTRL+SHIFT+K` | Same palette, pre-filtered to `@kube` |
| `CTRL+ALT+T` | Same palette, pre-filtered to `@tf` |
| `CTRL+SHIFT+H` | Same palette, pre-filtered to `@history` |

You do **not** need `CTRL+I` before the palette. From the shell: `CTRL+SHIFT+P` → type → Enter.

---

## Ask (`CTRL+I`)

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

### Files — `@path` (read-only)

```
@README.md
```

```
@README.md is this accurate for newcomers?
```

```
@src/main.lua @src/util.lua how are these wired together?
```

Paths are relative to the pane cwd unless absolute or `~/…`.

### Edit — `@@path` (write)

Exactly **two** `@` signs, then path, then instruction:

```
@@notes.txt sort the lines alphabetically
```

```
@@config.toml add a comment above the [server] section explaining the port
```

Flow: model returns a full file → wezai shows a **unified diff** in the confirm overlay (and the right pane) → **Apply** or **Cancel**. Apply writes the file and keeps a timestamped backup such as `notes.txt.20260805-195530.wezai.bak` (configurable via `backup.*`; can be disabled).

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
| `@dir:.` | `@dir:src what modules exist?` |
| `@history` | `@history what docker commands did I run?` |
| `@history:40` | `@history:40 summarize recent work` |
| `@history:shell:30` | `@history:shell:30 which docker cmds?` |
| `@git:log30` | `@git:log30 what changed recently?` |

Bare `@git:status` / `@tf:validate` / `@history` (nothing else) run **actions** / open the palette — they do not call the model. Add a question after the token to attach + ask.

---

## Command palette (`CTRL+SHIFT+P`)

Type to fuzzy-filter. Labels start with namespaces so filtering is easy:

| You type | You see |
|----------|---------|
| `@git` | All git actions |
| `@git:soft` / `@git:rebase` | Soft reset / interactive rebase (any N) |
| `@kube` | All kubectl actions |
| `@tf` | All terraform actions |
| `@history` | Recent shell / AI commands |
| `Ask` / `Fix` / `model` | Core helpers |

### Core actions

| Palette label | What it does |
|---------------|----------------|
| **Ask…** | Same as `CTRL+I` |
| **Ask (with pane history)…** | Ask + attach scrollback |
| **Fix last error** | Diagnose selection or recent scrollback; propose a fix |
| **Explain last command** | Explain last command + output from scrollback |
| **Edit file (`@@path …`)** | Opens Ask so you can type an edit |
| **Undo last edit** | Restore last `@@` write from its backup (or in-memory prior text if backups are off) |
| **Copy last command** | Clipboard: last AI command, else shell history, else scrollback |
| **Re-ask last question (shorter)** | Same question, shorter answer |
| **Pick model…** | Switch model for next requests (`models` list) |
| **Clear chat memory** | Wipe multi-turn memory for this tab |

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
| `@git:resolve` | Help on conflicted files; optional `@@` edit |
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
| Persist in wezai config | `kube = { namespace = "kube-system" }` in `apply_to_config` |

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

> **Not seeing `@tf`?** The catalog ships in wezai ≥ 1.5.0. Run `wezterm.plugin.update_all()` (debug overlay or temporarily from config), reload WezTerm, then open the palette and type `tf`. Check the log for `wezai: load path … (tf.lua ok)`. `CTRL+SHIFT+T` is WezTerm’s **new tab** — the tf shortcut is `CTRL+ALT+T`.

Commands use the **shell pane cwd** (`terraform -chdir=…` for show/AI). wezai resolves the `terraform` binary the same way as kubectl (Homebrew/asdf/mise + login shell), or set `tf.terraform = "/usr/local/bin/terraform"`.

**Mutating** actions (`apply`, `destroy`, `import`, `state-rm`) confirm when `tf.confirm_mutate` is true (default). `unlock` (`force-unlock`) always confirms. AI helpers gather read-only context and steer toward validate / fmt / plan / `@@` edits — not apply/destroy.

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

## `@history`

Recent shell history (fish / zsh / bash), scrollback, and wezai session events appear as `@history …` rows in the palette.

1. `CTRL+SHIFT+P` → type `@history` or `docker`  
2. Pick a row  
3. Choose: **Run** / **Insert** / **Explain** / **Attach & ask** / **Copy**

| You type in Ask | Result |
|-----------------|--------|
| `@history` alone | Palette scoped to history |
| `@history:failed` | Rows near error-looking output |
| `@history:shell` / `@history:ai` | Filter by source |
| `@history:40` | Attach last 40 entries (any positive N) |
| `@history:shell:40` / `@history:failed:20` | Filter + limit |
| `@history how did I deploy?` | Attach history chunk + ask |
| `@history:shell:30 what docker cmds?` | Attach 30 shell rows + ask |

History files are read from the **tail** only (default last 4 MiB). Fuzzy filter applies to the rows loaded into the palette (`palette_n`), not your entire lifetime history.

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
CTRL+I → @@scripts/bootstrap.sh make this idiomatic fish and add set -e
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

Then write it with `@@main.tf …` after reviewing the suggestion.

---

## Safety

- Secrets (API keys, tokens, private keys) are redacted before send / memory  
- Risky shell commands confirm before send (includes `terraform apply` / `destroy` / `force-unlock`)  
- `@@` edits always show a unified diff in the confirm overlay unless you disable `require_edit_confirm`  
- Edit backups are timestamped (`backup.suffix` / `backup.dir`); set `backup.enabled = false` to skip writing `.bak` files  
- No force-push action in v1  
- `@git:latest` uses `--ff-only` only  
- Terraform AI helpers prefer validate/fmt/plan — not apply/destroy  

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `no pane cwd` | Focus the **shell** pane, not the wezai pane; then open the palette again |
| Two right panes | Close extras; reload config — wezai reattaches one output pane |
| Palette is WezTerm’s, not wezai | Reload config; wezai overrides `CTRL+SHIFT+P`. Or set `keybinding_palette` |
| Empty `@history` | Run commands in fish/zsh/bash first; check `history.tail_bytes` / `palette_n` |
| No `@tf` in palette | Need wezai ≥ 1.5.0 with `plugin/tf.lua`. `wezterm.plugin.update_all()` then reload. Log should say `tf.lua ok`. Shortcut is `CTRL+ALT+T` (not `CTRL+SHIFT+T`) |
| Plugin not loading | `require` local path or publish URL; ensure cache has `plugin/palette.lua` |

---

## See also

- [README.md](README.md) — install & config overview  
- [LICENSE](LICENSE) — MIT  
