local wezterm = require("wezterm")
local util = require("util")
local ui = require("ui")
local session = require("session")
local shell = require("shell")

local M = {}

local ERROR_MARKERS = {
    "error:",
    "error ",
    "failed",
    "fatal:",
    "command not found",
    "permission denied",
    "no such file",
    "traceback",
    "exception",
    "not a git repository",
}

local function hist_opts(config)
    local h = (config and config.history) or {}
    return {
        max_shell = h.max_shell or 500,
        max_session = h.max_session or 50,
        attach_n = h.attach_n or 40,
        include_scrollback = h.include_scrollback ~= false,
        -- Bytes to read from the end of history files (fish can be multi‑MB)
        tail_bytes = h.tail_bytes or (4 * 1024 * 1024),
    }
end

local function home_path(...)
    local home = os.getenv("HOME") or os.getenv("USERPROFILE")
    if not home then
        return nil
    end
    local parts = { home, ... }
    return table.concat(parts, util.separator)
end

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$") or ""
end

local function shorten(s, n)
    n = n or 80
    s = trim(s):gsub("%s+", " ")
    if #s <= n then
        return s
    end
    return s:sub(1, n - 1) .. "…"
end

local function looks_failed(text)
    local lower = (text or ""):lower()
    for _, m in ipairs(ERROR_MARKERS) do
        if lower:find(m, 1, true) then
            return true
        end
    end
    return false
end

-- Parse bare @history / @history:shell / @history:ai / @history:failed
-- (optional :N is ignored for palette scope — use attach for limits).
-- Returns filter ("", "shell", "ai", "failed") or nil if not a bare history ref.
function M.parse_bare_ref(line)
    local token = trim(line or "")
    if token == "@history" then
        return ""
    end
    local rest = token:match("^@history:([%w%-:]+)$")
    if not rest then
        return nil
    end
    -- Strip optional :N limit for palette scoping
    local filter = rest:match("^(shell|ai|failed):%d+$") or rest
    if filter == "shell" or filter == "ai" or filter == "failed" then
        return filter
    end
    return nil
end

function M.is_history_synthetic(raw)
    if raw == "history" then
        return true
    end
    return raw:match("^history:") ~= nil
end

function M.parse_history_spec(raw)
    -- returns filter ("all"|"shell"|"ai"|"failed"), limit (number|nil)
    if raw == "history" then
        return "all", nil
    end
    local rest = raw:match("^history:(.+)$")
    if not rest then
        return "all", nil
    end
    -- history:shell:40 / history:ai:20 / history:failed:15
    local filter, nstr = rest:match("^(shell|ai|failed):(%d+)$")
    if filter then
        local n = tonumber(nstr)
        if n and n > 0 then
            return filter, math.floor(n)
        end
        return filter, nil
    end
    if rest == "shell" or rest == "ai" or rest == "failed" then
        return rest, nil
    end
    -- history:40
    local n = tonumber(rest)
    if n and n > 0 then
        return "all", math.floor(n)
    end
    return "all", nil
end

-- Read the last ~chunk of a file as lines (seek from end — never loads whole multi‑MB histories).
-- tail_bytes defaults to a generous 4 MiB when not passed.
local function read_file_tail_lines(path, max_lines, tail_bytes)
    max_lines = max_lines or 2000
    tail_bytes = tail_bytes or (4 * 1024 * 1024)
    local f = io.open(path, "rb")
    if not f then
        return {}
    end
    local size = f:seek("end")
    if not size or size <= 0 then
        f:close()
        return {}
    end
    local chunk = math.min(size, tail_bytes)
    f:seek("set", size - chunk)
    local content = f:read("*a") or ""
    f:close()
    if chunk < size then
        -- Drop the first partial line when we seek mid-file
        local nl = content:find("\n", 1, true)
        if nl then
            content = content:sub(nl + 1)
        end
    end
    local lines = {}
    for line in (content .. "\n"):gmatch("(.-)\n") do
        table.insert(lines, line)
    end
    if #lines <= max_lines then
        return lines
    end
    local out = {}
    for i = #lines - max_lines + 1, #lines do
        table.insert(out, lines[i])
    end
    return out
end

