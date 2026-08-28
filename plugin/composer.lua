-- Ask composer: a split of the shell pane (AI output pane stays visible).
local wezterm = require("wezterm")
local util = require("util")
local ui = require("ui")
local session = require("session")

local M = {}

-- tab_id -> { pane, pane_id, config, on_submit, on_cancel, opening }
local pending = {}
local hooked = false
local cached_py = nil

local PY_CANDIDATES = {
    "/usr/bin/python3",
    "/opt/homebrew/bin/python3",
    "/usr/local/bin/python3",
    "/usr/bin/python",
}

local function tid_of(window)
    return util.tab_id(window)
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

local function pane_alive(pane)
    if not pane then
        return false
    end
    local alive = false
    pcall(function()
        if pane:pane_id() and pane:get_dimensions() then
            alive = true
        end
    end)
    return alive
end

local function file_exists(path)
    if not path or path == "" then
        return false
    end
    local fh = io.open(path, "r")
    if not fh then
        return false
    end
    fh:close()
    return true
end

local function composer_script()
    local dir = util.plugin_dir()
    if not dir or dir == "" then
        return nil
    end
    local path = dir .. "composer.py"
    if not file_exists(path) then
        return nil
    end
    return path
end

-- Prefer a cheap io.open probe so CTRL+I never waits on login-shell PATH scans.
local function python3()
    if cached_py then
        return cached_py
    end
    for _, path in ipairs(PY_CANDIDATES) do
        if file_exists(path) then
            cached_py = path
            return cached_py
        end
    end
    cached_py = util.resolve_executable("python3", {
        candidates = PY_CANDIDATES,
    })
    return cached_py
end

local function close_pane(window, pane)
    if not pane then
        return
    end
    pcall(function()
        window:perform_action(wezterm.action.CloseCurrentPane({ confirm = false }), pane)
    end)
end

local function activate_shell(window, pane)
    local shell_pane = ui.shell_pane_for(window, pane)
    if shell_pane then
        pcall(function()
            shell_pane:activate()
        end)
    end
end

local function tab_panes(window)
    local ok, tab = pcall(function()
        return window:active_tab()
    end)
    if not ok or not tab then
        return {}
    end
    local ok_list, list = pcall(function()
        return tab:panes()
    end)
    if not ok_list or type(list) ~= "table" then
        return {}
    end
    return list
end

function M.looks_like_composer(pane)
    if not pane then
        return false
    end
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
    local ok_name, name = pcall(function()
        return pane:get_foreground_process_name()
    end)
    if ok_name and type(name) == "string" and name:find("composer.py", 1, true) then
        return true
    end
    return false
end

