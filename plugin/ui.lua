local wezterm = require("wezterm")
local act = wezterm.action
local util = require("util")

local M = {}

-- tab_id -> { ai = pane, shell = pane, pad = n }
local panes = {}
local default_pad = 2

-- ANSI helpers
local ESC = "\27["
local function sgr(...)
    return ESC .. table.concat({ ... }, ";") .. "m"
end
local RESET = sgr(0)
local BOLD = sgr(1)
local DIM = sgr(2)
local RED = sgr(31)
local GREEN = sgr(32)
local YELLOW = sgr(33)
local BLUE = sgr(34)
local MAGENTA = sgr(35)
local CYAN = sgr(36)
local BRIGHT_BLACK = sgr(90)

local KIND_STYLE = {
    -- Meta / chrome: slightly muted but still readable on dark themes
    system = { color = BRIGHT_BLACK, label = nil, gap_before = false },
    status = { color = DIM .. YELLOW, label = nil, gap_before = false },
    message = { color = CYAN, label = "assistant", gap_before = true },
    command = { color = GREEN, label = "command", gap_before = true },
    attach = { color = MAGENTA, label = "context", gap_before = true },
    error = { color = RED, label = "error", gap_before = true },
    success = { color = GREEN, label = "ok", gap_before = true },
    warn = { color = YELLOW, label = "warn", gap_before = true },
    diff = { color = "", label = "diff", gap_before = true },
    -- Terminal-default foreground (no forced color) — for git status/log/etc.
    plain = { color = "", label = nil, gap_before = true },
    git = { color = "", label = "git", gap_before = true },
    turn = { color = BOLD .. BLUE, label = nil, gap_before = true },
}

-- Portable keep-alive: macOS `sleep` does NOT accept "infinity".
local function keep_alive_args(pad)
    local indent = string.rep(" ", pad or default_pad)
    if util.is_windows then
        return { "cmd", "/c", "echo wezai output pane && ping -t localhost >NUL" }
    end
    return {
        "sh",
        "-c",
        string.format(
            "printf '\\r\\n%s%swezai%s — output pane\\r\\n%s%sFollow up: CTRL+i%s · %sCTRL+SHIFT+P%s command palette\\r\\n%sType @git / @history in the palette to filter\\r\\n\\r\\n'; "
                .. "while true; do sleep 86400; done",
            indent,
            BOLD .. CYAN,
            RESET,
            indent,
            DIM,
            RESET,
            DIM,
            RESET,
            indent
        ),
    }
end

local function pane_usable(pane)
    if not pane then
        return false
    end
    local ok_id = pcall(function()
        return pane:pane_id()
    end)
    if not ok_id then
        return false
    end
    local ok_dim = pcall(function()
        return pane:get_dimensions()
    end)
    return ok_dim
end

local function pane_id(pane)
    if not pane then
        return nil
    end
    local ok, id = pcall(function()
        return pane:pane_id()
    end)
    if ok then
        return id
    end
    return nil
end

local function looks_like_ai_pane(pane)
    if not pane_usable(pane) then
        return false
    end
    local ok, text = pcall(function()
        return pane:get_logical_lines_as_text(12)
    end)
    if not ok or not text then
        return false
    end
    return text:find("wezai", 1, true) ~= nil and text:find("output pane", 1, true) ~= nil
end

local function find_ai_pane_in_tab(window)
    local ok, tab = pcall(function()
        return window:active_tab()
    end)
    if not ok or not tab then
        return nil
    end
    local ok_list, list = pcall(function()
        return tab:panes()
    end)
    if not ok_list or type(list) ~= "table" then
        return nil
    end
    for _, p in ipairs(list) do
        if looks_like_ai_pane(p) then
            return p
        end
    end
    return nil
end

-- Strip/replace invalid UTF-8 so InputSelector doesn't crash on history labels.
function M.sanitize_utf8(s)
    s = tostring(s or "")
    if s == "" then
        return s
    end
    if utf8 and utf8.len and utf8.len(s) then
        return s
    end
    if not utf8 or not utf8.len then
        return (s:gsub("[\128-\255]", "?"))
    end
    local out = {}
    local i = 1
    local n = #s
    while i <= n do
        local matched = false
        for len = math.min(4, n - i + 1), 1, -1 do
            local chunk = s:sub(i, i + len - 1)
            if utf8.len(chunk) == 1 then
                table.insert(out, chunk)
                i = i + len
                matched = true
                break
            end
        end
        if not matched then
            table.insert(out, "?")
            i = i + 1
        end
    end
    return table.concat(out)
