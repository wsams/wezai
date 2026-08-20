local wezterm = require("wezterm")
local util = require("util")
local ui = require("ui")
local session = require("session")
local confirm = require("confirm")

local M = {}

local DEFAULT_SUFFIX = ".wezai.bak"
local DIFF_PREVIEW_MAX = 80
-- Default backup name: `.notes.txt.20260819-040305.wezai.bak` (dotfile, searchable `*wezai*`).

--- Normalize backup settings from nested `backup.*` and legacy `backup_suffix`.
function M.backup_opts(config)
    config = config or {}
    local b = type(config.backup) == "table" and config.backup or {}
    local enabled = b.enabled
    if enabled == nil then
        enabled = true
    end
    local suffix = b.suffix
    if suffix == nil or suffix == "" then
        suffix = config.backup_suffix
    end
    if suffix == nil or suffix == "" then
        suffix = DEFAULT_SUFFIX
    end
    local dir = b.dir
    if type(dir) == "string" and dir ~= "" then
        dir = util.expand_path(dir, nil) or dir
    else
        dir = nil
    end
    local dotfile = b.dotfile
    if dotfile == nil then
        dotfile = true
    end
    return {
        enabled = enabled and true or false,
        suffix = suffix,
        dir = dir,
        dotfile = dotfile and true or false,
    }
end

local function timestamp_slug()
    return os.date("%Y%m%d-%H%M%S")
end

local function backup_filename(base, ts, suffix, n, dotfile)
    local extra = ""
    if n and n > 1 then
        extra = "-" .. tostring(n)
    end
    local name = base .. "." .. ts .. extra .. suffix
    if dotfile and name:sub(1, 1) ~= "." then
        name = "." .. name
    end
    return name
end

--- Build a unique backup path. Default: sibling dotfile `.name.<timestamp>.wezai.bak`.
function M.backup_path_for(path, config, ts)
    local opts = M.backup_opts(config)
    if not opts.enabled then
        return nil
    end
    ts = ts or timestamp_slug()
    local base = util.basename(path)
    local name = backup_filename(base, ts, opts.suffix, nil, opts.dotfile)
    local candidate
    if opts.dir and opts.dir ~= "" then
        local dir = opts.dir:gsub("[/\\]+$", "")
        candidate = dir .. util.separator .. name
    else
        local parent = util.dirname(path)
        if parent and parent ~= "" then
            candidate = parent .. util.separator .. name
        else
            candidate = name
        end
    end
    -- Rare same-second collision: append -2, -3, …
    if not util.path_exists_as_file(candidate) then
        return candidate
    end
    local n = 2
    while n < 100 do
        local alt_name = backup_filename(base, ts, opts.suffix, n, opts.dotfile)
        local alt
        if opts.dir and opts.dir ~= "" then
            local dir = opts.dir:gsub("[/\\]+$", "")
            alt = dir .. util.separator .. alt_name
        else
            local parent = util.dirname(path)
            if parent and parent ~= "" then
                alt = parent .. util.separator .. alt_name
            else
                alt = alt_name
            end
        end
        if not util.path_exists_as_file(alt) then
            return alt
        end
        n = n + 1
    end
    return candidate
end

local function backup_label(config)
    local opts = M.backup_opts(config)
    if not opts.enabled then
        return "no backup"
    end
    if opts.dir and opts.dir ~= "" then
        return "backup → " .. opts.dir
    end
    if opts.dotfile then
        return "keeps dotfile *wezai.bak"
    end
    return "keeps timestamped " .. opts.suffix
end

function M.apply_file_edit(path, new_content, config)
    if type(new_content) ~= "string" then
        return false, "edit response missing file contents", nil, nil
    end

    local original = ""
    local src = io.open(path, "rb")
    if src then
        original = src:read("*a") or ""
        src:close()
    end

    local backup_path = M.backup_path_for(path, config)
    if backup_path then
        if not util.ensure_parent_dir(backup_path) then
            return false, "cannot create backup directory for " .. backup_path, nil, original
        end
        local bak_ok, bak_err = util.write_text_file(backup_path, original)
        if not bak_ok then
            return false, bak_err, nil, original
        end
    end

    local write_ok, write_err = util.write_text_file(path, new_content)
    if not write_ok then
        if backup_path then
            return false, write_err .. " (backup kept at " .. backup_path .. ")", backup_path, original
        end
        return false, write_err, nil, original
    end
    return true, nil, backup_path, original
