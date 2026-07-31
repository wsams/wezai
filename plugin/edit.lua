local wezterm = require("wezterm")
local util = require("util")
local ui = require("ui")
local session = require("session")

local M = {}

function M.apply_file_edit(path, new_content, config)
    if type(new_content) ~= "string" then
        return false, "edit response missing file contents", nil
    end
    local suffix = config.backup_suffix or ".wezai.bak"
    local backup_path = path .. suffix

    local original = ""
    local src = io.open(path, "rb")
    if src then
        original = src:read("*a") or ""
        src:close()
    end

    -- Always keep a backup (empty string for brand-new files) so undo can restore/clear.
    local bak_ok, bak_err = util.write_text_file(backup_path, original)
    if not bak_ok then
        return false, bak_err, nil
    end

    local write_ok, write_err = util.write_text_file(path, new_content)
    if not write_ok then
        return false, write_err .. " (backup kept at " .. backup_path .. ")", backup_path
    end
    return true, nil, backup_path
end

function M.undo_last_edit(window, ai_pane)
    local last = session.get_last_edit(window)
    if not last or not last.path or not last.backup then
        ui.ai_print(ai_pane, "No edit to undo.", "error")
        return false
    end
    local ok, content = util.read_text_file(last.backup, nil)
    if not ok then
        ui.ai_print(ai_pane, "Cannot read backup: " .. tostring(content), "error")
        return false
    end
    local wok, werr = util.write_text_file(last.path, content)
    if not wok then
        ui.ai_print(ai_pane, "Undo failed: " .. tostring(werr), "error")
        return false
    end
    ui.ai_print(ai_pane, "Restored " .. last.path .. " from " .. last.backup, "success")
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

local function show_diff_then_confirm(window, shell_pane, ai_pane, config, path, original, new_content, message, callback)
    local diff, old_n, new_n = M.unified_diff(path, original, new_content)
    local basename = path:match("([^/\\]+)$") or path

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
    ui.ai_print(
        ai_pane,
        "Diff is above. Choose Apply or Cancel in the overlay.",
        "status"
    )

    local function apply()
        local ok, err, backup = M.apply_file_edit(path, new_content, config)
        if not ok then
            ui.ai_print(ai_pane, err or "write failed", "error")
            callback(false)
            return
        end
        session.set_last_edit(window, path, backup)
        local verb = creating and "Created" or "Saved"
        ui.ai_print(ai_pane, verb .. ": " .. path .. "\nbackup: " .. backup, "success")
        callback(true)
    end

    if config.require_edit_confirm == false then
        apply()
        return
    end

    local function open_confirm()
        ui.input_select(
            window,
            shell_pane,
            (creating and "Diff is in the AI pane — Create " or "Diff is in the AI pane — Apply edit to ")
                .. basename
                .. "?",
            {
                {
                    id = "apply",
                    label = creating and "Create — write new file (keeps .wezai.bak)"
                        or "Apply — write file (keeps .wezai.bak)",
                },
                { id = "cancel", label = "Cancel — discard changes" },
            },
            function(_, _, id)
                if id == "apply" then
                    apply()
                else
                    ui.ai_print(ai_pane, "Cancelled — file not modified.", "warn")
                    callback(false)
                end
            end
        )
    end

    -- Let the AI pane paint the diff before the overlay steals focus
    if wezterm.time and wezterm.time.call_after then
        wezterm.time.call_after(0.2, open_confirm)
    else
        open_confirm()
    end
end

-- Show diff in AI pane and confirm apply. callback(applied:boolean)
function M.confirm_and_apply(window, shell_pane, ai_pane, config, path, original, new_content, message, callback)
    callback = callback or function() end
    show_diff_then_confirm(window, shell_pane, ai_pane, config, path, original, new_content, message, callback)
end

return M