local function unescape_fish_cmd(cmd)
    if not cmd then
        return ""
    end
    -- fish stores some escapes as backslash-sequences
    cmd = cmd:gsub("\\n", "\n")
    cmd = cmd:gsub("\\\\", "\\")
    return trim(cmd)
end

local function parse_fish_history(path, max_n, tail_bytes)
    -- fish yaml-ish lines: need several lines per command
    local lines = read_file_tail_lines(path, max_n * 8, tail_bytes)
    local cmds = {}
    local i = 1
    while i <= #lines do
        local cmd = lines[i]:match("^%- cmd:%s*(.*)$")
        if cmd ~= nil then
            -- continuation lines while previous ends with \
            while cmd:sub(-1) == "\\" and i < #lines do
                i = i + 1
                cmd = cmd:sub(1, -2) .. lines[i]
            end
            cmd = unescape_fish_cmd(cmd)
            if cmd ~= "" then
                table.insert(cmds, cmd)
            end
        end
        i = i + 1
    end
    return cmds
end

local function parse_zsh_history(path, max_n, tail_bytes)
    local lines = read_file_tail_lines(path, max_n, tail_bytes)
    local cmds = {}
    for _, line in ipairs(lines) do
        local cmd = line:match("^: %d+:%d+;(.*)$") or line
        cmd = trim(cmd)
        if cmd ~= "" and not cmd:match("^#") then
            table.insert(cmds, cmd)
        end
    end
    return cmds
end

local function parse_bash_history(path, max_n, tail_bytes)
    local lines = read_file_tail_lines(path, max_n, tail_bytes)
    local cmds = {}
    for _, line in ipairs(lines) do
        -- bash hist with timestamps: lines starting with #epoch
        if line:match("^#%d+$") then
            -- skip timestamp marker
        else
            local cmd = trim(line)
            if cmd ~= "" and not cmd:match("^#") then
                table.insert(cmds, cmd)
            end
        end
    end
    return cmds
end

local function fish_history_paths()
    local paths = {}
    local xdg = os.getenv("XDG_DATA_HOME")
    if xdg and xdg ~= "" then
        table.insert(paths, xdg .. util.separator .. "fish" .. util.separator .. "fish_history")
    end
    local p = home_path(".local", "share", "fish", "fish_history")
    if p then
        table.insert(paths, p)
    end
    return paths
end

local function zsh_history_paths()
    local paths = {}
    local histfile = os.getenv("HISTFILE")
    if histfile and histfile ~= "" then
        table.insert(paths, histfile)
    end
    for _, rel in ipairs({ ".zsh_history", ".zhistory" }) do
        local p = home_path(rel)
        if p then
            table.insert(paths, p)
        end
    end
    return paths
end

local function bash_history_paths()
    local paths = {}
    local histfile = os.getenv("HISTFILE")
    if histfile and histfile ~= "" then
        table.insert(paths, histfile)
    end
    for _, rel in ipairs({ ".bash_history", ".history" }) do
        local p = home_path(rel)
        if p then
            table.insert(paths, p)
        end
    end
    return paths
end

local function history_candidates_for(kind)
    if kind == "fish" then
        return { { paths = fish_history_paths(), parse = parse_fish_history } }
    elseif kind == "zsh" then
        return { { paths = zsh_history_paths(), parse = parse_zsh_history } }
    elseif kind == "bash" then
        return { { paths = bash_history_paths(), parse = parse_bash_history } }
    end
    -- unknown: try all common stores
    return {
        { paths = zsh_history_paths(), parse = parse_zsh_history },
        { paths = bash_history_paths(), parse = parse_bash_history },
        { paths = fish_history_paths(), parse = parse_fish_history },
    }
end

local function load_from_files(candidates, max_n, tail_bytes)
    for _, cand in ipairs(candidates) do
        for _, path in ipairs(cand.paths) do
            if path and util.path_exists_as_file(path) then
                local cmds = cand.parse(path, max_n, tail_bytes)
                if cmds and #cmds > 0 then
                    return cmds, path
                end
            end
        end
    end
    return {}, nil
end

