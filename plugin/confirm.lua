-- Apply/Cancel split of the shell pane (AI output pane stays visible).
local wezterm = require("wezterm")
local util = require("util")
local ui = require("ui")

local M = {}

-- tab_id -> { pane, on_done, config }
local pending = {}
local hooked = false

local function tid_of(window)
    return util.tab_id(window)
end

local function confirm_script()
    local dir = util.plugin_dir()
    if not dir or dir == "" then
        return nil
    end
    local path = dir .. "confirm.py"
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

local function finish(window, pane, value)
    local tid = tid_of(window)
    local st = pending[tid]
    if not st then
        return
    end
    pending[tid] = nil
    local on_done = st.on_done
    close_pane(window, st.pane or pane)
    activate_shell(window, pane)
    if on_done then
        on_done(value == "apply")
    end
end

local function handle_var(window, pane, name, value)
    if name ~= "WEZAI_CONFIRM" then
        return
    end
    local tid = tid_of(window)
    local st = pending[tid]
    if not st then
        return
    end
    local incoming = pane_id(pane)
    local expected = pane_id(st.pane)
    if incoming and expected and incoming ~= expected then
        return
    end
    finish(window, pane, value or "cancel")
end

function M.ensure_hook()
    if hooked then
        return
    end
    hooked = true
    wezterm.on("user-var-changed", function(window, pane, name, value)
        local ok, err = pcall(handle_var, window, pane, name, value)
        if not ok then
            wezterm.log_error("wezai: confirm user-var failed: ", tostring(err))
        end
    end)
end

--- Open a confirm split under the shell. Returns true if the pane opened.
--- opts: title, hint, apply_label, cancel_label, on_done(applied:boolean)
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
            local old_cb = existing.on_done
            pending[tid] = nil
            close_pane(window, existing.pane)
            if old_cb then
                old_cb(false)
            end
        else
            pending[tid] = nil
        end
    end

    local script = confirm_script()
    local py = python3()
    if not script or not py then
        return false, "confirm requires python3 and plugin/confirm.py"
    end

    local size = 0.28
    local c = (config and config.composer) or {}
    if tonumber(c.size_percent) then
        size = math.max(0.15, math.min(0.5, tonumber(c.size_percent) / 100))
    end

    local env = {
        WEZAI_CONFIRM_PANE = "1",
        WEZAI_CONFIRM_TITLE = opts.title or "Apply changes?",
        WEZAI_CONFIRM_HINT = opts.hint
            or "Review the wezai pane on the right, then Apply or Cancel.",
        WEZAI_CONFIRM_APPLY = opts.apply_label or "Apply — write file",
        WEZAI_CONFIRM_CANCEL = opts.cancel_label or "Cancel — discard changes",
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
        wezterm.log_warn("wezai: confirm split failed: ", tostring(new_pane_or_err))
        return false, tostring(new_pane_or_err)
    end

    pending[tid] = {
        pane = new_pane_or_err,
        on_done = opts.on_done,
        config = config,
    }
    ui.remember_composer(tid, new_pane_or_err, shell_pane)
    pcall(function()
        new_pane_or_err:activate()
    end)
    wezterm.log_info("wezai: confirm pane id=", new_pane_or_err:pane_id())
    return true
end

return M
