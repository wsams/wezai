# Agent notes for wezai

Canonical product/behavior spec: **[SPECS.md](SPECS.md)**. User docs: [README.md](README.md), [GUIDE.md](GUIDE.md).

---

## Reserved WezTerm shortcuts — do not bind

WezTerm owns several default key assignments. **Never** bind wezai actions to these unless the change explicitly documents stealing them and updates README/GUIDE/SPECS.

### `CTRL+SHIFT+T` is reserved

| Shortcut | Owner | Meaning |
|----------|--------|---------|
| **`CTRL+SHIFT+T`** | **WezTerm (reserved)** | **`SpawnTab`** — open a new tab |

Do **not** use `CTRL+SHIFT+T` (or `key = "t", mods = "CTRL|SHIFT"`) for wezai — including `@tf`, palette scopes, or any new catalog.

- Terraform palette default is **`CTRL+ALT+T`** (`keybinding_tf` in `settings.lua`).
- If you add another `T`-based binding, keep it off `CTRL|SHIFT`.

Other WezTerm defaults to treat carefully when picking shortcuts (non-exhaustive): `CTRL+SHIFT+W` (close tab), `CTRL+SHIFT+F` (search), `CTRL+SHIFT+P` (wezai already overrides for its palette — do not casually reassign).

---

## Keybinding checklist (before shipping a new shortcut)

1. Check [WezTerm default keys](https://wezterm.org/config/default-keys.html) for conflicts.
2. Prefer `CTRL|SHIFT` + a free letter for catalog scopes (`G` git, `K` kube, `H` history) — **not `T`**.
3. Update `settings.lua` defaults, `init.lua` bind site, and README / GUIDE / SPECS tables together.
4. Call out any intentional override of a WezTerm default in those docs.

---

## Local HTTP / Ollama pitfalls

Ask and `@@` edit **require** a JSON object reply (SPECS §4.4). That is not optional style — parsers hard-fail without it.

### Prefer instruct models over “thinking” models

wezai is a **structured-output** client (`message` + `command`, or `message` + `file` for edits). Models that spend hundreds/thousands of tokens on chain-of-thought (e.g. OpenAI `gpt-oss:*`, other “thinking” GGUFs) often:

- wrap JSON in prose → `Failed to parse JSON response` (mitigated somewhat by `util.extract_json_object`, not a cure)
- invent field names (`content` instead of `file`) → edit errors
- burn long completion budgets on tiny prompts

Prefer instruction-tuned chat/coder models that follow “JSON only” (e.g. `qwen2.5:14b`, `qwen2.5-coder:14b`). Do **not** “fix” thinking-model flakiness by removing the JSON contract from `system_prompt` — Ask/Edit still need it. Custom style prompts are fine; `settings.finalize` appends `REPLY_CONTRACT` when `"message"` is absent. `@@` edit **ignores** user `system_prompt` and uses `context.EDIT_SYSTEM_PROMPT`.

### `timeout` vs cold model load

Default `timeout` is **120s** (`settings.lua`). For large local models over `type = "http"` (Ollama OpenAI-compatible `/v1/chat/completions`):

1. `/api/tags` can be instant while chat is still **0 bytes** until `llama-server` finishes load + warmup.
2. curl `--max-time` disconnect mid-load → Ollama logs `client connection closed before llama-server finished loading` and **aborts** the load.
3. Next request is cold again — so a too-short timeout looks like “it never warms.”

Raise `timeout` to **300–600** for big local GGUFs, or pre-warm (`ollama run …` / generate with `keep_alive`). `chat_http` appends a hint when curl reports a timeout.

### Config reload / local checkout

- Prefer `plugin.require("/absolute/path/to/wezai")` while developing; **do not** call `wezterm.plugin.update_all()` on every reload.
- GitHub installs: run `update_all()` once after pulling, then reload.

---

## Related pitfalls

- Plugin modules load via fingerprint scan in `init.lua`. Prefer the **most complete** install (`tf.lua`, etc.) so a stale local checkout cannot hide new catalogs.
- After merging catalog work to GitHub installs: users need `wezterm.plugin.update_all()` + config reload. Log line should include `tf.lua ok` when present.
- Shell vs AI pane, provider contract, and safety rules: see SPECS §4.
