local wezterm = require("wezterm")
local action = wezterm.action

-- WezTerm has no debug.getinfo; discover our plugin/ dir by fingerprint.
do
    local slash = (package.config:sub(1, 1) == "\\") and "\\" or "/"
    local function looks_like_wezai(dir)
        for _, name in ipairs({ "settings.lua", "stats.lua", "providers/init.lua", "palette.lua" }) do
            local fh = io.open(dir .. name, "r")
            if not fh then
                return false
            end
            fh:close()
        end
        return true
    end
    local ranked = {}
    for _, plug in ipairs(wezterm.plugin.list()) do
        local dir = tostring(plug.plugin_dir or "") .. slash .. "plugin" .. slash
        local blob = (tostring(plug.component) .. " " .. tostring(plug.url) .. " " .. dir):lower()
        if blob:find("wezai", 1, true) or looks_like_wezai(dir) then
            local score = 3
            if dir:find("sZsUsers", 1, true) or dir:find("filesCss", 1, true) then
                score = 1
            elseif dir:find("wsams", 1, true) then
                score = 2
            end
            ranked[#ranked + 1] = { score = score, dir = dir }
        end
    end
    table.sort(ranked, function(a, b)
        return a.score < b.score
    end)
    local root
    for i = 1, #ranked do
        if looks_like_wezai(ranked[i].dir) then
            root = ranked[i].dir
            break
        end
    end
    root = root or (ranked[1] and ranked[1].dir)
    if root then
        package.path = table.concat({ package.path, root .. "?.lua", root .. "?/init.lua" }, ";")
        wezterm.log_info("wezai: load path " .. root)
    else
        wezterm.log_warn("wezai: could not locate plugin modules")
    end
end

local util = require("util")
local ui = require("ui")
local session = require("session")
local shell = require("shell")
local edit = require("edit")
local context = require("context")
local history = require("history")
local git = require("git")
local palette = require("palette")
local files = require("files")
local providers = require("providers")
local settings = require("settings")
local stats = require("stats")

local function note_usage(ai_pane, config, meta)
    if not meta or (config.stats and config.stats.enabled == false) then
        return
    end
    local db = stats.record(config, meta)
    ui.ai_print(ai_pane, stats.format_turn(meta, db), "status")
end

local function parse_ai_response(response)
    local json, err = util.parse_json_response(response)
    if not json then
        local cleaned = util.clean_response(response)
        wezterm.log_error("wezai: Failed to parse JSON response: ", cleaned)
        return { message = "❌ Error parsing AI response \r\n" .. cleaned, command = nil }
    end
    return json
end

local function with_dialect(config, pane)
    local c = util.copy_config(config)
    local dialect = shell.detect_shell(pane)
    c.system_prompt = (c.system_prompt or "") .. "\n\n" .. shell.dialect_hint(dialect)
    return c, dialect
end

local function prepend_history(window, prompt, config)
    local hist = session.history_block(window)
    if hist ~= "" then
        return context.redact(hist) .. "\n\n" .. prompt
    end
    return prompt
end

local function handle_ai_request(window, shell_pane, prompt, config, opts)
    opts = opts or {}
    if not prompt or prompt:match("^%s*$") then
        return
    end

    -- Prefer the real shell pane (not the AI output pane) for cwd + dialect.
    shell_pane = ui.shell_pane_for(window, shell_pane)
    local ai_pane = ui.ensure_ai_pane(window, shell_pane, config)
    local req_config, dialect = with_dialect(config, shell_pane)

    if config._share_pane_history or opts.share_pane then
        local history
        if config.share_n_lines ~= nil then
            history = shell_pane:get_logical_lines_as_text(config.share_n_lines)
        else
            history = shell_pane:get_logical_lines_as_text()
        end
        prompt = prompt .. "\nHere is the previous history of my shell:\n" .. context.redact(history)
    end

    prompt = prepend_history(window, prompt, config)
    prompt = context.redact(prompt)

    if opts.user_text then
        session.set_last_question(window, opts.user_text)
        session.add_turn(window, "user", context.redact(opts.user_text), config.chat_max_turns)
        session.push_history_event(
            window,
            { kind = "ask", text = context.redact(opts.user_text) },
            (config.history and config.history.max_session) or 50
        )
    end

    ui.begin_turn(ai_pane, os.date("%H:%M:%S") .. "  ask")
    local progress = ui.start_progress(ai_pane, config)
    local success, stdout, err, meta = providers.ask(req_config, prompt)
    progress.stop()
    wezterm.log_info("wezai: ask finished ok=", success)

    if not success then
        ui.ai_print(ai_pane, "AI request failed" .. (err and (": " .. err) or ""), "error")
        return
    end

    note_usage(ai_pane, config, meta)

    local response = parse_ai_response(stdout)
    if response.message and response.message ~= "" then
        ui.ai_print(ai_pane, response.message, "message")
        session.add_turn(window, "assistant", context.redact(response.message), config.chat_max_turns)
    end

    if response.command and response.command ~= "" then
        session.set_last_command(window, response.command)
        session.push_history_event(
            window,
            { kind = "ai-cmd", text = response.command },
            (config.history and config.history.max_session) or 50
        )
        ui.ai_print(ai_pane, "(" .. dialect .. ")\n" .. response.command, "command")
        shell.send_command(window, shell_pane, ai_pane, config, response.command)
    end
end

local function handle_edit_request(window, shell_pane, request, config)
    local ai_pane = ui.ensure_ai_pane(window, shell_pane, config)
    local prompt = prepend_history(window, request.prompt, config)
    prompt = context.redact(prompt)

    if request.user_text then
        session.set_last_question(window, request.user_text)
        session.add_turn(window, "user", "EDIT " .. request.target_path .. ": " .. request.user_text, config.chat_max_turns)
        session.push_history_event(window, {
            kind = "edit",
            text = request.user_text,
            path = request.target_path,
            instruction = request.user_text,
        }, (config.history and config.history.max_session) or 50)
    end

    ui.begin_turn(ai_pane, os.date("%H:%M:%S") .. "  edit")
    local progress = ui.start_progress(ai_pane, config)

    local edit_config = util.copy_config(config)
    edit_config.system_prompt = context.EDIT_SYSTEM_PROMPT
    edit_config._share_pane_history = false

    local success, stdout, err, meta = providers.ask(edit_config, prompt)
    progress.stop()

    if not success then
        ui.ai_print(ai_pane, "AI edit failed" .. (err and (": " .. err) or ""), "error")
        return
    end

    note_usage(ai_pane, config, meta)

    local response, parse_err = util.parse_json_response(stdout)
    if not response then
        ui.ai_print(ai_pane, parse_err or "bad edit response", "error")
        return
    end

    local new_content = response.file
    if type(new_content) ~= "string" or new_content == "" then
        ui.ai_print(ai_pane, "Edit response missing non-empty \"file\" field", "error")
        if response.message then
            ui.ai_print(ai_pane, tostring(response.message), "message")
        end
        return
    end

    local original = request.original_content
    if not original then
        local ok, content = util.read_text_file(request.target_path, config.max_file_bytes)
        original = ok and content or ""
    end

    edit.confirm_and_apply(
        window,
        shell_pane,
        ai_pane,
        config,
        request.target_path,
        original,
        new_content,
        response.message,
        function(applied)
            if applied and response.message then
                session.add_turn(window, "assistant", context.redact(tostring(response.message)), config.chat_max_turns)
            end
        end
    )
end

local function dispatch_request(window, shell_pane, request, config, opts)
    opts = opts or {}
    local ai_pane = ui.ensure_ai_pane(window, shell_pane, config)

    if request.files and #request.files > 0 then
        local names = {}
        for _, file in ipairs(request.files) do
            local tag = (request.mode == "edit" and file.path == request.target_path) and "edit:" or ""
            table.insert(names, tag .. (file.path or "?"))
        end
        ui.ai_print(ai_pane, "Attached: " .. table.concat(names, ", "), "attach")
    end

    if request.mode == "edit" then
        handle_edit_request(window, shell_pane, request, config)
        return
    end

    handle_ai_request(window, shell_pane, request.prompt, config, {
        share_pane = opts.share_pane,
        user_text = request.user_text,
    })
end

local function prompt_for_ai(window, pane, config, opts)
    opts = opts or {}
    local share_pane = opts.share_pane or false
    local selection = util.get_selection(window, pane)
    local cwd = util.get_pane_cwd(pane)
    local selected_file = context.selection_as_file_path(selection, cwd)
    ui.ensure_ai_pane(window, pane, config)

    local description
    if selected_file then
        description = "wezai — @path / @pick / @@file / @git / @history\n---\n"
            .. util.truncate(selected_file)
            .. "\n---"
    elseif selection then
        description = "wezai — selection attached; @pick / @git / @history / @@file\n---\n"
            .. util.truncate(selection)
            .. "\n---"
    else
        description = "wezai — @path / @pick (fuzzy) / @@file / @git / @history · palette CTRL+SHIFT+P"
        if share_pane then
            description = description .. " · sharing pane history"
        end
    end
    if opts.prefill_hint then
        description = opts.prefill_hint .. "\n" .. description
    end

    local function process_ask_line(win, p, line)
        if line == nil then
            return
        end

        local bare = history.parse_bare_ref(line)
        if bare ~= nil then
            local scope = (bare == "" or bare == "all") and "history" or ("history:" .. bare)
            palette.show(win, p, config, { scope = scope })
            return
        end

        local git_ref = git.parse_line(line)
        if git_ref then
            if git_ref.mode == "picker" then
                palette.show(win, p, config, { scope = "git" })
                return
            elseif git_ref.mode == "run" then
                git.run_action(win, p, config, git_ref.id, git_ref.extra)
                return
            end
        end

        local function run_prepared(req_line)
            local request, err = context.prepare_request(win, p, req_line, selection, config)
            if err then
                if err:find("file not found", 1, true) then
                    local parsed = context.parse_at_refs(req_line)
                    local mode = (#parsed.edit_paths > 0) and "edit" or "attach"
                    local hint = err:match("([^/\\]+)$") or "file"
                    files.show_picker(win, p, config, {
                        mode = mode,
                        title = "No exact match — fuzzy pick a file",
                        fuzzy_description = "Filter (tried " .. hint .. "): ",
                        on_chosen = function(w2, p2, rel)
                            local rest = parsed.rest or ""
                            local rebuilt
                            if mode == "edit" then
                                rebuilt = "@@" .. rel .. (rest ~= "" and (" " .. rest) or "")
                            else
                                rebuilt = "@" .. rel .. (rest ~= "" and (" " .. rest) or "")
                            end
                            process_ask_line(w2, p2, rebuilt)
                        end,
                    })
                    return
                end
                local ai_pane = ui.ensure_ai_pane(win, p, config)
                ui.ai_print(ai_pane, "wezai: " .. err, "error")
                return
            end
            if not request then
                return
            end
            if opts.extra_context and opts.extra_context ~= "" then
                request.prompt = "Context from history:\n```\n"
                    .. context.redact(opts.extra_context)
                    .. "\n```\n\n"
                    .. (request.prompt or "")
            end
            dispatch_request(win, p, request, config, { share_pane = share_pane })
        end

        local pick = files.parse_pick_line(line)
        if pick then
            files.show_picker(win, p, config, {
                mode = pick.mode,
                on_chosen = function(w2, p2, rel)
                    local rest = pick.rest or ""
                    local rebuilt
                    if pick.mode == "edit" then
                        rebuilt = "@@" .. rel .. (rest ~= "" and (" " .. rest) or "")
                    else
                        rebuilt = "@" .. rel .. (rest ~= "" and (" " .. rest) or "")
                    end
                    if pick.mode == "edit" and (rest == "" or rest:match("^%s*$")) then
                        -- Need an edit instruction after pick
                        w2:perform_action(
                            action.PromptInputLine({
                                description = "Edit instruction for " .. rel,
                                action = wezterm.action_callback(function(w3, p3, instr)
                                    if instr == nil or instr:match("^%s*$") then
                                        return
                                    end
                                    process_ask_line(w3, p3, "@@" .. rel .. " " .. instr)
                                end),
                            }),
                            p2
                        )
                        return
                    end
                    process_ask_line(w2, p2, rebuilt)
                end,
            })
            return
        end

        -- `@pick` / `@@pick` embedded among other text
        local parsed = context.parse_at_refs(line)
        local embedded_pick = false
        local embed_mode = "attach"
        for _, syn in ipairs(parsed.synthetics) do
            if syn == "pick" then
                embedded_pick = true
            end
        end
        for _, ep in ipairs(parsed.edit_paths) do
            if ep == "pick" then
                embedded_pick = true
                embed_mode = "edit"
            end
        end
        if embedded_pick then
            files.show_picker(win, p, config, {
                mode = embed_mode,
                on_chosen = function(w2, p2, rel)
                    local rest = parsed.rest or ""
                    local rebuilt
                    if embed_mode == "edit" then
                        rebuilt = "@@" .. rel .. (rest ~= "" and (" " .. rest) or "")
                    else
                        -- keep any other non-pick path refs from the original line
                        local extras = {}
                        for _, path in ipairs(parsed.paths) do
                            extras[#extras + 1] = "@" .. path
                        end
                        rebuilt = table.concat(extras, " ")
                        if rebuilt ~= "" then
                            rebuilt = rebuilt .. " "
                        end
                        rebuilt = rebuilt .. "@" .. rel .. (rest ~= "" and (" " .. rest) or "")
                    end
                    process_ask_line(w2, p2, rebuilt)
                end,
            })
            return
        end

        run_prepared(line)
    end

    window:perform_action(
        action.PromptInputLine({
            description = description,
            action = wezterm.action_callback(function(win, p, line)
                process_ask_line(win, p, line)
            end),
        }),
        pane
    )
end

local function fix_last_error(window, pane, config)
    local ai_pane = ui.ensure_ai_pane(window, pane, config)
    local selection = util.get_selection(window, pane)
    local scroll = pane:get_logical_lines_as_text(80)
    local blob = selection or scroll
    if not blob or blob:match("^%s*$") then
        ui.ai_print(ai_pane, "Nothing to diagnose (no selection / empty scrollback).", "error")
        return
    end
    local prompt = "Diagnose this terminal error/output and propose one safe fix command.\n\n```\n"
        .. context.redact(blob)
        .. "\n```\nRespond with JSON message + command."
    handle_ai_request(window, pane, prompt, config, { user_text = "fix last error" })
end

local function explain_last_command(window, pane, config)
    local ai_pane = ui.ensure_ai_pane(window, pane, config)
    local scroll = pane:get_logical_lines_as_text(120)
    if not scroll or scroll:match("^%s*$") then
        ui.ai_print(ai_pane, "Empty scrollback.", "error")
        return
    end
    local prompt = "Explain the last command the user ran and its output. Do not invent a new command; set command to null.\n\nScrollback:\n```\n"
        .. context.redact(scroll)
        .. "\n```"
    handle_ai_request(window, pane, prompt, config, { user_text = "explain last command" })
end

local function pick_model(window, pane, config)
    local list = config.models
    if type(list) ~= "table" or #list == 0 then
        list = { config.model }
    end
    local choices = {}
    for _, m in ipairs(list) do
        local mark = (m == (config._model_override or config.model)) and " (current)" or ""
        table.insert(choices, { id = m, label = m .. mark })
    end
    ui.input_select(window, pane, "Pick model for next AI requests", choices, function(_, _, id)
        if id then
            config._model_override = id
            local ai_pane = ui.ensure_ai_pane(window, pane, config)
            ui.ai_print(ai_pane, "Model set to: " .. id, "system")
        end
    end)
end

local function show_palette(window, pane, config)
    palette.show(window, pane, config, {})
end

-- Wire history / git / palette handlers (avoids circular requires)
history._dispatch = function(win, p, request, config)
    dispatch_request(win, p, request, config, {})
end

history._explain = function(win, p, config, entry)
    local prompt = "Explain this history item. Prefer diagnosis when it looks like an error. "
        .. "Set command only if a ready-to-run fix is clearly appropriate; otherwise null.\n\n```\n"
        .. context.redact(entry.text)
        .. "\n```"
    handle_ai_request(win, p, prompt, config, { user_text = "explain history: " .. util.truncate(entry.text, 80) })
end

history._attach_ask = function(win, p, config, entry)
    prompt_for_ai(win, p, config, {
        share_pane = false,
        prefill_hint = "📎 Attached history item — type your question",
        extra_context = entry.text,
    })
end

git._ask = function(win, p, config, prompt, user_text)
    handle_ai_request(win, p, prompt, config, { user_text = user_text or "git" })
end

git._dispatch = function(win, p, request, config)
    dispatch_request(win, p, request, config, {})
end

palette.handlers = {
    ask = function(win, p, cfg)
        prompt_for_ai(win, p, cfg, { share_pane = false })
    end,
    ask_pane = function(win, p, cfg)
        prompt_for_ai(win, p, cfg, { share_pane = true })
    end,
    fix_error = function(win, p, cfg)
        fix_last_error(win, p, cfg)
    end,
    explain_cmd = function(win, p, cfg)
        explain_last_command(win, p, cfg)
    end,
    edit = function(win, p, cfg)
        prompt_for_ai(win, p, cfg, { share_pane = false })
    end,
    attach_file = function(win, p, cfg)
        files.show_picker(win, p, cfg, {
            mode = "attach",
            on_chosen = function(w2, p2, rel)
                w2:perform_action(
                    action.PromptInputLine({
                        description = "Question about @" .. rel .. " (Enter = explain file)",
                        action = wezterm.action_callback(function(w3, p3, q)
                            if q == nil then
                                return
                            end
                            local line = "@" .. rel
                            if q ~= "" and not q:match("^%s*$") then
                                line = line .. " " .. q
                            end
                            local request, err = context.prepare_request(w3, p3, line, util.get_selection(w3, p3), cfg)
                            if err then
                                ui.ai_print(ui.ensure_ai_pane(w3, p3, cfg), "wezai: " .. err, "error")
                                return
                            end
                            if request then
                                dispatch_request(w3, p3, request, cfg, {})
                            end
                        end),
                    }),
                    p2
                )
            end,
        })
    end,
    edit_file = function(win, p, cfg)
        files.show_picker(win, p, cfg, {
            mode = "edit",
            on_chosen = function(w2, p2, rel)
                w2:perform_action(
                    action.PromptInputLine({
                        description = "Edit instruction for " .. rel,
                        action = wezterm.action_callback(function(w3, p3, instr)
                            if instr == nil or instr:match("^%s*$") then
                                return
                            end
                            local line = "@@" .. rel .. " " .. instr
                            local request, err = context.prepare_request(w3, p3, line, nil, cfg)
                            if err then
                                ui.ai_print(ui.ensure_ai_pane(w3, p3, cfg), "wezai: " .. err, "error")
                                return
                            end
                            if request then
                                dispatch_request(w3, p3, request, cfg, {})
                            end
                        end),
                    }),
                    p2
                )
            end,
        })
    end,
    undo_edit = function(win, p, cfg)
        edit.undo_last_edit(win, ui.ensure_ai_pane(win, p, cfg))
    end,
    copy_cmd = function(win, p, cfg)
        local ai_pane = ui.ensure_ai_pane(win, p, cfg)
        local cmd, source = history.resolve_last_command(win, p, cfg)
        if not cmd then
            local kind = shell.detect_shell(p)
            ui.ai_print(
                ai_pane,
                "No last command found (shell="
                    .. kind
                    .. "). Run a command first, or pick an @history row → Copy.",
                "error"
            )
        elseif shell.write_clipboard(cmd) then
            ui.ai_print(
                ai_pane,
                "Copied (" .. (source or "?") .. "): " .. util.truncate(cmd, 120),
                "success"
            )
        else
            ui.ai_print(ai_pane, "Could not copy to clipboard.", "error")
        end
    end,
    shorter = function(win, p, cfg)
        local ai_pane = ui.ensure_ai_pane(win, p, cfg)
        local q = session.get_last_question(win)
        if not q then
            ui.ai_print(ai_pane, "No previous question.", "error")
        else
            handle_ai_request(
                win,
                p,
                "Answer more briefly.\n\nOriginal question: " .. q,
                cfg,
                { user_text = q .. " (shorter)" }
            )
        end
    end,
    pick_model = function(win, p, cfg)
        pick_model(win, p, cfg)
    end,
    clear = function(win, p, cfg)
        session.clear(win)
        ui.ai_print(ui.ensure_ai_pane(win, p, cfg), "Chat memory cleared.", "system")
    end,
}

local function apply_to_config(wezterm_config, user_config)
    local config = settings.finalize(user_config)
    settings.maybe_extend_rocks_path(config)

    if not providers.ready(config) then
        wezterm.log_error("wezai: backend config rejected")
        return
    end

    if wezterm_config.keys == nil then
        wezterm_config.keys = {}
    end

    table.insert(wezterm_config.keys, {
        key = config.keybinding.key,
        mods = config.keybinding.mods,
        action = wezterm.action_callback(function(window, pane)
            prompt_for_ai(window, pane, config, { share_pane = false })
        end),
    })

    table.insert(wezterm_config.keys, {
        key = config.keybinding_with_pane.key,
        mods = config.keybinding_with_pane.mods,
        action = wezterm.action_callback(function(window, pane)
            prompt_for_ai(window, pane, config, { share_pane = true })
        end),
    })

    local function bind_key(key, mods, action)
        table.insert(wezterm_config.keys, {
            key = key,
            mods = mods,
            action = action,
        })
        -- WezTerm defaults sometimes use the opposite case (e.g. Ctrl+Shift+P)
        local alt = key
        if type(key) == "string" and #key == 1 then
            local lower = key:lower()
            local upper = key:upper()
            if key == lower and upper ~= lower then
                alt = upper
            elseif key == upper and lower ~= upper then
                alt = lower
            else
                alt = nil
            end
            if alt then
                table.insert(wezterm_config.keys, {
                    key = alt,
                    mods = mods,
                    action = action,
                })
            end
        end
    end

    local open_full = wezterm.action_callback(function(window, pane)
        show_palette(window, pane, config)
    end)
    bind_key(config.keybinding_palette.key, config.keybinding_palette.mods, open_full)

    -- Optional scoped shortcuts → same unified palette
    if type(config.keybinding_history) == "table" and config.keybinding_history.key then
        bind_key(
            config.keybinding_history.key,
            config.keybinding_history.mods,
            wezterm.action_callback(function(window, pane)
                palette.show(window, pane, config, { scope = "history" })
            end)
        )
    end

    if type(config.keybinding_git) == "table" and config.keybinding_git.key then
        bind_key(
            config.keybinding_git.key,
            config.keybinding_git.mods,
            wezterm.action_callback(function(window, pane)
                palette.show(window, pane, config, { scope = "git" })
            end)
        )
    end

    wezterm.log_info(
        "wezai loaded model="
            .. config.model
            .. " type="
            .. config.type
            .. " shell_fallback="
            .. shell.env_shell()
            .. " palette="
            .. config.keybinding_palette.mods
            .. "+"
            .. config.keybinding_palette.key
            .. " (dialect injected per ask from the active shell pane)"
    )
end

return {
    apply_to_config = apply_to_config,
}
