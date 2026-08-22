local wezterm = require("wezterm")
local util = require("util")
local ui = require("ui")
local git = require("git")
local kube = require("kube")
local history = require("history")

local tf
do
    local ok, mod = pcall(require, "tf")
    if ok then
        tf = mod
    else
        wezterm.log_warn("wezai: palette @tf disabled — " .. tostring(mod))
        tf = {
            list_actions = function()
                return {}
            end,
            run_action = function() end,
        }
    end
end

local weather
do
    local ok, mod = pcall(require, "weather")
    if ok then
        weather = mod
    else
        wezterm.log_warn("wezai: palette @weather disabled — " .. tostring(mod))
        weather = {
            list_actions = function()
                return {}
            end,
            run_action = function() end,
        }
    end
end

local docker
do
    local ok, mod = pcall(require, "docker")
    if ok then
        docker = mod
    else
        wezterm.log_warn("wezai: palette @docker disabled — " .. tostring(mod))
        docker = {
            list_actions = function()
                return {}
            end,
            run_action = function() end,
        }
    end
end

local M = {}

-- Set by init.lua: functions(win, pane, config)
M.handlers = {}

local function hist_cap(config, scoped)
    local h = (config and config.history) or {}
    if scoped then
        return h.search_n or 12000
    end
    return h.palette_n or 200
end

local function add(choices, handlers, id, label, fn)
    table.insert(choices, { id = id, label = label })
    handlers[id] = fn
end