end

local function pad_cols_for(pane)
    for _, entry in pairs(panes) do
        if entry.ai == pane or entry.shell == pane then
            return entry.pad or default_pad
        end
    end
    return default_pad
end

-- Return the user's shell pane, never the AI output pane.
-- After @git:log the focused pane is often the AI pane (no cwd) — callers must use this.
function M.shell_pane_for(window, pane)
    local tid = util.tab_id(window)
    local entry = panes[tid]
    local pid = pane_id(pane)

    if entry and pane_usable(entry.ai) and pid and pane_id(entry.ai) == pid then
        if pane_usable(entry.shell) and pane_id(entry.shell) ~= pid then
            return entry.shell
        end
    end

    if entry and pane_usable(entry.shell) then
        -- Prefer stored shell when current pane looks like AI output
        if looks_like_ai_pane(pane) then
            return entry.shell
        end
    end

    if pane_usable(pane) and not looks_like_ai_pane(pane) then
        return pane
    end

    if entry and pane_usable(entry.shell) then
        return entry.shell
    end

    return pane
end

local function strip_leading_emoji_label(text)
    -- Keep content readable; styling adds the role label
    return text
end

local function format_block(text, kind, pad)
    kind = kind or "system"
    local style = KIND_STYLE[kind] or KIND_STYLE.system
    local indent = string.rep(" ", pad or default_pad)
    local body = strip_leading_emoji_label(text or "")
    body = body:gsub("\r\n", "\n"):gsub("\r", "\n")

    local lines = {}
    if style.gap_before then
        table.insert(lines, "")
    end

    if kind == "turn" then
        local rule = string.rep("─", 28)
        table.insert(lines, indent .. style.color .. rule .. RESET)
        if body ~= "" then
            table.insert(lines, indent .. style.color .. BOLD .. body .. RESET)
        end
        table.insert(lines, indent .. style.color .. rule .. RESET)
        table.insert(lines, "")
        return table.concat(lines, "\r\n") .. "\r\n"
    end

    if style.label then
        table.insert(lines, indent .. style.color .. BOLD .. "▶ " .. style.label .. RESET)
    end

    for line in (body .. "\n"):gmatch("(.-)\n") do
        local rendered = nil
        if kind == "diff" then
            local color = ""
            if line:find("^%+") and not line:find("^%+%+%+") then
                color = GREEN
            elseif line:find("^%-") and not line:find("^%-%-%-") then
                color = RED
            elseif line:find("^@@") then
                color = CYAN
            elseif line:find("^%-%-%-") or line:find("^%+%+%+") then
                color = BOLD .. BLUE
            end
            if color ~= "" then
                rendered = indent .. color .. line .. RESET
            else
                rendered = indent .. RESET .. line .. RESET
            end
        elseif kind == "git" then
            -- Branch header cyan; status XY yellow; paths use default terminal fg
            if line:sub(1, 2) == "##" then
                rendered = indent .. CYAN .. line .. RESET
            elseif #line >= 2 and line:match("^[MADRCUTU%s%?%!%*][MADRCUTU%s%?%!%*]") then
                rendered = indent .. YELLOW .. line:sub(1, 2) .. RESET .. line:sub(3)
            else
                rendered = indent .. RESET .. line .. RESET
            end
        elseif style.color ~= nil and style.color ~= "" then
            rendered = indent .. style.color .. line .. RESET
        else
            -- plain / uncolored: terminal default foreground
            rendered = indent .. RESET .. line .. RESET
        end
        table.insert(lines, rendered)
    end

    if kind == "message" or kind == "command" or kind == "success" or kind == "error" or kind == "diff" or kind == "git" or kind == "plain" then
        table.insert(lines, "")
    end

    return table.concat(lines, "\r\n") .. "\r\n"
end

