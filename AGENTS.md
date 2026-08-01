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

## Related pitfalls

- Plugin modules load via fingerprint scan in `init.lua`. Prefer the **most complete** install (`tf.lua`, etc.) so a stale local checkout cannot hide new catalogs.
- After merging catalog work to GitHub installs: users need `wezterm.plugin.update_all()` + config reload. Log line should include `tf.lua ok` when present.
- Shell vs AI pane, provider contract, and safety rules: see SPECS §4.