end

local function restore_one(item)
    local content = nil
    local source = nil
    if item.backup and item.backup ~= "" then
        local ok, body = util.read_text_file(item.backup, nil)
        if not ok then
            return false, "Cannot read backup: " .. tostring(body), nil
        end
        content = body
        source = item.backup
    elseif item.content ~= nil then
        content = item.content
        source = "(in-memory; backups disabled)"
    else
        return false, "No backup available to undo.", nil
    end
    local wok, werr = util.write_text_file(item.path, content)
    if not wok then
        return false, "Undo failed: " .. tostring(werr), source
    end
    return true, nil, source
end

function M.undo_last_edit(window, ai_pane)
    local last = session.get_last_edit(window)
    if not last or not last.path then
        ui.ai_print(ai_pane, "No edit to undo.", "error")
        return false
    end

    local items = last.items
    if type(items) ~= "table" or #items == 0 then
        items = { last }
    end

    local restored = {}
    for i = #items, 1, -1 do
        local item = items[i]
        local ok, err, source = restore_one(item)
        if not ok then
            ui.ai_print(ai_pane, err or "Undo failed", "error")
            return false
        end
        restored[#restored + 1] = item.path .. " ← " .. tostring(source)
    end
    ui.ai_print(ai_pane, "Restored:\n" .. table.concat(restored, "\n"), "success")
    return true
end

local function count_lines(text)
    if not text or text == "" then
        return 0
    end
    local n = 0
    for _ in (text .. "\n"):gmatch("\n") do
        n = n + 1
    end
    return n
end

-- Prefer system diff -u; fall back to a simple line dump if unavailable.
function M.unified_diff(path, old_text, new_text, max_lines)
    max_lines = max_lines or 200
    old_text = old_text or ""
    new_text = new_text or ""

    local a = os.tmpname()
    local b = os.tmpname()
    local ok_a = util.write_text_file(a, old_text)
    local ok_b = util.write_text_file(b, new_text)
    if ok_a and ok_b then
        -- diff returns exit 1 when files differ; still success for our purposes
        local success, stdout, stderr = wezterm.run_child_process({
            "diff",
            "-u",
            "--label",
            "a/" .. path,
            "--label",
            "b/" .. path,
            a,
            b,
        })
        os.remove(a)
        os.remove(b)
        local out = stdout or ""
        if out == "" and stderr and stderr ~= "" then
            out = stderr
        end
        if out ~= "" then
            local lines = {}
            local n = 0
            for line in (out .. "\n"):gmatch("(.-)\n") do
                n = n + 1
                if n > max_lines then
                    table.insert(lines, "... (diff truncated)")
                    break
                end
                table.insert(lines, line)
            end
            return table.concat(lines, "\n"), count_lines(old_text), count_lines(new_text)
        end
        if success then
            return "(no changes — files are identical)", count_lines(old_text), count_lines(new_text)
        end
    else
        pcall(os.remove, a)
        pcall(os.remove, b)
    end

    -- Fallback preview
    local old_n = count_lines(old_text)
    local new_n = count_lines(new_text)
    local preview = {
        "--- a/" .. path .. " (" .. old_n .. " lines)",
        "+++ b/" .. path .. " (" .. new_n .. " lines)",
        "(system diff unavailable — showing proposed file head)",
        "@@@@ proposed @@@@",
    }
    local n = 0
    for line in (new_text .. "\n"):gmatch("(.-)\n") do
        n = n + 1
        if n > math.min(max_lines, 80) then
            table.insert(preview, "... (truncated)")
            break
        end
        table.insert(preview, "+" .. line)
    end
    return table.concat(preview, "\n"), old_n, new_n
end

local function diff_line_label(line)
    -- Colorize +/-/@@ in the InputSelector so the overlay itself is the review UI.
    if type(wezterm.format) ~= "function" then
        return line
    end
    local fg = nil
    if line:find("^%+") and not line:find("^%+%+%+") then
        fg = "Lime"
    elseif line:find("^%-") and not line:find("^%-%-%-") then
        fg = "Red"
    elseif line:find("^@@") then
        fg = "Aqua"
    elseif line:find("^%-%-%-") or line:find("^%+%+%+") then
        fg = "Blue"
    end
    if not fg then
        return line
    end
    return wezterm.format({
        { Foreground = { AnsiColor = fg } },
        { Text = line },
    })
end

local function build_confirm_choices(diff, creating, config)
    local bak = backup_label(config)
    local choices = {
        {
            id = "apply",
            label = creating and ("Create — write new file (" .. bak .. ")")
                or ("Apply — write file (" .. bak .. ")"),
        },
        { id = "cancel", label = "Cancel — discard changes" },
        {
            id = "preview:hdr",
            label = "── diff preview (a=Apply, c=Cancel; Esc aborts) ──",
        },
    }
    local n = 0
    local total = 0
    for _ in (diff .. "\n"):gmatch("(.-)\n") do
        total = total + 1
    end
    for line in (diff .. "\n"):gmatch("(.-)\n") do
        n = n + 1
        if n > DIFF_PREVIEW_MAX then
            local left = total - DIFF_PREVIEW_MAX
            table.insert(choices, {
                id = "preview:more",
                label = string.format("… (%d more lines — full diff also in AI pane)", left),
            })
            break
        end
        -- Keep empty lines visible in the selector
        local shown = line
        if shown == "" then
            shown = " "
        end
        table.insert(choices, {
            id = "preview:" .. tostring(n),
            label = diff_line_label(shown),
        })
    end
    return choices
end

local function show_diff_then_confirm(window, shell_pane, ai_pane, config, path, original, new_content, message, callback)
    local diff, old_n, new_n = M.unified_diff(path, original, new_content)
    local basename = util.basename(path)

    local creating = (not original or original == "")
    ui.ai_print(ai_pane, (creating and "Review new file " or "Review diff for ") .. basename, "warn")
    if message and message ~= "" then
        ui.ai_print(ai_pane, message, "message")
    end
    ui.ai_print(
        ai_pane,
        string.format("stats: %d → %d lines\n\n%s", old_n or 0, new_n or 0, diff),
        "diff"
    )

    local function apply()
        local ok, err, backup, prior = M.apply_file_edit(path, new_content, config)
        if not ok then
            ui.ai_print(ai_pane, err or "write failed", "error")
            callback(false)
            return
        end
        -- Keep prior content in session so Undo works even when backups are off.
        session.set_last_edit(window, path, backup, prior or original or "")
        local verb = creating and "Created" or "Saved"
        if backup then
            ui.ai_print(ai_pane, verb .. ": " .. path .. "\nbackup: " .. backup, "success")
        else
            ui.ai_print(ai_pane, verb .. ": " .. path .. "\nbackup: disabled", "success")
        end
        callback(true)
    end

    if config.require_edit_confirm == false then
        apply()
        return
    end

    local bak = backup_label(config)
    local apply_label = creating and ("Create — write new file (" .. bak .. ")")
        or ("Apply — write file (" .. bak .. ")")
    local title = string.format(
        "%s %s?  (%d → %d lines)",
        creating and "Create" or "Apply edit to",
        basename,
        old_n or 0,
        new_n or 0
    )

    local function open_overlay_fallback()
        local choices = build_confirm_choices(diff, creating, config)
        local function open_confirm()
            ui.input_select(
                window,
                shell_pane,
                title,
                choices,
                function(_, _, id)
                    if id == "apply" then
                        apply()
                    elseif id == "cancel" or id == nil then
                        ui.ai_print(ai_pane, "Cancelled — file not modified.", "warn")
                        callback(false)
                    else
                        -- Selected a preview row: re-open so the overlay keeps the diff visible.
                        open_confirm()
                    end
                end,
                {
                    fuzzy = false,
                    alphabet = "ac",
                    description = "python3 confirm pane unavailable — review the embedded diff. Esc cancels.",
                }
            )
        end
        open_confirm()
    end

    local function open_confirm()
        local opened = confirm.open(window, shell_pane, config, {
            title = title,
            hint = "Full unified diff is in the wezai pane on the right. a=Apply, c=Cancel.",
            apply_label = apply_label,
            cancel_label = "Cancel — discard changes",
            on_done = function(applied)
                if applied then
                    apply()
                else
                    ui.ai_print(ai_pane, "Cancelled — file not modified.", "warn")
                    callback(false)
                end
            end,
        })
        if not opened then
            open_overlay_fallback()
        end
    end

    -- Brief delay so the AI pane paints the full diff before the confirm split opens.
    if wezterm.time and wezterm.time.call_after then
        wezterm.time.call_after(0.15, open_confirm)
    else
        open_confirm()
    end
end

-- Show diff (AI pane + confirm split) and apply. callback(applied:boolean)
function M.confirm_and_apply(window, shell_pane, ai_pane, config, path, original, new_content, message, callback)
    callback = callback or function() end
    show_diff_then_confirm(window, shell_pane, ai_pane, config, path, original, new_content, message, callback)
end

--- Apply several file edits. Diffs print in the AI pane; one confirm covers the batch.
--- changes: { {path, original, new_content}, ... }
function M.confirm_and_apply_many(window, shell_pane, ai_pane, config, changes, message, callback)
    callback = callback or function() end
    if type(changes) ~= "table" or #changes == 0 then
        callback(false)
        return
    end
    if #changes == 1 then
        local c = changes[1]
        M.confirm_and_apply(
            window,
            shell_pane,
            ai_pane,
            config,
            c.path,
            c.original,
            c.new_content,
            message,
            callback
        )
        return
    end

    local stats_parts = {}
    for _, c in ipairs(changes) do
        local diff, old_n, new_n = M.unified_diff(c.path, c.original, c.new_content)
        stats_parts[#stats_parts + 1] = string.format(
            "%s  %d → %d lines\n%s",
            c.path,
            old_n or 0,
            new_n or 0,
            diff
        )
    end
    ui.ai_print(ai_pane, "Review " .. tostring(#changes) .. " file edits", "warn")
    if message and message ~= "" then
        ui.ai_print(ai_pane, message, "message")
    end
    ui.ai_print(ai_pane, table.concat(stats_parts, "\n\n"), "diff")

    local function apply_all()
        local items = {}
        local saved = {}
        for _, c in ipairs(changes) do
            local ok, err, backup, prior = M.apply_file_edit(c.path, c.new_content, config)
            if not ok then
                ui.ai_print(ai_pane, err or ("write failed: " .. tostring(c.path)), "error")
                if #items > 0 then
                    session.set_last_edit_batch(window, items)
                end
                callback(false)
                return
            end
            items[#items + 1] = { path = c.path, backup = backup, content = prior or c.original or "" }
            local bak = backup or "disabled"
            saved[#saved + 1] = c.path .. "\nbackup: " .. bak
        end
        session.set_last_edit_batch(window, items)
        ui.ai_print(ai_pane, "Saved " .. tostring(#items) .. " files:\n" .. table.concat(saved, "\n"), "success")
        callback(true)
    end

    if config.require_edit_confirm == false then
        apply_all()
        return
    end

    local bak = backup_label(config)
    local title = string.format("Apply %d file edits? (%s)", #changes, bak)
    local function open_overlay_fallback()
        ui.input_select(window, shell_pane, title, {
            { id = "apply", label = "Apply all — write " .. tostring(#changes) .. " files (" .. bak .. ")" },
            { id = "cancel", label = "Cancel — discard all changes" },
        }, function(_, _, id)
            if id == "apply" then
                apply_all()
            else
                ui.ai_print(ai_pane, "Cancelled — files not modified.", "warn")
                callback(false)
            end
        end, {
            fuzzy = false,
            alphabet = "ac",
            description = "Full diffs are in the AI pane. a=Apply all, c=Cancel.",
        })
    end
    local function open_confirm()
        local opened = confirm.open(window, shell_pane, config, {
            title = title,
            hint = "Full diffs for every file are in the wezai pane on the right. a=Apply all, c=Cancel.",
            apply_label = "Apply all — write " .. tostring(#changes) .. " files (" .. bak .. ")",
            cancel_label = "Cancel — discard all changes",
            on_done = function(applied)
                if applied then
                    apply_all()
                else
                    ui.ai_print(ai_pane, "Cancelled — files not modified.", "warn")
                    callback(false)
                end
            end,
        })
        if not opened then
            open_overlay_fallback()
        end
    end
    if wezterm.time and wezterm.time.call_after then
        wezterm.time.call_after(0.15, open_confirm)
    else
        open_confirm()
    end
end

return M
