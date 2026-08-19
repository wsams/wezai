local wezterm = require("wezterm")
local act = wezterm.action
local util = require("util")
local stats = require("stats")

local M = {}

-- tab_id -> { ai = pane, shell = pane, composer = pane, pad = n }
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
-- Marker string WEZAI_OUTPUT_PANE lets us re-detect the pane after the banner scrolls away.
local function keep_alive_args(pad)
    local indent = string.rep(" ", pad or default_pad)
    local brand = util.brand_with_version()
    if util.is_windows then
        return {
            "cmd",
            "/c",
            "echo " .. brand .. " output pane WEZAI_OUTPUT_PANE && ping -t localhost >NUL",
        }
    end
    return {
        "sh",
        "-c",
        string.format(
            "printf '\\r\\n%s%s%s%s — output pane\\r\\n%s%sFollow up: CTRL+i%s (composer keeps this pane visible) · %sCTRL+SHIFT+P%s command palette\\r\\n%sType @ to attach, # to edit · Compact/Clear · @git / @weather in the palette\\r\\n\\r\\n'; "
                .. "WEZAI_OUTPUT_PANE=1; while true; do sleep 86400; done",
            indent,
            BOLD .. CYAN,
            brand,
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

local function tab_panes(window)
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
    return list
end

local function find_pane_by_id(window, want_id)
    if want_id == nil then
        return nil
    end
    local list = tab_panes(window)
    if not list then
        return nil
    end
    for _, p in ipairs(list) do
        if pane_id(p) == want_id and pane_usable(p) then
            return p
        end
    end
    return nil
end

local function process_looks_like_composer(pane)
    local ok_info, info = pcall(function()
        return pane:get_foreground_process_info()
    end)
    if ok_info and type(info) == "table" then
        local chunks = {}
        if type(info.argv) == "table" then
            for _, a in ipairs(info.argv) do
                chunks[#chunks + 1] = tostring(a)
            end
        end
        if info.executable then
            chunks[#chunks + 1] = tostring(info.executable)
        end
        local blob = table.concat(chunks, " ")
        if blob:find("WEZAI_COMPOSER_PANE", 1, true) or blob:find("composer.py", 1, true) then
            return true
        end
    end
    return false
end

local function process_looks_like_ai(pane)
    local ok_info, info = pcall(function()
        return pane:get_foreground_process_info()
    end)
    if ok_info and type(info) == "table" then
        local chunks = {}
        if type(info.argv) == "table" then
            for _, a in ipairs(info.argv) do
                chunks[#chunks + 1] = tostring(a)
            end
        end
        if info.executable then
            chunks[#chunks + 1] = tostring(info.executable)
        end
        local blob = table.concat(chunks, " ")
        if blob:find("WEZAI_OUTPUT_PANE", 1, true)
            or (blob:find("wezai", 1, true) and blob:find("output pane", 1, true))
            or (blob:find("sleep 86400", 1, true) and blob:find("while true", 1, true))
        then
            return true
        end
    end
    local ok_name, name = pcall(function()
        return pane:get_foreground_process_name()
    end)
    if ok_name and type(name) == "string" and name:lower():find("wezai", 1, true) then
        return true
    end
    return false
end

local function looks_like_ai_pane(pane)
    if not pane_usable(pane) then
        return false
    end
    -- Composer is a prompt pane, not the AI output pane.
    if process_looks_like_composer(pane) then
        return false
    end
    -- Process fingerprint survives long scrollback (banner may be gone).
    if process_looks_like_ai(pane) then
        return true
    end
    local ok, text = pcall(function()
        return pane:get_logical_lines_as_text(80)
    end)
    if not ok or type(text) ~= "string" or text == "" then
        return false
    end
    if not text:find("wezai", 1, true) then
        return false
    end
    return text:find("output pane", 1, true)
        or text:find("WEZAI_OUTPUT_PANE", 1, true)
        or text:find("command palette", 1, true)
        or text:find("CTRL+SHIFT+P", 1, true)
        or text:find("usage  req", 1, true)
        or text:find("▶ assistant", 1, true)
        or text:find("▶ command", 1, true)
end

local function find_ai_pane_in_tab(window, prefer_id)
    if prefer_id ~= nil then
        local by_id = find_pane_by_id(window, prefer_id)
        if by_id then
            return by_id
        end
    end
    local list = tab_panes(window)
    if not list then
        return nil
    end
    for _, p in ipairs(list) do
        if looks_like_ai_pane(p) then
            return p
        end
    end
    return nil
end

local function remember_panes(tid, ai, shell, pad, composer)
    local prev = panes[tid] or {}
    panes[tid] = {
        ai = ai,
        shell = shell,
        pad = pad or default_pad,
        ai_id = pane_id(ai),
        shell_id = pane_id(shell),
        composer = composer or prev.composer,
        composer_id = composer and pane_id(composer) or prev.composer_id,
    }
end

function M.remember_composer(tid, composer, shell)
    local entry = panes[tid]
    if entry then
        entry.composer = composer
        entry.composer_id = pane_id(composer)
        if shell then
            entry.shell = shell
            entry.shell_id = pane_id(shell)
        end
    else
        panes[tid] = {
            composer = composer,
            composer_id = pane_id(composer),
            shell = shell,
            shell_id = pane_id(shell),
            pad = default_pad,
        }
    end
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

    if process_looks_like_composer(pane) then
        if entry and pane_usable(entry.shell) then
            return entry.shell
        end
    end

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

    if pane_usable(pane) and not looks_like_ai_pane(pane) and not process_looks_like_composer(pane) then
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

--- @return pane|nil, boolean is_new
local function spawn_ai_pane(window, shell_pane, config)
    -- Absolute last check — never split if an AI pane is already in this tab.
    local already = find_ai_pane_in_tab(window)
    if already then
        wezterm.log_info("wezai: spawn skipped; reused existing AI pane id=", pane_id(already))
        return already, false
    end

    local opts = config.ai_pane or {}
    local direction = opts.direction or "Right"
    local pct = opts.size_percent or 35
    local size = pct / 100
    local pad = opts.pad_cols or default_pad
    local args = keep_alive_args(pad)
    local env = { WEZAI_OUTPUT_PANE = "1" }

    local ok, new_pane_or_err = pcall(function()
        return shell_pane:split({
            direction = direction,
            size = size,
            args = args,
            set_environment_variables = env,
        })
    end)
    if ok and new_pane_or_err then
        pcall(function()
            shell_pane:activate()
        end)
        wezterm.log_info("wezai: created AI pane via pane:split id=", new_pane_or_err:pane_id())
        return new_pane_or_err, true
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
                    command = { args = args, set_environment_variables = env },
                }),
                shell_pane
            )
        end)
        if not ok2 then
            wezterm.log_warn("wezai: SplitPane action failed: ", tostring(err2))
            return nil, false
        end
        local ai = window:active_pane()
        if ai and ai:pane_id() ~= shell_pane:pane_id() then
            pcall(function()
                shell_pane:activate()
            end)
            wezterm.log_info("wezai: created AI pane via SplitPane action")
            return ai, true
        end
        wezterm.log_warn("wezai: SplitPane ran but active pane unchanged")
    end
    return nil, false
end

function M.print_usage_banner(ai_pane, config)
    if not ai_pane or (config and config.stats and config.stats.enabled == false) then
        return
    end
    local db = stats.load(config)
    M.ai_print(ai_pane, stats.format_compact(db), "status")
end

function M.ensure_ai_pane(window, from_pane, config)
    local opts = config.ai_pane or {}
    local tid = util.tab_id(window)
    local pad = opts.pad_cols or default_pad
    local shell_pane = M.shell_pane_for(window, from_pane)

    if opts.enabled == false then
        remember_panes(tid, shell_pane, shell_pane, pad)
        return shell_pane
    end

    local entry = panes[tid]
    local cached_ai = nil
    if entry then
        if pane_usable(entry.ai) then
            cached_ai = entry.ai
        elseif entry.ai_id ~= nil then
            cached_ai = find_pane_by_id(window, entry.ai_id)
        end
    end

    if cached_ai and pane_id(cached_ai) ~= pane_id(shell_pane) then
        if pane_usable(shell_pane) and pane_id(shell_pane) ~= pane_id(cached_ai) then
            -- keep shell
        elseif entry and entry.shell_id then
            local recovered = find_pane_by_id(window, entry.shell_id)
            if recovered and pane_id(recovered) ~= pane_id(cached_ai) then
                shell_pane = recovered
            end
        end
        remember_panes(tid, cached_ai, shell_pane, pad)
        pcall(function()
            shell_pane:activate()
        end)
        return cached_ai
    end

    -- Reattach after reload / lost Lua state / banner scrolled away
    local existing = find_ai_pane_in_tab(window, entry and entry.ai_id or nil)
    if existing and pane_usable(existing) then
        if not pane_usable(shell_pane) or pane_id(shell_pane) == pane_id(existing) then
            local list = tab_panes(window) or {}
            for _, p in ipairs(list) do
                if pane_id(p) ~= pane_id(existing) and pane_usable(p) and not looks_like_ai_pane(p) then
                    shell_pane = p
                    break
                end
            end
        end
        remember_panes(tid, existing, shell_pane, pad)
        pcall(function()
            shell_pane:activate()
        end)
        wezterm.log_info("wezai: reattached existing AI pane id=", pane_id(existing))
        return existing
    end

    local created, is_new = spawn_ai_pane(window, shell_pane, config)
    if created and pane_usable(created) then
        remember_panes(tid, created, shell_pane, pad)
        pcall(function()
            shell_pane:activate()
        end)
        if is_new then
            M.print_usage_banner(created, config)
        end
        return created
    end

    wezterm.log_warn("wezai: could not create AI pane; falling back to shell pane")
    remember_panes(tid, shell_pane, shell_pane, pad)
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

local function fmt_duration(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    if sec < 60 then
        return tostring(sec) .. "s"
    end
    local minutes = math.floor(sec / 60)
    local rem = sec % 60
    if minutes < 60 then
        return string.format("%dm %02ds", minutes, rem)
    end
    local hours = math.floor(minutes / 60)
    minutes = minutes % 60
    return string.format("%dh %02dm %02ds", hours, minutes, rem)
end

local function provider_endpoint(config)
    local kind = (config and config.type) or "http"
    if kind == "http" then
        local url = config and config.api_url
        if type(url) == "string" and url ~= "" then
            local host = url:match("^https?://([^/]+)")
            if host then
                return "http @" .. host
            end
        end
        return "http"
    end
    if kind == "ollama" then
        return "ollama CLI"
    end
    if kind == "local" then
        return "lms CLI"
    end
    if kind == "google" then
        return "google"
    end
    return tostring(kind)
end

local function progress_hint(elapsed, timeout, kind, pulse_n)
    local budget = tonumber(timeout) or 120
    local hints
    if kind == "http" or kind == "ollama" or kind == "local" then
        if elapsed < 15 then
            hints = {
                "request in flight",
                "waiting for first bytes",
                "provider has not replied yet",
            }
        elseif elapsed < 45 then
            hints = {
                "local models often load cold on first ask",
                "runner may still be warming up",
                "no reply yet — this can take a minute",
            }
        elseif elapsed < math.max(90, budget * 0.75) then
            hints = {
                "long wait is normal for large GGUFs",
                "still waiting on the model",
                "keep this pane open — request is live",
                "cold load + first tokens can take several minutes",
            }
        else
            hints = {
                "approaching timeout — raise config.timeout if loads are cold",
                "near timeout; a mid-load disconnect aborts Ollama warmup",
                "still waiting — consider pre-warming the model",
            }
        end
    else
        if elapsed < budget * 0.75 then
            hints = {
                "waiting for provider reply",
                "request still in flight",
                "no reply yet",
            }
        else
            hints = {
                "approaching timeout — raise config.timeout if needed",
                "still waiting on the provider",
            }
        end
    end
    return hints[((pulse_n - 1) % #hints) + 1]
end

function M.start_progress(ai_pane, config)
    config = config or {}
    if config.show_loading == false then
        return { stop = function() end }
    end
    local timeout = tonumber(config.timeout) or 120
    local model = (type(config.model) == "string" and config.model ~= "" and config.model) or "model?"
    local kind = config.type or "http"
    local endpoint = provider_endpoint(config)
    local state = { done = false, started = os.time(), pulse_n = 0 }
    local interval = 2.5

    M.ai_print(
        ai_pane,
        string.format("thinking…  %s via %s  timeout %s", model, endpoint, fmt_duration(timeout)),
        "status"
    )

    local function pulse()
        if state.done then
            return
        end
        state.pulse_n = state.pulse_n + 1
        local elapsed = os.time() - state.started
        local left = math.max(0, timeout - elapsed)
        local pct = timeout > 0 and math.min(100, math.floor((elapsed * 100) / timeout)) or 0
        local hint = progress_hint(elapsed, timeout, kind, state.pulse_n)
        M.ai_print(
            ai_pane,
            string.format(
                "… %s / %s (%d%%) · %s left — %s",
                fmt_duration(elapsed),
                fmt_duration(timeout),
                pct,
                fmt_duration(left),
                hint
            ),
            "status"
        )
        if wezterm.time and wezterm.time.call_after then
            wezterm.time.call_after(interval, pulse)
        end
    end

    if wezterm.time and wezterm.time.call_after then
        wezterm.time.call_after(interval, pulse)
    end

    return {
        stop = function()
            state.done = true
            local elapsed = os.time() - state.started
            M.ai_print(ai_pane, "done (" .. fmt_duration(elapsed) .. ")", "status")
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
        local label = c.label
        -- Allow wezterm.format tables; sanitize plain strings only.
        if type(label) ~= "table" then
            label = M.sanitize_utf8(label or c.id or "?")
        end
        table.insert(safe, {
            id = c.id,
            label = label,
        })
    end
    local selector = {
        title = M.sanitize_utf8(title or "wezai"),
        choices = safe,
        fuzzy = fuzzy and true or false,
        fuzzy_description = opts.fuzzy_description or "Fuzzy matching: ",
        action = wezterm.action_callback(function(win, p, id, label)
            -- InputSelector may hand back the AI pane as `p` — normalize to shell
            local sp = M.shell_pane_for(win, p)
            callback(win, sp, id, label)
        end),
    }
    if opts.description then
        selector.description = M.sanitize_utf8(opts.description)
    end
    if opts.alphabet then
        selector.alphabet = opts.alphabet
    end
    window:perform_action(act.InputSelector(selector), shell_pane or pane)
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