local function find_composers(window)
    local found = {}
    for _, p in ipairs(tab_panes(window)) do
        if pane_alive(p) and M.looks_like_composer(p) then
            found[#found + 1] = p
        end
    end
    return found
end

local function close_extra_composers(window, keep)
    local keep_id = pane_id(keep)
    for _, p in ipairs(find_composers(window)) do
        local id = pane_id(p)
        if id and (not keep_id or id ~= keep_id) then
            wezterm.log_info("wezai: closing extra composer pane id=", id)
            close_pane(window, p)
        end
    end
end

local function focus_composer(window, pane)
    if not pane then
        return
    end
    pcall(function()
        pane:activate()
    end)
end

local function adopt(window, tid, composer_pane, shell_pane, config, opts)
    pending[tid] = {
        pane = composer_pane,
        pane_id = pane_id(composer_pane),
        config = config,
        on_submit = opts.on_submit,
        on_cancel = opts.on_cancel,
        opening = false,
    }
    ui.remember_composer(tid, composer_pane, shell_pane)
    close_extra_composers(window, composer_pane)
    focus_composer(window, composer_pane)
    return true
end

local function handle_var(window, pane, name, value)
    if name ~= "WEZAI_SUBMIT" and name ~= "WEZAI_DRAFT" and name ~= "WEZAI_CANCEL" then
        return
    end
    local tid = tid_of(window)
    local st = pending[tid]
    if not st then
        -- Still persist drafts if the composer outlived Lua state.
        if name == "WEZAI_DRAFT" then
            session.set_draft(window, value or "")
        end
        return
    end

    local incoming = pane_id(pane)
    local expected = pane_id(st.pane)
    if incoming and expected and incoming ~= expected then
        -- A leftover composer pane is dying or typing; do not cancel the live one.
        if name == "WEZAI_DRAFT" then
            session.set_draft(window, value or "")
        end
        return
    end

    if name == "WEZAI_DRAFT" then
        session.set_draft(window, value or "")
        return
    end

    if name == "WEZAI_SUBMIT" then
        session.set_draft(window, "")
        local line = value or ""
        local on_submit = st.on_submit
        pending[tid] = nil
        close_pane(window, st.pane or pane)
        activate_shell(window, pane)
        if on_submit and line ~= nil then
            -- Empty string is a valid "use selection" ask (Enter with no text).
            on_submit(window, ui.shell_pane_for(window, pane), line)
        end
        return
    end

    if name == "WEZAI_CANCEL" then
        -- Draft already stored via WEZAI_DRAFT (composer emits it first).
        local on_cancel = st.on_cancel
        pending[tid] = nil
        close_pane(window, st.pane or pane)
        activate_shell(window, pane)
        if on_cancel then
            on_cancel(window, ui.shell_pane_for(window, pane))
        end
    end
end

function M.ensure_hook()
    if hooked then
        return
    end
    hooked = true
    wezterm.on("user-var-changed", function(window, pane, name, value)
        local ok, err = pcall(handle_var, window, pane, name, value)
        if not ok then
            wezterm.log_error("wezai: composer user-var failed: ", tostring(err))
        end
    end)
end

--- Open (or focus) the ask composer. opts.on_submit(window, shell_pane, line)
--- Splits immediately; cwd @/# matches load inside composer.py in the background.
function M.open(window, pane, config, opts)
    opts = opts or {}
    M.ensure_hook()
    local shell_pane = ui.shell_pane_for(window, pane)
    local tid = tid_of(window)
    local existing = pending[tid]

    -- In-flight split (CTRL+I mashed while pane:split yields): do not spawn another.
    if existing and existing.opening then
        if pane_alive(existing.pane) then
            focus_composer(window, existing.pane)
        end
        return true
    end

    if existing and pane_alive(existing.pane) then
        existing.on_submit = opts.on_submit or existing.on_submit
        existing.on_cancel = opts.on_cancel or existing.on_cancel
        existing.config = config or existing.config
        close_extra_composers(window, existing.pane)
        focus_composer(window, existing.pane)
        return true
    end

    if existing then
        pending[tid] = nil
    end

    -- Reattach after config reload / lost Lua state; close any duplicates.
    local already = find_composers(window)
    if #already > 0 then
        return adopt(window, tid, already[1], shell_pane, config, opts)
    end

    -- Lock before any work that can yield so a second CTRL+I cannot split again.
    pending[tid] = {
        opening = true,
        config = config,
        on_submit = opts.on_submit,
        on_cancel = opts.on_cancel,
    }

    local script = composer_script()
    local py = python3()
    if not script or not py then
        pending[tid] = nil
        return false, "composer requires python3 and plugin/composer.py"
    end

    local cwd = util.get_pane_cwd(shell_pane)
    local hint = session.pins_summary(window)
    local eph_n = #(session.list_ephemeral(window) or {})
    if eph_n > 0 then
        local extra = eph_n .. " sticky selection(s) (compact clears)"
        hint = (hint ~= "" and (hint .. " · " .. extra)) or extra
    end
    local draft = session.get_draft(window) or ""
    if opts.prefill and opts.prefill ~= "" and (not draft or draft == "") then
        draft = opts.prefill
    end

    local size = 0.32
    local c = config.composer or {}
    if tonumber(c.size_percent) then
        size = math.max(0.15, math.min(0.6, tonumber(c.size_percent) / 100))
    end

    local max_n = 400
    local files_opts = config.files or {}
    if tonumber(files_opts.max_candidates) then
        max_n = math.max(50, tonumber(files_opts.max_candidates))
    end

    local env = {
        WEZAI_COMPOSER_PANE = "1",
        WEZAI_CWD = cwd or "",
        WEZAI_DRAFT = draft,
        WEZAI_HINT = hint,
        WEZAI_MAX_CANDIDATES = tostring(max_n),
        PYTHONUNBUFFERED = "1",
        TERM = "xterm-256color",
    }

    local ok, new_pane_or_err = pcall(function()
        return shell_pane:split({
            direction = "Bottom",
            size = size,
            args = { py, script },
            set_environment_variables = env,
        })
    end)
    if not ok or not new_pane_or_err then
        pending[tid] = nil
        wezterm.log_warn("wezai: composer split failed: ", tostring(new_pane_or_err))
        return false, tostring(new_pane_or_err)
    end

    pending[tid] = {
        pane = new_pane_or_err,
        pane_id = pane_id(new_pane_or_err),
        config = config,
        on_submit = opts.on_submit,
        on_cancel = opts.on_cancel,
        opening = false,
    }
    ui.remember_composer(tid, new_pane_or_err, shell_pane)
    close_extra_composers(window, new_pane_or_err)
    focus_composer(window, new_pane_or_err)
    wezterm.log_info("wezai: composer pane id=", new_pane_or_err:pane_id())
    return true
end

function M.pending_pane(window)
    local st = pending[tid_of(window)]
    return st and st.pane or nil
end

return M
