local wezterm = require("wezterm")
local act = wezterm.action
local util = require("util")
local ui = require("ui")
local session = require("session")
local shell = require("shell")
local store = require("history_store")

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

-- Cap line split so a pathological histfile cannot pin the GUI.
local MAX_TAIL_LINES = 250000
local SEARCH_MATCH_N = 400
local SEARCH_ALL_BYTES = 32 * 1024 * 1024

-- path -> { size, max_n, cmds, kind }
local file_cache = {}

local function hist_opts(config)
    local h = (config and config.history) or {}
    return {
        max_shell = h.max_shell or 20000,
        max_session = h.max_session or 50,
        attach_n = h.attach_n or 40,
        include_scrollback = h.include_scrollback ~= false,
        palette_n = h.palette_n or 200,
        search_n = h.search_n or 12000,
        tail_bytes = h.tail_bytes or (8 * 1024 * 1024),
    }
end

local function home_path(...)
    local home = os.getenv("HOME") or os.getenv("USERPROFILE")
    if not home then
        return nil
    end
    return table.concat({ home, ... }, util.separator)
end

local function trim(s)
    return store.trim(s)
end

local function shorten(s, n)
    n = n or 80
    s = trim(s):gsub("%s+", " ")
    if #s <= n then
        return s
    end
    return s:sub(1, n - 1) .. "…"
end