-- Live fallback when history files are empty/stale (common with bash until shell exits).
-- Avoid interactive (-i) shells so we don't hang sourcing rc files.
local function load_from_shell_process(kind, max_n)
    max_n = math.min(max_n or 50, 80)
    local ok, stdout = false, ""
    if kind == "fish" then
        ok, stdout = util.run_cmd({
            "fish",
            "-c",
            string.format("history --show-time= | head -n %d", max_n),
        })
    elseif kind == "zsh" then
        local hist = os.getenv("HISTFILE") or home_path(".zsh_history") or ""
        ok, stdout = util.run_cmd({
            "zsh",
            "-f",
            "-c",
            string.format(
                "fc -p %q; fc -l -%d 2>/dev/null | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//'",
                hist,
                max_n
            ),
        })
    elseif kind == "bash" then
        local hist = os.getenv("HISTFILE") or home_path(".bash_history") or ""
        ok, stdout = util.run_cmd({
            "bash",
            "--norc",
            "--noprofile",
            "-c",
            string.format(
                "HISTFILE=%q; set -o history; history -r; history %d 2>/dev/null | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//'",
                hist,
                max_n
            ),
        })
    else
        return {}
    end
    if not ok or not stdout or stdout == "" then
        return {}
    end
    -- fish/zsh/bash history dumps are newest-first; normalize to oldest-first
    local newest_first = {}
    for line in (stdout .. "\n"):gmatch("(.-)\n") do
        line = trim(line)
        if line ~= "" then
            table.insert(newest_first, line)
        end
    end
    local cmds = {}
    for i = #newest_first, 1, -1 do
        table.insert(cmds, newest_first[i])
    end
    return cmds
end

local function tail_slice(cmds, max_n)
    if #cmds <= max_n then
        return cmds
    end
    local slice = {}
    for i = #cmds - max_n + 1, #cmds do
        table.insert(slice, cmds[i])
    end
    return slice
end

-- opts.allow_live: when true, spawn fish/zsh/bash to dump history if files are empty.
-- Palette collection should keep this false so the UI opens instantly.
function M.load_shell_history(pane, max_n, opts)
    opts = opts or {}
    local allow_live = opts.allow_live == true
    local tail_bytes = opts.tail_bytes or (4 * 1024 * 1024)
    max_n = max_n or 500
    local kind = shell.detect_shell(pane)
    local ok, cmds_or_err = pcall(function()
        local cmds = select(1, load_from_files(history_candidates_for(kind), max_n, tail_bytes))
        if #cmds == 0 and kind ~= "unknown" then
            cmds = select(1, load_from_files(history_candidates_for("unknown"), max_n, tail_bytes))
        end
        if #cmds == 0 and allow_live then
            if kind ~= "unknown" then
                cmds = load_from_shell_process(kind, max_n)
            else
                for _, try in ipairs({ "zsh", "bash", "fish" }) do
                    cmds = load_from_shell_process(try, max_n)
                    if #cmds > 0 then
                        kind = try
                        break
                    end
                end
            end
        end
        return tail_slice(cmds, max_n)
    end)
    if not ok then
        wezterm.log_warn("wezai: load_shell_history failed: " .. tostring(cmds_or_err))
        return {}, kind
    end
    return cmds_or_err or {}, kind
end

local function load_shell_history(pane, max_n, config)
    -- File-only for browsing/palette (no subprocess)
    local opts = hist_opts(config)
    return M.load_shell_history(pane, max_n or opts.max_shell, {
        allow_live = false,
        tail_bytes = opts.tail_bytes,
    })
end

local function strip_prompt(line)
    local s = trim(line)
    if s == "" then
        return nil
    end
    -- common prompt suffixes
    s = s:gsub("^.-[$#%%❯▶⇒>]%s+", "")
    s = s:gsub("^%[.-%]%s*", "")
    s = trim(s)
    if s == "" or #s < 2 then
        return nil
    end
    -- skip pure paths / status noise
    if s:match("^[%w%._%-]+$") and not s:match("[%s/]") then
        -- allow short cmds like "ls"
        if #s > 20 then
            return nil
        end
    end
    return s
end