local function infer_kind(text)
    if not text then
        return "system"
    end
    if text:find("^❌") or text:find("failed") then
        return "error"
    end
    if text:find("^💬") then
        return "message"
    end
    if text:find("^⌘") or text:find("^Command") then
        return "command"
    end
    if text:find("^📎") then
        return "attach"
    end
    if text:find("^💾") or text:find("^✓") or text:find("^↩️") or text:find("^📋") then
        return "success"
    end
    if text:find("^⚠️") or text:find("^…") or text:find("thinking") then
        return "status"
    end
    if text:find("^📝") or text:find("^%-%-%-") or text:find("^%+%+%+") then
        return "diff"
    end
    if text:find("^🧠") or text:find("^🧹") then
        return "system"
    end
    return "system"
end

local function inject_raw(pane, text)
    if not pane_usable(pane) then
        return false
    end
    local ok, err = pcall(function()
        pane:inject_output(text)
    end)
    if not ok then
        wezterm.log_warn("wezai: inject_output failed: ", tostring(err))
        return false
    end
    return true
end

local function spawn_ai_pane(window, shell_pane, config)
    local opts = config.ai_pane or {}
    local direction = opts.direction or "Right"
    local pct = opts.size_percent or 35
    local size = pct / 100
    local pad = opts.pad_cols or default_pad
    local args = keep_alive_args(pad)

    local ok, new_pane_or_err = pcall(function()
        return shell_pane:split({
            direction = direction,
            size = size,
            args = args,
        })
    end)
    if ok and new_pane_or_err then
        pcall(function()
            shell_pane:activate()
        end)
        wezterm.log_info("wezai: created AI pane via pane:split id=", new_pane_or_err:pane_id())
        return new_pane_or_err
    end
    if not ok then
        wezterm.log_warn("wezai: pane:split failed: ", tostring(new_pane_or_err))
    end

    if window then
        local ok2, err2 = pcall(function()
            window:perform_action(
                act.SplitPane({
                    direction = direction,
                    size = { Percent = pct },
                    command = { args = args },
                }),
                shell_pane
            )
        end)
        if not ok2 then
            wezterm.log_warn("wezai: SplitPane action failed: ", tostring(err2))
            return nil
        end
        local ai = window:active_pane()
        if ai and ai:pane_id() ~= shell_pane:pane_id() then
            pcall(function()
                shell_pane:activate()
            end)
            wezterm.log_info("wezai: created AI pane via SplitPane action")
            return ai
        end
        wezterm.log_warn("wezai: SplitPane ran but active pane unchanged")
    end
    return nil
end

function M.ensure_ai_pane(window, from_pane, config)
    local opts = config.ai_pane or {}
    local tid = util.tab_id(window)
    local pad = opts.pad_cols or default_pad
    local shell_pane = M.shell_pane_for(window, from_pane)

    if opts.enabled == false then
        panes[tid] = { ai = shell_pane, shell = shell_pane, pad = pad }
        return shell_pane
    end

    local entry = panes[tid]
    if entry and pane_usable(entry.ai) then
        -- Never overwrite shell with the AI pane itself
        if pane_usable(shell_pane) and pane_id(shell_pane) ~= pane_id(entry.ai) then
            entry.shell = shell_pane
        end
        entry.pad = pad
        pcall(function()
            entry.shell:activate()
        end)
        return entry.ai
    end

    -- After config reload, Lua state is empty but an AI pane may still exist in the tab
    local existing = find_ai_pane_in_tab(window)
    if existing and pane_usable(existing) then
        if not pane_usable(shell_pane) or pane_id(shell_pane) == pane_id(existing) then
            -- Fall back to any other pane in the tab as shell
            local ok, tab = pcall(function()
                return window:active_tab()
            end)
            if ok and tab then
                local ok_list, list = pcall(function()
                    return tab:panes()
                end)
                if ok_list and list then
                    for _, p in ipairs(list) do
                        if pane_id(p) ~= pane_id(existing) and pane_usable(p) then
                            shell_pane = p
                            break
                        end
                    end
                end
            end
        end
        panes[tid] = { ai = existing, shell = shell_pane, pad = pad }
        pcall(function()
            shell_pane:activate()
        end)
        wezterm.log_info("wezai: reattached existing AI pane")
        return existing
    end

    local created = spawn_ai_pane(window, shell_pane, config)
    if created and pane_usable(created) then
        panes[tid] = { ai = created, shell = shell_pane, pad = pad }
        pcall(function()
            shell_pane:activate()
        end)
        return created
    end

    wezterm.log_warn("wezai: could not create AI pane; falling back to shell pane")
    panes[tid] = { ai = shell_pane, shell = shell_pane, pad = pad }
    return shell_pane