local function posix_quote(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
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
    if raw == "history" then
        return "all", nil
    end
    local rest = raw:match("^history:(.+)$")
    if not rest then
        return "all", nil
    end
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
    local n = tonumber(rest)
    if n and n > 0 then
        return "all", math.floor(n)
    end
    return "all", nil
end

function M.detect_kind(pane)
    return shell.detect_shell(pane)
end

local function pane_pid(pane)
    if not pane then
        return nil
    end
    local ok, info = pcall(function()
        return pane:get_foreground_process_info()
    end)
    if ok and type(info) == "table" then
        return info.pid or info.process_id
    end
    return nil
end

--- Read the pane's process environment (Linux /proc). Used for HISTFILE.
local function proc_environ(pid)
    local env = {}
    if not pid then
        return env
    end
    local f = io.open("/proc/" .. tostring(pid) .. "/environ", "rb")
    if not f then
        return env
    end
    local data = f:read("*a") or ""
    f:close()
    for entry in (data .. "\0"):gmatch("([^%z]+)") do
        local k, v = entry:match("^([^=]+)=(.*)$")
        if k then
            env[k] = v
        end
    end
    return env
end

local function pane_env(pane)
    return proc_environ(pane_pid(pane))
end

local function fish_history_paths(penv)
    local paths = {}
    local xdg = (penv and penv.XDG_DATA_HOME) or os.getenv("XDG_DATA_HOME")
    if xdg and xdg ~= "" then
        paths[#paths + 1] = xdg .. util.separator .. "fish" .. util.separator .. "fish_history"
    end
    local home = (penv and penv.HOME) or os.getenv("HOME") or os.getenv("USERPROFILE")
    if home then
        paths[#paths + 1] = home
            .. util.separator
            .. ".local"
            .. util.separator
            .. "share"
            .. util.separator
            .. "fish"
            .. util.separator
            .. "fish_history"
    end
    return paths
end

local function histfile_paths(kind, penv)
    local paths = {}
    local seen = {}
    local function add(p)
        if p and p ~= "" and not seen[p] then
            seen[p] = true
            paths[#paths + 1] = p
        end
    end
    add(penv and penv.HISTFILE)
    add(os.getenv("HISTFILE"))
    if kind == "zsh" then
        local home = (penv and penv.HOME) or os.getenv("HOME")
        if home then
            add(home .. util.separator .. ".zsh_history")
            add(home .. util.separator .. ".zhistory")
        else
            add(home_path(".zsh_history"))
            add(home_path(".zhistory"))
        end
    elseif kind == "bash" then
        local home = (penv and penv.HOME) or os.getenv("HOME")
        if home then
            add(home .. util.separator .. ".bash_history")
            add(home .. util.separator .. ".history")
        else
            add(home_path(".bash_history"))
            add(home_path(".history"))
        end
    elseif kind == "fish" then
        for _, p in ipairs(fish_history_paths(penv)) do
            add(p)
        end
    end
    return paths
end

local function first_existing(paths)
    for _, path in ipairs(paths or {}) do
        if path and util.path_exists_as_file(path) then
            return path
        end
    end
    return nil
end

local function read_file_tail(path, tail_bytes)
    local f = io.open(path, "rb")
    if not f then
        return "", 0
    end
    local size = f:seek("end") or 0
    if size <= 0 then
        f:close()
        return "", 0
    end
    local chunk = math.min(size, tail_bytes or size)
    f:seek("set", size - chunk)
    local content = f:read("*a") or ""
    f:close()
    if chunk < size then
        local nl = content:find("\n", 1, true)
        if nl then
            content = content:sub(nl + 1)
        end
    end
    return content, size
end

local function unique_from_text(kind, text, max_n)
    local parse_kind = kind
    if kind ~= "fish" and kind ~= "zsh" then
        parse_kind = "bash"
    end
    local lines = store.split_lines(text)
    if #lines > MAX_TAIL_LINES then
        local sliced = {}
        local start = #lines - MAX_TAIL_LINES + 1
        for i = start, #lines do
            sliced[#sliced + 1] = lines[i]
        end
        text = table.concat(sliced, "\n") .. "\n"
    end
    return store.unique_text(parse_kind, text, max_n)
end

local function file_size(path)
    local f = io.open(path, "rb")
    if not f then
        return 0
    end
    local size = f:seek("end") or 0
    f:close()
    return size
end

local function cached_unique(path, kind, max_n, tail_bytes)
    if not path then
        return {}
    end
    local size = file_size(path)
    if size <= 0 then
        return {}
    end
    local slot = file_cache[path]
    if
        slot
        and slot.size == size
        and slot.kind == kind
        and slot.max_n >= max_n
        and (slot.tail_bytes or 0) >= (tail_bytes or 0)
    then
        local cmds = slot.cmds
        if #cmds <= max_n then
            return cmds
        end
        local slice = {}
        for i = 1, max_n do
            slice[i] = cmds[i]
        end
        return slice
    end
    local content = read_file_tail(path, tail_bytes)
    if content == "" then
        return {}
    end
    local cmds = unique_from_text(kind, content, max_n)
    file_cache[path] = { size = size, max_n = max_n, cmds = cmds, kind = kind, tail_bytes = tail_bytes }
    return cmds
end

local function invalidate_cache(path)
    if path then
        file_cache[path] = nil
    end
end

local function resolve_executable(name, extra)
    return util.resolve_executable(name, {
        candidates = extra,
        login_shell = true,
    })
end

local function fish_bin()
    return resolve_executable("fish", {
        "/usr/bin/fish",
        "/usr/local/bin/fish",
        "/opt/homebrew/bin/fish",
        "/opt/local/bin/fish",
    })
end

local function fzf_bin()
    return resolve_executable("fzf", {
        "/usr/bin/fzf",
        "/usr/local/bin/fzf",
        "/opt/homebrew/bin/fzf",
    })
end

local function history_edit_script()
    local dir = util.plugin_dir()
    if not dir or dir == "" then
        return nil
    end
    local path = dir .. "history_edit.py"
    local fh = io.open(path, "r")
    if not fh then
        return nil
    end
    fh:close()
    return path
end

--- Native fish `history` — unique, newest-first, same store the pager uses.
local function load_from_fish_cli(max_n)
    local bin = fish_bin()
    if not bin then
        return {}
    end
    max_n = math.max(1, math.floor(max_n or 500))
    local script = string.format("history --max=%d --null", max_n)
    local ok, stdout = util.run_cmd({ bin, "--no-config", "-c", script })
    if not ok or not stdout or stdout == "" then
        ok, stdout = util.run_cmd({ bin, "-c", script })
    end
    if ok and stdout and stdout:find("\0", 1, true) then
        local cmds = {}
        for part in (stdout .. "\0"):gmatch("([^%z]+)") do
            part = trim(part)
            if part ~= "" then
                cmds[#cmds + 1] = part
            end
        end
        return cmds
    end
    -- Older fish: newline-separated unique dump.
    script = string.format("history --max=%d", max_n)
    ok, stdout = util.run_cmd({ bin, "--no-config", "-c", script })
    if not ok or not stdout or stdout == "" then
        ok, stdout = util.run_cmd({ bin, "-c", script })
    end
    if not ok or not stdout or stdout == "" then
        return {}
    end
    local cmds = {}
    for line in (stdout .. "\n"):gmatch("(.-)\n") do
        line = trim(line)
        if line ~= "" then
            cmds[#cmds + 1] = line
        end
    end
    return cmds
end

local function load_from_fish_cli_cached(max_n, histfile)
    local size = 0
    if histfile then
        local f = io.open(histfile, "rb")
        if f then
            size = f:seek("end") or 0
            f:close()
        end
    end
    local key = "fish-cli:" .. tostring(histfile or "")
    local slot = file_cache[key]
    if slot and slot.size == size and slot.max_n >= max_n then
        local cmds = slot.cmds
        if #cmds <= max_n then
            return cmds
        end
        local slice = {}
        for i = 1, max_n do
            slice[i] = cmds[i]
        end
        return slice
    end
    local cmds = load_from_fish_cli(max_n)
    if cmds and #cmds > 0 then
        file_cache[key] = { size = size, max_n = max_n, cmds = cmds, kind = "fish" }
    end
    return cmds or {}
end

-- Live fallback when history files are empty/stale (common with bash until shell exits).
-- Avoid interactive (-i) shells so we don't hang sourcing rc files.
local function load_from_shell_process(kind, max_n, histfile)
    max_n = math.min(max_n or 50, 80)
    local ok, stdout = false, ""
    if kind == "fish" then
        return load_from_fish_cli(max_n)
    elseif kind == "zsh" then
        local hist = histfile or os.getenv("HISTFILE") or home_path(".zsh_history") or ""
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
        local hist = histfile or os.getenv("HISTFILE") or home_path(".bash_history") or ""
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
    -- fc/history dumps are newest-first already for `history N`; zsh fc -l -N too.
    local cmds = {}
    for line in (stdout .. "\n"):gmatch("(.-)\n") do
        line = trim(line)
        if line ~= "" then
            cmds[#cmds + 1] = line
        end
    end
    return cmds
end

-- opts.allow_live: spawn fish/zsh/bash when files are empty.
-- opts.prefer_native: fish → `history` CLI (unique, newest-first).
-- opts.tail_bytes / opts.full: how much of the histfile to read.
-- Returns newest-first unique commands, kind, histfile path (or nil).
function M.load_shell_history(pane, max_n, opts)
    opts = opts or {}
    local allow_live = opts.allow_live == true
    local prefer_native = opts.prefer_native == true
    local tail_bytes = opts.tail_bytes or (8 * 1024 * 1024)
    if opts.full then
        tail_bytes = math.max(tail_bytes, SEARCH_ALL_BYTES)
    end
    max_n = max_n or 500
    local kind = M.detect_kind(pane)
    local penv = pane_env(pane)
    local histfile = nil
    -- Small lists (unified palette / last-command) only need a short tail.
    if not opts.full and max_n <= 250 then
        tail_bytes = math.min(tail_bytes, 1024 * 1024)
    end

    local ok, result_or_err = pcall(function()
        if kind == "fish" and prefer_native then
            histfile = first_existing(histfile_paths("fish", penv))
            local native = load_from_fish_cli_cached(max_n, histfile)
            if native and #native > 0 then
                return native
            end
        end

        local function try_kind(k)
            local path = first_existing(histfile_paths(k, penv))
            if not path then
                return {}
            end
            histfile = path
            return cached_unique(path, k, max_n, tail_bytes)
        end

        local cmds = {}
        if kind ~= "unknown" then
            cmds = try_kind(kind)
        end
        if #cmds == 0 then
            for _, k in ipairs({ "zsh", "bash", "fish" }) do
                if k ~= kind then
                    cmds = try_kind(k)
                    if #cmds > 0 then
                        kind = k
                        break
                    end
                end
            end
        end
        if #cmds == 0 and allow_live then
            if kind ~= "unknown" then
                cmds = load_from_shell_process(kind, max_n, histfile)
            else
                for _, try in ipairs({ "zsh", "bash", "fish" }) do
                    cmds = load_from_shell_process(try, max_n, nil)
                    if #cmds > 0 then
                        kind = try
                        break
                    end
                end
            end
        end
        return cmds
    end)
    if not ok then
        wezterm.log_warn("wezai: load_shell_history failed: " .. tostring(result_or_err))
        return {}, kind, histfile
    end
    return result_or_err or {}, kind, histfile
end

local function load_shell_history_for_browse(pane, max_n, config)
    local opts = hist_opts(config)
    local kind = M.detect_kind(pane)
    max_n = max_n or opts.max_shell
    return M.load_shell_history(pane, max_n, {
        allow_live = false,
        -- Native fish dump is worth it for the history-scoped palette, not for
        -- a 200-row slice of CTRL+SHIFT+P.
        prefer_native = (kind == "fish" and max_n >= 500),
        tail_bytes = opts.tail_bytes,
    })
end

local function strip_prompt(line)
    local s = trim(line)
    if s == "" then
        return nil
    end
    s = s:gsub("^.-[$#%%❯▶⇒>]%s+", "")
    s = s:gsub("^%[.-%]%s*", "")
    s = trim(s)
    if s == "" or #s < 2 then
        return nil
    end
    if s:match("^[%w%._%-]+$") and not s:match("[%s/]") then
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

function M.resolve_last_command(window, pane, config)
    local ai = session.get_last_command(window)
    if ai and trim(ai) ~= "" then
        return trim(ai), "ai"
    end

    local opts = hist_opts(config)
    local shell_cmds = M.load_shell_history(pane, math.min(80, opts.max_shell), {
        allow_live = true,
        prefer_native = false,
        tail_bytes = opts.tail_bytes,
    })
    -- newest-first
    if shell_cmds and #shell_cmds > 0 then
        return shell_cmds[1], "shell"
    end

    if opts.include_scrollback ~= false then
        local scroll_cmds = load_scrollback_commands(pane, 40)
        if scroll_cmds and #scroll_cmds > 0 then
            return scroll_cmds[#scroll_cmds], "scroll"
        end
    end

    local events = session.list_history_events(window, opts.max_session)
    for i = #events, 1, -1 do
        if events[i].kind == "ai-cmd" and events[i].text and events[i].text ~= "" then
            return events[i].text, "ai"
        end
    end

    return nil, nil
end

-- Collect merged, deduped entries (newest first).
-- opts.shell_limit: how many unique shell histfile rows to load.
function M.collect_entries(window, pane, config, filter, opts)
    opts = opts or {}
    local hopt = hist_opts(config)
    filter = filter or "all"
    local shell_limit = opts.shell_limit or hopt.max_shell
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

    local events = session.list_history_events(window, hopt.max_session)
    for i = #events, 1, -1 do
        local ev = events[i]
        if ev.kind == "edit" then
            push("edit", "#" .. (ev.path or "?") .. " " .. (ev.instruction or ev.text), {
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

    if hopt.include_scrollback then
        local scroll_cmds, failed_cmds = load_scrollback_commands(pane, math.min(80, shell_limit))
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

    if filter ~= "ai" and shell_limit > 0 then
        local shell_cmds = load_shell_history_for_browse(pane, shell_limit, config)
        for i = 1, #shell_cmds do
            push("shell", shell_cmds[i])
        end
    end

    return entries
end

function M.attach_block(window, pane, config, filter, limit)
    local hopt = hist_opts(config)
    limit = limit or hopt.attach_n
    local entries = M.collect_entries(window, pane, config, filter or "all", {
        shell_limit = limit,
    })
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
            shell_pane:send_text("\r")
            session.push_history_event(window, { kind = "ai-cmd", text = command }, hist_opts(config).max_session)
            ui.ai_print(ai_pane, "Ran: " .. shorten(command, 100), "success")
        end
    end)
end

local function write_exact_file(path, text)
    local f = io.open(path, "wb")
    if not f then
        return false
    end
    f:write(text or "")
    f:close()
    return true
end

local function lua_rewrite_histfile(kind, histfile, cmd)
    local f = io.open(histfile, "rb")
    if not f then
        return false, 0, "cannot read " .. tostring(histfile)
    end
    local raw = f:read("*a") or ""
    f:close()
    local parse_kind = kind
    if kind ~= "fish" and kind ~= "zsh" then
        parse_kind = "bash"
    end
    local new_text, removed = store.strip_exact(parse_kind, raw, cmd)
    if removed < 1 then
        return true, 0, nil
    end
    local tmp = histfile .. ".wezai.tmp"
    local out = io.open(tmp, "wb")
    if not out then
        return false, 0, "cannot write temp file"
    end
    out:write(new_text)
    out:close()
    local ok = os.rename(tmp, histfile)
    if not ok then
        -- Windows: replace existing
        os.remove(histfile)
        ok = os.rename(tmp, histfile)
    end
    if not ok then
        os.remove(tmp)
        return false, 0, "cannot replace " .. histfile
    end
    invalidate_cache(histfile)
    return true, removed, nil
end

local function send_shell(pane, command)
    if not pane or not command or command == "" then
        return
    end
    util.clear_line(pane)
    pane:send_text(command)
    pane:send_text("\r")
end

--- Delete `cmd` from the detected shell's history (all copies), like fish's pager.
--- Fish: native `history delete` in the live pane (session + file).
--- Bash/zsh: flush → rewrite HISTFILE → reload, one synchronous chain.
function M.delete_command(window, pane, config, cmd)
    cmd = trim(cmd)
    if cmd == "" then
        return false, "empty command"
    end
    local kind = M.detect_kind(pane)
    local penv = pane_env(pane)
    local ai_pane = ui.ensure_ai_pane(window, pane, config)
    local del_path = os.tmpname()
    if not write_exact_file(del_path, cmd) then
        return false, "could not write temp file"
    end

    if kind ~= "fish" and kind ~= "zsh" and kind ~= "bash" then
        os.remove(del_path)
        local removed_any = 0
        for _, k in ipairs({ "fish", "zsh", "bash" }) do
            local path = first_existing(histfile_paths(k, penv))
            if path then
                local ok, removed = lua_rewrite_histfile(k, path, cmd)
                if ok and removed and removed > 0 then
                    removed_any = removed_any + removed
                end
            end
        end
        if removed_any < 1 then
            return false, "command not found in history files (shell=" .. tostring(kind) .. ")"
        end
        ui.ai_print(
            ai_pane,
            "Removed from history file(s). Reload the shell to drop the in-memory copy: "
                .. shorten(cmd, 80),
            "success"
        )
        return true, nil
    end

    if kind == "fish" then
        local qpath = posix_quote(del_path)
        -- Native fish history: updates the live session and the YAML store.
        send_shell(
            pane,
            "history delete --exact --case-sensitive -- (command cat -- "
                .. qpath
                .. "); command rm -f "
                .. qpath
        )
        invalidate_cache(first_existing(histfile_paths("fish", penv)))
        ui.ai_print(ai_pane, "Deleted from fish history: " .. shorten(cmd, 80), "success")
        return true, nil
    end

    local script = history_edit_script()
    local histfile = first_existing(histfile_paths(kind, penv))
    local rewrite_kind = (kind == "zsh") and "zsh" or "bash"
    local default_hist = (kind == "zsh") and "$HOME/.zsh_history" or "$HOME/.bash_history"

    if script then
        local qscript = posix_quote(script)
        local qdel = posix_quote(del_path)
        local qkind = posix_quote(rewrite_kind)
        -- Prefer python3 from the user's shell PATH; composer already depends on it.
        -- Flush first so this session's lines are on disk, rewrite, then replace
        -- in-memory history — never `history -c` unless the rewrite succeeded.
        local chain
        if kind == "zsh" then
            chain = string.format(
                "hf=${HISTFILE:-%s}; builtin fc -W \"$hf\" && "
                    .. "(command -v python3 >/dev/null && python3 %s %s \"$hf\" %s "
                    .. "|| python %s %s \"$hf\" %s) && builtin fc -p \"$hf\" 100000 100000; "
                    .. "command rm -f %s",
                default_hist,
                qscript,
                qkind,
                qdel,
                qscript,
                qkind,
                qdel,
                qdel
            )
        else
            chain = string.format(
                "hf=${HISTFILE:-%s}; history -a \"$hf\" && "
                    .. "(command -v python3 >/dev/null && python3 %s %s \"$hf\" %s "
                    .. "|| python %s %s \"$hf\" %s) && history -c && history -r \"$hf\"; "
                    .. "command rm -f %s",
                default_hist,
                qscript,
                qkind,
                qdel,
                qscript,
                qkind,
                qdel,
                qdel
            )
        end
        send_shell(pane, chain)
        if histfile then
            invalidate_cache(histfile)
        end
        ui.ai_print(
            ai_pane,
            "Deleted from " .. rewrite_kind .. " history: " .. shorten(cmd, 80),
            "success"
        )
        return true, nil
    end

    -- No helper script: rewrite from this process (file only) and ask the
    -- live shell to reload without `history -c` (would drop unflushed lines).
    os.remove(del_path)
    if not histfile then
        return false, "no history file found for " .. tostring(kind)
    end
    local ok, removed, err = lua_rewrite_histfile(rewrite_kind, histfile, cmd)
    if not ok then
        return false, err or "rewrite failed"
    end
    if removed < 1 then
        return false, "command not found in " .. histfile
    end
    if kind == "zsh" then
        send_shell(pane, "builtin fc -p " .. posix_quote(histfile) .. " 100000 100000")
    elseif kind == "bash" then
        send_shell(pane, "history -r " .. posix_quote(histfile))
    end
    ui.ai_print(
        ai_pane,
        string.format("Removed %d cop%s from %s", removed, removed == 1 and "y" or "ies", histfile),
        "success"
    )
    return true, nil
end

local function fzf_filter(cmds, query, limit)
    local bin = fzf_bin()
    if not bin or #cmds == 0 then
        return nil
    end
    local tmp = os.tmpname()
    local f = io.open(tmp, "wb")
    if not f then
        return nil
    end
    -- Map display line → original command (flatten newlines for fzf).
    local by_line = {}
    for i = 1, #cmds do
        local disp = cmds[i]:gsub("[\r\n]+", " ")
        if not by_line[disp] then
            by_line[disp] = cmds[i]
            f:write(disp, "\n")
        end
    end
    f:close()
    local ok, stdout = util.run_cmd({
        "sh",
        "-c",
        posix_quote(bin) .. " -f " .. posix_quote(query) .. " < " .. posix_quote(tmp),
    })
    os.remove(tmp)
    if not ok or not stdout then
        return nil
    end
    local out = {}
    local seen = {}
    for line in (stdout .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then
            local cmd = by_line[line] or line
            if not seen[cmd] then
                seen[cmd] = true
                out[#out + 1] = cmd
                if #out >= limit then
                    break
                end
            end
        end
    end
    return out
end

--- Fuzzy-search unique shell history (full file / native fish dump).
--- Returns newest-first match strings.
function M.search(pane, config, query, limit)
    local hopt = hist_opts(config)
    limit = limit or SEARCH_MATCH_N
    query = trim(query)
    local cmds = M.load_shell_history(pane, hopt.max_shell, {
        allow_live = false,
        prefer_native = true,
        tail_bytes = hopt.tail_bytes,
        full = true,
    })
    if query == "" then
        local out = {}
        for i = 1, math.min(limit, #cmds) do
            out[i] = cmds[i]
        end
        return out
    end
    local via_fzf = fzf_filter(cmds, query, limit)
    if via_fzf then
        return via_fzf
    end
    return store.fuzzy_filter(cmds, query, limit)
end

local function show_command_rows(window, pane, config, title, cmds)
    if not cmds or #cmds == 0 then
        local ai_pane = ui.ensure_ai_pane(window, pane, config)
        ui.ai_print(ai_pane, "No matching history entries.", "warn")
        return
    end
    local choices = {}
    local by_id = {}
    for i, cmd in ipairs(cmds) do
        local id = "hit:" .. i
        by_id[id] = cmd
        choices[#choices + 1] = {
            id = id,
            label = entry_label("shell", cmd),
        }
    end
    ui.input_select(window, pane, title, choices, function(win, p, id)
        if not id then
            return
        end
        local text = by_id[id]
        if text then
            M.show_actions(win, p, config, {
                kind = "shell",
                text = text,
                label = entry_label("shell", text),
                runnable = true,
            })
        end
    end, {
        fuzzy = true,
        fuzzy_description = "Fuzzy history: ",
    })
end

function M.prompt_search(window, pane, config)
    local kind = M.detect_kind(pane)
    window:perform_action(
        act.PromptInputLine({
            description = "Fuzzy search " .. kind .. " history (all unique commands)",
            action = wezterm.action_callback(function(win, p, line)
                if line == nil then
                    return
                end
                local q = trim(line)
                if q == "" then
                    return
                end
                local ok, cmds_or_err = pcall(M.search, p, config, q, SEARCH_MATCH_N)
                if not ok then
                    local ai_pane = ui.ensure_ai_pane(win, p, config)
                    ui.ai_print(ai_pane, "History search failed: " .. tostring(cmds_or_err), "error")
                    return
                end
                show_command_rows(
                    win,
                    p,
                    config,
                    util.brand_with_version() .. " · @history · " .. kind .. "  “" .. shorten(q, 40) .. "”",
                    cmds_or_err
                )
            end),
        }),
        ui.shell_pane_for(window, pane) or pane
    )
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
    local kind = M.detect_kind(pane)
    local choices = {}

    if entry.runnable then
        table.insert(choices, { id = "run", label = "Run — send to shell and execute" })
        table.insert(choices, { id = "insert", label = "Insert — paste at prompt (edit before run)" })
    end
    if entry.kind == "edit" and entry.path then
        table.insert(choices, { id = "reedit", label = "Re-run edit — #path with same instruction" })
    end
    table.insert(choices, { id = "explain", label = "Explain — ask AI about this" })
    table.insert(choices, { id = "attach", label = "Attach & ask — use as context in a new prompt" })
    table.insert(choices, { id = "copy", label = "Copy — clipboard" })
    if entry.kind ~= "edit" and entry.text and trim(entry.text) ~= "" then
        table.insert(choices, {
            id = "delete",
            label = "Delete — remove from " .. kind .. " history (all copies)",
        })
    end

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
            local line = "#" .. entry.path .. " " .. (entry.instruction or entry.text)
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
        elseif id == "delete" then
            ui.confirm(
                win,
                p,
                "Delete from " .. kind .. " history?\n" .. shorten(entry.text, 80),
                "delete",
                function(_, _, yes)
                    if not yes then
                        ui.ai_print(ap, "Cancelled — history unchanged.", "warn")
                        return
                    end
                    local dok, derr = M.delete_command(win, p, config, entry.text)
                    if not dok then
                        ui.ai_print(ap, "Delete failed: " .. tostring(derr), "error")
                    end
                end
            )
        end
    end, { fuzzy = false })
end

-- Hooks set by init.lua to avoid circular requires for ask/edit dispatch
M._dispatch = nil
M._explain = nil
M._attach_ask = nil

return M