local function load_scrollback_commands(pane, max_n)
    local ok, text = pcall(function()
        return pane:get_logical_lines_as_text(math.max(max_n * 3, 120))
    end)
    if not ok or not text or text == "" then
        return {}, {}
    end
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        table.insert(lines, line)
    end

    local cmds = {}
    local failed_cmds = {}
    for i, line in ipairs(lines) do
        local cmd = strip_prompt(line)
        if cmd and not cmd:match("^wezai") then
            table.insert(cmds, cmd)
            local window_blob = table.concat({
                lines[i - 1] or "",
                line,
                lines[i + 1] or "",
                lines[i + 2] or "",
            }, "\n")
            if looks_failed(window_blob) then
                table.insert(failed_cmds, cmd)
            end
        end
    end

    local function tail_unique(list)
        local seen = {}
        local out = {}
        for i = #list, 1, -1 do
            local c = list[i]
            if not seen[c] then
                seen[c] = true
                table.insert(out, 1, c)
                if #out >= max_n then
                    break
                end
            end
        end
        return out
    end

    return tail_unique(cmds), tail_unique(failed_cmds)
end

local function entry_label(kind, text)
    local prefix = ({
        shell = "shell",
        scroll = "scroll",
        ["ai-cmd"] = "ai-cmd",
        ask = "ask",
        edit = "edit",
        failed = "failed",
    })[kind] or kind
    return prefix .. " · " .. shorten(text, 72)
end

