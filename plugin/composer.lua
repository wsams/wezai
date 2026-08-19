-- Ask composer: a split of the shell pane (AI output pane stays visible).
local wezterm = require("wezterm")
local util = require("util")
local ui = require("ui")
local session = require("session")
local files = require("files")

local M = {}

-- tab_id -> { pane, pane_id, config, on_submit, on_cancel, cand_path }
local pending = {}
local hooked = false

local function tid_of(window)
    return util.tab_id(window)
end

local function composer_script()
    local dir = util.plugin_dir()
    if not dir or dir == "" then
        return nil
    end
    local path = dir .. "composer.py"
    local fh = io.open(path, "r")
    if not fh then
        return nil
    end
    fh:close()
    return path
end

local function python3()
    return util.resolve_executable("python3", {
        candidates = {
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python",
        },
    })
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

    if name == "WEZAI_DRAFT" then
        session.set_draft(window, value or "")
        return
    end

    if name == "WEZAI_SUBMIT" then
        session.set_draft(window, "")
        local line = value or ""
        local on_submit = st.on_submit
        pending[tid] = nil
        if st.cand_path then
            pcall(os.remove, st.cand_path)
        end
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
        if st.cand_path then
            pcall(os.remove, st.cand_path)
        end
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
function M.open(window, pane, config, opts)
    opts = opts or {}
    M.ensure_hook()
    local shell_pane = ui.shell_pane_for(window, pane)
    local tid = tid_of(window)
    local existing = pending[tid]
    if existing and existing.pane then
        local alive = false
        pcall(function()
            if existing.pane:pane_id() and existing.pane:get_dimensions() then
                alive = true
            end
        end)
        if alive then
            pcall(function()
                existing.pane:activate()
            end)
            return true
        end
        pending[tid] = nil
        if existing.cand_path then
            pcall(os.remove, existing.cand_path)
        end
    end

    local cwd = util.get_pane_cwd(shell_pane)
    local script = composer_script()
    local py = python3()
    if not script or not py then
        return false, "composer requires python3 and plugin/composer.py"
    end

    local cand = os.tmpname()
    if cwd then
        files.write_candidate_list(cwd, config, cand)
    else
        util.write_text_file(cand, "")
    end

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

    local env = {
        WEZAI_COMPOSER_PANE = "1",
        WEZAI_CWD = cwd or "",
        WEZAI_DRAFT = draft,
        WEZAI_HINT = hint,
        WEZAI_CANDIDATES = cand,
        PYTHONUNBUFFERED = "1",
        TERM = "xterm-256color",
    }

    local ok, new_pane_or_err = pcall(function()
        return shell_pane:split({
            direction = "Bottom",
            size = size,
            args = { py, script, cand },
            set_environment_variables = env,
        })
    end)
    if not ok or not new_pane_or_err then
        pcall(os.remove, cand)
        wezterm.log_warn("wezai: composer split failed: ", tostring(new_pane_or_err))
        return false, tostring(new_pane_or_err)
    end

    pending[tid] = {
        pane = new_pane_or_err,
        pane_id = new_pane_or_err:pane_id(),
        config = config,
        on_submit = opts.on_submit,
        on_cancel = opts.on_cancel,
        cand_path = cand,
    }
    ui.remember_composer(tid, new_pane_or_err, shell_pane)
    pcall(function()
        new_pane_or_err:activate()
    end)
    wezterm.log_info("wezai: composer pane id=", new_pane_or_err:pane_id())
    return true
end

function M.pending_pane(window)
    local st = pending[tid_of(window)]
    return st and st.pane or nil
end

return M