end

function M.begin_turn(ai_pane, title)
    local pad = pad_cols_for(ai_pane)
    local label = title or os.date("%H:%M:%S")
    local block = format_block(label, "turn", pad)
    if inject_raw(ai_pane, block) then
        return
    end
    for _, entry in pairs(panes) do
        if entry.shell and inject_raw(entry.shell, block) then
            return
        end
    end
end

-- kind: message|command|attach|error|success|warn|status|system|diff|turn
function M.ai_print(ai_pane, text, kind)
    if not text then
        return
    end
    kind = kind or infer_kind(text)
    -- Drop emoji noise from known prefixes once we have a styled label
    local cleaned = text
    if kind == "message" then
        cleaned = cleaned:gsub("^💬%s*", "")
    elseif kind == "command" then
        cleaned = cleaned:gsub("^⌘%s*", "")
    elseif kind == "attach" then
        cleaned = cleaned:gsub("^📎%s*", "")
    elseif kind == "error" then
        cleaned = cleaned:gsub("^❌%s*", "")
    end

    local pad = pad_cols_for(ai_pane)
    local block = format_block(cleaned, kind, pad)

    if inject_raw(ai_pane, block) then
        return
    end
    for _, entry in pairs(panes) do
        if entry.ai == ai_pane and entry.shell and entry.shell ~= ai_pane then
            inject_raw(entry.shell, block)
            return
        end
    end
    for _, entry in pairs(panes) do
        if entry.shell and inject_raw(entry.shell, block) then
            return
        end
    end
    wezterm.log_error("wezai: ai_print could not deliver output")
end

function M.start_progress(ai_pane, config)
    if config.show_loading == false then
        return { stop = function() end }
    end
    local state = { done = false, started = os.time() }
    M.ai_print(ai_pane, "thinking…", "status")

    local function pulse()
        if state.done then
            return
        end
        local elapsed = os.time() - state.started
        M.ai_print(ai_pane, "still thinking (" .. elapsed .. "s)", "status")
        if wezterm.time and wezterm.time.call_after then
            wezterm.time.call_after(3.0, pulse)
        end
    end

    if wezterm.time and wezterm.time.call_after then
        wezterm.time.call_after(3.0, pulse)
    end

    return {
        stop = function()
            state.done = true
            local elapsed = os.time() - state.started
            M.ai_print(ai_pane, "done (" .. elapsed .. "s)", "status")
        end,
    }
end

function M.input_select(window, pane, title, choices, callback, opts)
    opts = opts or {}
    local fuzzy = opts.fuzzy
    if fuzzy == nil then
        fuzzy = #choices > 6
    end
    -- Prefer opening the selector from the shell pane (stable focus / cwd)
    local shell_pane = M.shell_pane_for(window, pane)
    local safe = {}
    for _, c in ipairs(choices or {}) do
        table.insert(safe, {
            id = c.id,
            label = M.sanitize_utf8(c.label or c.id or "?"),
        })
    end
    window:perform_action(
        act.InputSelector({
            title = M.sanitize_utf8(title or "wezai"),
            choices = safe,
            fuzzy = fuzzy,
            action = wezterm.action_callback(function(win, p, id, label)
                -- InputSelector may hand back the AI pane as `p` — normalize to shell
                local sp = M.shell_pane_for(win, p)
                callback(win, sp, id, label)
            end),
        }),
        shell_pane or pane
    )
end

function M.confirm(window, pane, title, yes_id, callback)
    M.input_select(window, pane, title, {
        { id = yes_id or "yes", label = "Yes — continue" },
        { id = "no", label = "No — cancel" },
    }, function(win, p, id)
        if id and id ~= "no" then
            callback(win, p, true)
        else
            callback(win, p, false)
        end
    end)
end

return M