-- Resolve the best "last command" for Copy last command, etc.
-- Preference: AI-suggested → shell history file/process → scrollback.
-- Returns cmd, source ("ai"|"shell"|"scroll"|nil)
function M.resolve_last_command(window, pane, config)
    local ai = session.get_last_command(window)
    if ai and trim(ai) ~= "" then
        return trim(ai), "ai"
    end

    local opts = hist_opts(config)
    local shell_cmds = M.load_shell_history(pane, opts.max_shell, {
        allow_live = true,
        tail_bytes = opts.tail_bytes,
    })
    if shell_cmds and #shell_cmds > 0 then
        return shell_cmds[#shell_cmds], "shell"
    end

    if opts.include_scrollback ~= false then
        local scroll_cmds = load_scrollback_commands(pane, 40)
        if scroll_cmds and #scroll_cmds > 0 then
            return scroll_cmds[#scroll_cmds], "scroll"
        end
    end

    -- Session events: last ai-cmd
    local events = session.list_history_events(window, opts.max_session)
    for i = #events, 1, -1 do
        if events[i].kind == "ai-cmd" and events[i].text and events[i].text ~= "" then
            return events[i].text, "ai"
        end
    end

    return nil, nil
end

-- Collect merged, deduped entries (newest first).
function M.collect_entries(window, pane, config, filter)
    local opts = hist_opts(config)
    filter = filter or "all"
    local entries = {}
    local seen = {}

    local function push(kind, text, extra)
        text = trim(text)
        if text == "" then
            return
        end
        local key = kind .. "\0" .. text
        if filter == "shell" and kind ~= "shell" and kind ~= "scroll" then
            return
        end
        if filter == "ai" and kind ~= "ai-cmd" and kind ~= "ask" and kind ~= "edit" then
            return
        end
        if filter == "failed" and kind ~= "failed" then
            return
        end
        if seen[key] then
            return
        end
        seen[key] = true
        local e = {
            kind = kind,
            text = text,
            label = entry_label(kind, text),
            runnable = (kind == "shell" or kind == "scroll" or kind == "ai-cmd" or kind == "failed"),
        }
        if extra then
            for k, v in pairs(extra) do
                e[k] = v
            end
        end
        table.insert(entries, e)
    end

    -- Session events first (most relevant / recent helper work)
    local events = session.list_history_events(window, opts.max_session)
    for i = #events, 1, -1 do
        local ev = events[i]
        if ev.kind == "edit" then
            push("edit", "@@" .. (ev.path or "?") .. " " .. (ev.instruction or ev.text), {
                runnable = false,
                path = ev.path,
                instruction = ev.instruction or ev.text,
            })
        else
            push(ev.kind, ev.text, { runnable = ev.kind == "ai-cmd" })
        end
    end

    local last_cmd = session.get_last_command(window)
    if last_cmd then
        push("ai-cmd", last_cmd)
    end

    if opts.include_scrollback then
        local scroll_cmds, failed_cmds = load_scrollback_commands(pane, math.min(80, opts.max_shell))
        if filter == "failed" then
            for i = #failed_cmds, 1, -1 do
                push("failed", failed_cmds[i])
            end
        else
            for i = #scroll_cmds, 1, -1 do
                push("scroll", scroll_cmds[i])
            end
            for i = #failed_cmds, 1, -1 do
                push("failed", failed_cmds[i])
            end
        end
    end

    if filter ~= "ai" then
        local shell_cmds = load_shell_history(pane, opts.max_shell, config)
        for i = #shell_cmds, 1, -1 do
            push("shell", shell_cmds[i])
        end
    end

    return entries
end

-- Text block for @history attach (redacted by caller).
function M.attach_block(window, pane, config, filter, limit)
    local opts = hist_opts(config)
    limit = limit or opts.attach_n
    local entries = M.collect_entries(window, pane, config, filter or "all")
    local lines = {}
    local n = 0
    for _, e in ipairs(entries) do
        n = n + 1
        if n > limit then
            break
        end
        table.insert(lines, e.label)
    end
    if #lines == 0 then
        return "(no history entries)"
    end
    return table.concat(lines, "\n")
end

local function insert_at_prompt(shell_pane, text)
    if not text or text == "" then
        return
    end
    util.clear_line(shell_pane)
    shell_pane:send_text(text)
end

local function run_command(window, shell_pane, ai_pane, config, command)
    shell.send_command(window, shell_pane, ai_pane, config, command, function(sent)
        if sent then
            -- execute after risk gate / send
            shell_pane:send_text("\r")
            session.push_history_event(window, { kind = "ai-cmd", text = command }, hist_opts(config).max_session)
            ui.ai_print(ai_pane, "Ran: " .. shorten(command, 100), "success")
        end
    end)
end

function M.open_browser(window, pane, config, filter)
    filter = filter or "all"
    if filter == "" then
        filter = "all"
    end
    local scope = (filter == "all") and "history" or ("history:" .. filter)
    require("palette").show(window, pane, config, { scope = scope })
end

function M.show_actions(window, pane, config, entry)
    local ai_pane = ui.ensure_ai_pane(window, pane, config)
    local choices = {}

    if entry.runnable then
        table.insert(choices, { id = "run", label = "Run — send to shell and execute" })
        table.insert(choices, { id = "insert", label = "Insert — paste at prompt (edit before run)" })
    end
    if entry.kind == "edit" and entry.path then
        table.insert(choices, { id = "reedit", label = "Re-run edit — @@path with same instruction" })
    end
    table.insert(choices, { id = "explain", label = "Explain — ask AI about this" })
    table.insert(choices, { id = "attach", label = "Attach & ask — use as context in a new prompt" })
    table.insert(choices, { id = "copy", label = "Copy — clipboard" })

    ui.input_select(window, pane, "History action · " .. shorten(entry.text, 50), choices, function(win, p, id)
        if not id then
            return
        end
        local ap = ui.ensure_ai_pane(win, p, config)

        if id == "run" then
            run_command(win, p, ap, config, entry.text)
        elseif id == "insert" then
            insert_at_prompt(p, entry.text)
            ui.ai_print(ap, "Inserted at prompt: " .. shorten(entry.text, 100), "success")
        elseif id == "reedit" then
            local line = "@@" .. entry.path .. " " .. (entry.instruction or entry.text)
            local ctx = require("context")
            local request, err = ctx.prepare_request(win, p, line, nil, config)
            if err then
                ui.ai_print(ap, err, "error")
                return
            end
            if request and M._dispatch then
                M._dispatch(win, p, request, config)
            end
        elseif id == "explain" then
            if M._explain then
                M._explain(win, p, config, entry)
            end
        elseif id == "attach" then
            if M._attach_ask then
                M._attach_ask(win, p, config, entry)
            end
        elseif id == "copy" then
            if shell.write_clipboard(entry.text) then
                ui.ai_print(ap, "Copied to clipboard.", "success")
            else
                ui.ai_print(ap, "Could not copy to clipboard.", "error")
            end
        end
    end, { fuzzy = false })
end

-- Hooks set by init.lua to avoid circular requires for ask/edit dispatch
M._dispatch = nil
M._explain = nil
M._attach_ask = nil

return M