-- scope: nil (all) | "git" | "kube" | "tf" | "weather" | "docker" | "history" | "history:…"
function M.show(window, pane, config, opts)
    opts = opts or {}
    local scope = opts.scope

    local ok, err = pcall(function()
        -- Normalize to shell pane so git/history use a real cwd (not the AI output pane)
        pane = ui.shell_pane_for(window, pane)
        local choices = {}
        local handlers = {}
        local H = M.handlers

        local include_core = (scope == nil)
        local include_git = (scope == nil or scope == "git")
        local include_kube = (scope == nil or scope == "kube")
        local include_tf = (scope == nil or scope == "tf")
        local include_weather = (scope == nil or scope == "weather")
        local include_docker = (scope == nil or scope == "docker")
        local hist_filter = nil
        if scope == "history" then
            hist_filter = "all"
        elseif scope == "history:failed" then
            hist_filter = "failed"
        elseif scope == "history:shell" then
            hist_filter = "shell"
        elseif scope == "history:ai" then
            hist_filter = "ai"
        elseif scope == nil then
            hist_filter = "all"
        end

        if include_core then
            add(choices, handlers, "core:ask", "Ask…", function(win, p, cfg)
                if H.ask then
                    H.ask(win, p, cfg)
                end
            end)
            add(choices, handlers, "core:ask_pane", "Ask (with pane history)…", function(win, p, cfg)
                if H.ask_pane then
                    H.ask_pane(win, p, cfg)
                end
            end)
            add(choices, handlers, "core:fix_error", "Fix last error", function(win, p, cfg)
                if H.fix_error then
                    H.fix_error(win, p, cfg)
                end
            end)
            add(choices, handlers, "core:explain_cmd", "Explain last command", function(win, p, cfg)
                if H.explain_cmd then
                    H.explain_cmd(win, p, cfg)
                end
            end)
            add(choices, handlers, "core:attach_file", "Attach file… (@pick fuzzy)", function(win, p, cfg)
                if H.attach_file then
                    H.attach_file(win, p, cfg)
                end
            end)
            add(choices, handlers, "core:edit", "Edit file… (#pick fuzzy)", function(win, p, cfg)
                if H.edit_file then
                    H.edit_file(win, p, cfg)
                elseif H.edit then
                    H.edit(win, p, cfg)
                end
            end)
            add(choices, handlers, "core:undo_edit", "Undo last edit", function(win, p, cfg)
                if H.undo_edit then
                    H.undo_edit(win, p, cfg)
                end
            end)
            add(choices, handlers, "core:copy_cmd", "Copy last command", function(win, p, cfg)
                if H.copy_cmd then
                    H.copy_cmd(win, p, cfg)
                end
            end)
            add(choices, handlers, "core:show_question", "Show last question", function(win, p, cfg)
                if H.show_question then
                    H.show_question(win, p, cfg)
                end
            end)
            add(choices, handlers, "core:shorter", "Re-ask last question (shorter)", function(win, p, cfg)
                if H.shorter then
                    H.shorter(win, p, cfg)
                end
            end)
            add(choices, handlers, "core:model", "Pick model…", function(win, p, cfg)
                if H.pick_model then
                    H.pick_model(win, p, cfg)
                end
            end)
            add(choices, handlers, "core:compact", "Compact chat (keep @/# files)", function(win, p, cfg)
                if H.compact then
                    H.compact(win, p, cfg)
                end
            end)
            add(choices, handlers, "core:clear", "Clear chat + file context", function(win, p, cfg)
                if H.clear then
                    H.clear(win, p, cfg)
                end
            end)
            add(choices, handlers, "core:install", "Show wezai install (version + cache path)", function(win, p, cfg)
                if H.show_install then
                    H.show_install(win, p, cfg)
                end
            end)
            add(choices, handlers, "core:update", "Update wezai plugin (fetch + reload)", function(win, p, cfg)
                if H.update_plugin then
                    H.update_plugin(win, p, cfg)
                end
            end)
        end

        if include_git then
            for _, a in ipairs(git.list_actions()) do
                local kind = a.kind == "ai" and "ai" or (a.kind == "show" and "show" or "run")
                local label = "@git:" .. a.id .. "  [" .. kind .. "]  " .. a.label
                local action_id = a.id
                add(choices, handlers, "git:" .. action_id, label, function(win, p, cfg)
                    git.run_action(win, p, cfg, action_id, nil)
                end)
            end
        end

        if include_kube then
            for _, a in ipairs(kube.list_actions()) do
                local kind = a.kind == "ai" and "ai" or (a.kind == "show" and "show" or "run")
                local label = "@kube:" .. a.id .. "  [" .. kind .. "]  " .. a.label
                local action_id = a.id
                add(choices, handlers, "kube:" .. action_id, label, function(win, p, cfg)
                    kube.run_action(win, p, cfg, action_id, nil)
                end)
            end
        end

        if include_tf then
            for _, a in ipairs(tf.list_actions()) do
                local kind = a.kind == "ai" and "ai" or (a.kind == "show" and "show" or "run")
                local label = "@tf:" .. a.id .. "  [" .. kind .. "]  " .. a.label
                local action_id = a.id
                add(choices, handlers, "tf:" .. action_id, label, function(win, p, cfg)
                    tf.run_action(win, p, cfg, action_id, nil)
                end)
            end
        end

        if include_weather then
            for _, a in ipairs(weather.list_actions()) do
                local kind = a.kind == "ai" and "ai" or (a.kind == "show" and "show" or "run")
                local label = "@weather:" .. a.id .. "  [" .. kind .. "]  " .. a.label
                local action_id = a.id
                add(choices, handlers, "weather:" .. action_id, label, function(win, p, cfg)
                    weather.run_action(win, p, cfg, action_id, nil)
                end)
            end
        end

        if include_docker then
            for _, a in ipairs(docker.list_actions()) do
                local kind = a.kind == "ai" and "ai" or (a.kind == "show" and "show" or "run")
                local label = "@docker:" .. a.id .. "  [" .. kind .. "]  " .. a.label
                local action_id = a.id
                add(choices, handlers, "docker:" .. action_id, label, function(win, p, cfg)
                    docker.run_action(win, p, cfg, action_id, nil)
                end)
            end
        end

        local hist_scoped = scope and tostring(scope):find("^history") ~= nil
        if hist_filter then
            if hist_scoped then
                add(choices, handlers, "hist:search", "@history  Search entire history…", function(win, p, cfg)
                    history.prompt_search(win, p, cfg)
                end)
                local kind = history.detect_kind(pane)
                if not history.histfile_kind_supported(kind) then
                    add(
                        choices,
                        handlers,
                        "hist:unsupported",
                        "@history  "
                            .. kind
                            .. " — histfile search/delete not supported (fish/zsh/bash only)",
                        function(win, p, cfg)
                            local ai = ui.ensure_ai_pane(win, p, cfg)
                            ui.ai_print(
                                ai,
                                "wezai @history indexes fish/zsh/bash histfiles. Detected shell is "
                                    .. kind
                                    .. ". Scrollback and session events still appear below. See GUIDE.md Troubleshooting.",
                                "warn"
                            )
                        end
                    )
                end
            end
            local cap = hist_cap(config, hist_scoped)
            local cok, entries_or_err = pcall(history.collect_entries, window, pane, config, hist_filter, {
                shell_limit = cap,
            })
            if not cok then
                wezterm.log_warn("wezai: history collect failed: " .. tostring(entries_or_err))
            else
                local hist_entries = entries_or_err or {}
                local n = 0
                for _, e in ipairs(hist_entries) do
                    n = n + 1
                    if n > cap then
                        break
                    end
                    local entry = e
                    local label = "@history  " .. (e.label or e.text or "?")
                    add(choices, handlers, "hist:" .. n, label, function(win, p, cfg)
                        history.show_actions(win, p, cfg, entry)
                    end)
                end
            end
        end

        if #choices == 0 then
            local ai_pane = ui.ensure_ai_pane(window, pane, config)
            ui.ai_print(ai_pane, "No palette items for this scope.", "warn")
            return
        end

        local brand = util.brand_with_version()
        local title
        if scope == "git" then
            title = brand .. " · @git  (type to filter)"
        elseif scope == "kube" then
            title = brand .. " · @kube  (type to filter)"
        elseif scope == "tf" then
            title = brand .. " · @tf  (type to filter)"
        elseif scope == "weather" then
            title = brand .. " · @weather  (type to filter)"
        elseif scope == "docker" then
            title = brand .. " · @docker  (type to filter)"
        elseif scope and tostring(scope):find("^history") then
            local kind = history.detect_kind(pane)
            if history.histfile_kind_supported(kind) then
                title = brand .. " · @history · " .. kind .. "  (type to filter)"
            else
                title = brand .. " · @history · " .. kind .. "  (histfile unsupported)"
            end
        else
            title = brand .. " · type @git / @kube / @tf / @docker / @weather / @history / Ask…"
        end

        -- Open selector on the current pane (do not create AI pane first — that steals focus)
        ui.input_select(window, pane, title, choices, function(win, p, id)
            if not id then
                return
            end
            local fn = handlers[id]
            if fn then
                local rok, rerr = pcall(fn, win, p, config)
                if not rok then
                    wezterm.log_error("wezai: palette action failed: ", tostring(rerr))
                    local ai_pane = ui.ensure_ai_pane(win, p, config)
                    ui.ai_print(ai_pane, "Palette action failed: " .. tostring(rerr), "error")
                end
            end
        end, {
            fuzzy = true,
            fuzzy_description = hist_scoped and "Fuzzy history: " or "Fuzzy matching: ",
        })
    end)

    if not ok then
        wezterm.log_error("wezai: palette failed to open: ", tostring(err))
        local ai_pane = ui.ensure_ai_pane(window, pane, config)
        ui.ai_print(ai_pane, "Palette failed: " .. tostring(err), "error")
    end
end

return M
