-- @docker catalog for wezai — local containers and compose.
-- Show/shell actions are no-model; AI helpers diagnose from ps/logs/selection.
-- Mutating restart/rm/compose-down confirm first.
local wezterm = require("wezterm")
local act = wezterm.action
local util = require("util")
local ui = require("ui")
local shell = require("shell")

local M = {}

-- Wired by init.lua
M._ask = nil
M._dispatch = nil

local MAX_ATTACH = 80000

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$") or ""
end

local function docker_opts(config)
    local d = (config and config.docker) or {}
    return {
        docker = d.docker,
        confirm_mutate = d.confirm_mutate ~= false,
        max_attach_bytes = d.max_attach_bytes or MAX_ATTACH,
    }
end

local function cap(text, max_bytes)
    text = text or ""
    max_bytes = max_bytes or MAX_ATTACH
    if #text <= max_bytes then
        return text
    end
    return text:sub(1, max_bytes) .. "\n… (truncated)"
end

local function redact(text)
    return require("context").redact(text)
end

-- Cached absolute docker for WezTerm's process (GUI PATH is often incomplete).
local _docker_resolved = nil

local function home_dir()
    return wezterm.home_dir or os.getenv("HOME") or ""
end

function M.docker_bin(config)
    local override = docker_opts(config).docker
    if override and override ~= "" then
        return override
    end
    if _docker_resolved then
        return _docker_resolved
    end
    local home = home_dir()
    local found = util.resolve_executable("docker", {
        candidates = {
            "/opt/homebrew/bin/docker",
            "/usr/local/bin/docker",
            "/usr/bin/docker",
            home .. "/.local/bin/docker",
            home .. "/.docker/bin/docker",
            home .. "/bin/docker",
        },
        login_shell = true,
    })
    _docker_resolved = found or "docker"
    return _docker_resolved
end

local function docker_run(config, args)
    local cmd = { M.docker_bin(config) }
    for _, a in ipairs(args) do
        table.insert(cmd, a)
    end
    return util.run_cmd(cmd)
end

local function compose_run(config, cwd, args)
    local cmd = { M.docker_bin(config), "compose", "--project-directory", cwd }
    for _, a in ipairs(args) do
        table.insert(cmd, a)
    end
    return util.run_cmd(cmd)
end

function M.ensure_cwd(pane)
    local cwd = util.get_pane_cwd(pane)
    if not cwd then
        return nil, "no pane cwd (open a shell where compose files live)"
    end
    return cwd, nil
end

local function print_show(ai_pane, title, body)
    ui.ai_print(ai_pane, title, "attach")
    ui.ai_print(ai_pane, body ~= "" and body or "(empty)", "plain")
end

local function prompt_line(window, pane, description, callback)
    window:perform_action(
        act.PromptInputLine({
            description = description,
            action = wezterm.action_callback(function(win, p, line)
                if line == nil then
                    return
                end
                callback(win, p, trim(line))
            end),
        }),
        pane
    )
end

local function run_in_shell(window, shell_pane, ai_pane, config, command, opts)
    opts = opts or {}
    local execute = opts.execute ~= false
    local force_confirm = opts.confirm == true

    local function send(skip_risk)
        shell.send_command(window, shell_pane, ai_pane, config, command, function(sent)
            if sent and execute then
                shell_pane:send_text("\r")
                ui.ai_print(ai_pane, "Ran: " .. util.truncate(command, 120), "success")
            elseif sent then
                ui.ai_print(ai_pane, "Inserted: " .. util.truncate(command, 120), "success")
            end
        end, { skip_risk_confirm = skip_risk })
    end

    if force_confirm then
        ui.ai_print(ai_pane, "About to run:\n" .. command, "warn")
        ui.confirm(window, shell_pane, "Run docker: " .. util.truncate(command, 50) .. " ?", "run", function(_, _, yes)
            if yes then
                send(true)
            else
                ui.ai_print(ai_pane, "Cancelled.", "warn")
            end
        end)
    else
        send(false)
    end
end

local function still_needs_placeholder(cmd)
    return cmd:find("<[%w%-]+>", 1) ~= nil
end

local function fill_placeholder(cmd, token, value)
    if not value or value == "" then
        return cmd
    end
    return cmd:gsub("<" .. token:gsub("%-", "%%-") .. ">", value)
end

--- Fill remaining placeholders via prompts, then insert/run.
local function finalize_command(ctx, template, opts)
    opts = opts or {}
    local extra = trim(ctx.extra or "")
    local cmd = template
    local mutate = opts.mutate == true
    local confirm = mutate and docker_opts(ctx.config).confirm_mutate

    if extra ~= "" then
        if cmd:find("<container>", 1, true) then
            cmd = fill_placeholder(cmd, "container", extra)
        elseif cmd:find("<image>", 1, true) then
            cmd = fill_placeholder(cmd, "image", extra)
        elseif cmd:find("<service>", 1, true) then
            cmd = fill_placeholder(cmd, "service", extra)
        end
    end

    local function after_filled(final_cmd)
        if still_needs_placeholder(final_cmd) then
            ui.ai_print(ctx.ai_pane, "Command still has placeholders — edit then Enter:\n" .. final_cmd, "warn")
            run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, final_cmd, {
                execute = false,
                confirm = false,
            })
            return
        end
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, final_cmd, {
            execute = opts.execute ~= false,
            confirm = confirm,
        })
    end

    local function step_image(c)
        if c:find("<image>", 1, true) then
            prompt_line(ctx.window, ctx.pane, "Image name (e.g. nginx:latest)", function(_, _, image)
                if image == "" then
                    return
                end
                after_filled(fill_placeholder(c, "image", image))
            end)
            return
        end
        after_filled(c)
    end

    local function step_service(c)
        if c:find("<service>", 1, true) then
            prompt_line(ctx.window, ctx.pane, "Compose service name", function(_, _, service)
                if service == "" then
                    return
                end
                after_filled(fill_placeholder(c, "service", service))
            end)
            return
        end
        step_image(c)
    end

    if cmd:find("<container>", 1, true) then
        prompt_line(ctx.window, ctx.pane, "Container name or id", function(_, _, name)
            if name == "" then
                return
            end
            step_service(fill_placeholder(cmd, "container", name))
        end)
        return
    end
    step_service(cmd)
end

local function show_cmd(ctx, title, args)
    local ok, stdout, stderr = docker_run(ctx.config, args)
    local body = ok and stdout or (stderr ~= "" and stderr or stdout)
    if ok and trim(body) == "" then
        body = "(no containers / empty output)"
    end
    print_show(ctx.ai_pane, title, cap(body, docker_opts(ctx.config).max_attach_bytes))
end

local function show_compose(ctx, title, args)
    local ok, stdout, stderr = compose_run(ctx.config, ctx.cwd, args)
    local body = ok and stdout or (stderr ~= "" and stderr or stdout)
    if ok and trim(body) == "" then
        body = "(no compose services in " .. ctx.cwd .. ")"
    end
    print_show(ctx.ai_pane, title .. "  (cwd=" .. ctx.cwd .. ")", cap(body, docker_opts(ctx.config).max_attach_bytes))
end

local function ask_ai(ctx, prompt, user_text)
    if M._ask then
        M._ask(ctx.window, ctx.pane, ctx.config, prompt, user_text)
    else
        ui.ai_print(ctx.ai_pane, "Docker AI hook not wired.", "error")
    end
end

local function positive_count(raw)
    local n = tonumber(raw)
    if n and n == math.floor(n) and n >= 1 then
        return n
    end
    return nil
end

-- Peel trailing N from logs200 / logs-f50 / compose-logs100.
local function split_tail_id(id)
    id = id or ""
    for _, base in ipairs({ "compose-logs", "logs-f", "logs" }) do
        local n = id:match("^" .. base:gsub("%-", "%%-") .. "(%d+)$")
        if n then
            return base, tonumber(n)
        end
    end
    return id, nil
end

local function logs_tail(ctx, default_n)
    if ctx.count then
        local n = positive_count(ctx.count)
        if n then
            return n
        end
    end
    local n = positive_count(ctx.extra)
    if n then
        return n
    end
    return default_n
end

-- --- Attach collectors (shared with context.lua) ---

function M.collect_ps(config, all)
    local args = { "ps", "--format", "table" }
    if all then
        args = { "ps", "-a", "--format", "table" }
    end
    local ok, stdout, stderr = docker_run(config, args)
    if not ok then
        return nil, stderr ~= "" and stderr or stdout
    end
    return stdout ~= "" and stdout or "(no containers)", nil
end

function M.collect_images(config)
    local ok, stdout, stderr = docker_run(config, { "images", "--format", "table" })
    if not ok then
        return nil, stderr ~= "" and stderr or stdout
    end
    return stdout ~= "" and stdout or "(no images)", nil
end

function M.collect_compose_ps(cwd, config)
    local ok, stdout, stderr = compose_run(config, cwd, { "ps" })
    if not ok then
        return nil, stderr ~= "" and stderr or stdout
    end
    return stdout ~= "" and stdout or "(no compose services)", nil
end

function M.collect_df(config)
    local ok, stdout, stderr = docker_run(config, { "system", "df" })
    if not ok then
        return nil, stderr ~= "" and stderr or stdout
    end
    return stdout ~= "" and stdout or "(empty)", nil
end

function M.collect_attach(syn, cwd, config)
    local raw = syn:match("^docker:(.+)$") or syn
    local id = trim(raw)
    local maxb = docker_opts(config).max_attach_bytes
    if id == "ps" then
        local body, err = M.collect_ps(config, false)
        return body and cap(body, maxb) or nil, err
    elseif id == "ps-a" or id == "psa" then
        local body, err = M.collect_ps(config, true)
        return body and cap(body, maxb) or nil, err
    elseif id == "images" then
        local body, err = M.collect_images(config)
        return body and cap(body, maxb) or nil, err
    elseif id == "compose-ps" or id == "compose" then
        if not cwd then
            return nil, "compose attach needs pane cwd"
        end
        local body, err = M.collect_compose_ps(cwd, config)
        return body and cap(body, maxb) or nil, err
    elseif id == "df" or id == "system-df" then
        local body, err = M.collect_df(config)
        return body and cap(body, maxb) or nil, err
    end
    return nil, "unknown @docker attach: " .. tostring(syn)
end

-- --- Actions ---

local ACTIONS = {}
local ACTION_ORDER = {}

local function add(a)
    ACTIONS[a.id] = a
    table.insert(ACTION_ORDER, a.id)
    if a.aliases then
        for _, al in ipairs(a.aliases) do
            ACTIONS[al] = a
        end
    end
end

add({
    id = "ps",
    kind = "show",
    label = "docker ps (running)",
    attach = true,
    run = function(ctx)
        show_cmd(ctx, "@docker:ps", { "ps", "--format", "table" })
    end,
})

add({
    id = "ps-a",
    kind = "show",
    label = "docker ps -a (all)",
    aliases = { "psa" },
    attach = true,
    run = function(ctx)
        show_cmd(ctx, "@docker:ps-a", { "ps", "-a", "--format", "table" })
    end,
})

add({
    id = "images",
    kind = "show",
    label = "docker images",
    attach = true,
    run = function(ctx)
        show_cmd(ctx, "@docker:images", { "images", "--format", "table" })
    end,
})

add({
    id = "compose-ps",
    kind = "show",
    label = "docker compose ps",
    aliases = { "compose" },
    attach = true,
    run = function(ctx)
        show_compose(ctx, "@docker:compose-ps", { "ps" })
    end,
})

add({
    id = "df",
    kind = "show",
    label = "docker system df",
    aliases = { "system-df" },
    attach = true,
    run = function(ctx)
        show_cmd(ctx, "@docker:df", { "system", "df" })
    end,
})

add({
    id = "logs",
    kind = "shell",
    label = "logsN <container> — --tail=N (default 200)",
    run = function(ctx)
        local tail = logs_tail(ctx, 200)
        local extra = trim(ctx.extra or "")
        if positive_count(extra) then
            ctx.extra = ""
        end
        finalize_command(ctx, "docker logs --tail=" .. tail .. " <container>", { execute = true })
    end,
})

add({
    id = "logs-f",
    kind = "shell",
    label = "logs-fN <container> — follow --tail=N (default 100)",
    aliases = { "logs-follow" },
    run = function(ctx)
        local tail = logs_tail(ctx, 100)
        local extra = trim(ctx.extra or "")
        if positive_count(extra) then
            ctx.extra = ""
        end
        finalize_command(ctx, "docker logs -f --tail=" .. tail .. " <container>", { execute = true })
    end,
})

add({
    id = "exec",
    kind = "shell",
    label = "exec -it <container> sh",
    run = function(ctx)
        finalize_command(ctx, "docker exec -it <container> sh", { execute = true })
    end,
})

add({
    id = "compose-up",
    kind = "shell",
    label = "docker compose up -d",
    run = function(ctx)
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, "docker compose up -d", { execute = true })
    end,
})

add({
    id = "compose-down",
    kind = "shell",
    label = "docker compose down (confirm)",
    run = function(ctx)
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, "docker compose down", {
            execute = true,
            confirm = docker_opts(ctx.config).confirm_mutate,
        })
    end,
})

add({
    id = "compose-logs",
    kind = "shell",
    label = "compose-logsN — compose logs --tail=N (default 200)",
    run = function(ctx)
        local tail = logs_tail(ctx, 200)
        local extra = trim(ctx.extra or "")
        if positive_count(extra) then
            extra = ""
        end
        local cmd = "docker compose logs --tail=" .. tail
        if extra ~= "" then
            cmd = cmd .. " " .. extra
        end
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, cmd, { execute = true })
    end,
})

add({
    id = "pull",
    kind = "shell",
    label = "docker pull <image>",
    run = function(ctx)
        finalize_command(ctx, "docker pull <image>", { execute = true })
    end,
})

add({
    id = "restart",
    kind = "shell",
    label = "docker restart <container> (confirm)",
    run = function(ctx)
        finalize_command(ctx, "docker restart <container>", { execute = true, mutate = true })
    end,
})

add({
    id = "rm",
    kind = "shell",
    label = "docker rm <container> (confirm)",
    run = function(ctx)
        finalize_command(ctx, "docker rm <container>", { execute = true, mutate = true })
    end,
})

add({
    id = "diagnose",
    kind = "ai",
    label = "diagnose running containers / compose",
    run = function(ctx)
        local ps_body, ps_err = M.collect_ps(ctx.config, true)
        local compose_body = nil
        if ctx.cwd then
            local body, err = M.collect_compose_ps(ctx.cwd, ctx.config)
            compose_body = (err and err ~= "") and err or body
        end
        local sel = util.get_selection(ctx.window, ctx.pane)
        local extra = trim(ctx.extra or "")
        local prompt = "Diagnose these Docker / Compose containers. "
            .. "Prefer read-only next steps (docker ps, logs, compose ps, inspect). "
            .. "Never bake hostnames into commands. Use placeholders like <container> / <service>. "
            .. "Set command to a single safe next step or null.\n\n=== docker ps -a ===\n```\n"
            .. redact(cap((ps_err and ps_err ~= "") and ps_err or (ps_body or ""), 40000))
            .. "\n```"
        if compose_body and compose_body ~= "" then
            prompt = prompt
                .. "\n\n=== docker compose ps ("
                .. ctx.cwd
                .. ") ===\n```\n"
                .. redact(cap(compose_body, 20000))
                .. "\n```"
        end
        if sel and sel ~= "" then
            prompt = prompt .. "\n\n=== selection ===\n```\n" .. redact(cap(sel, 12000)) .. "\n```"
        end
        if extra ~= "" then
            prompt = prompt .. "\n\nUser instruction: " .. extra
        end
        ask_ai(ctx, prompt, extra ~= "" and extra or "docker:diagnose")
    end,
})

add({
    id = "explain-sel",
    kind = "ai",
    label = "explain selected docker output",
    aliases = { "explain" },
    run = function(ctx)
        local sel = util.get_selection(ctx.window, ctx.pane)
        if not sel or trim(sel) == "" then
            ui.ai_print(ctx.ai_pane, "Select docker/compose output first, then @docker:explain-sel", "error")
            return
        end
        local extra = trim(ctx.extra or "")
        local prompt = "Explain this Docker / Compose output. Prefer diagnosis when it looks like an error. "
            .. "Set command to a single safe next step (logs/ps/inspect) or null.\n\n```\n"
            .. redact(cap(sel, 40000))
            .. "\n```"
        if extra ~= "" then
            prompt = prompt .. "\n\nUser instruction: " .. extra
        end
        ask_ai(ctx, prompt, extra ~= "" and extra or "docker:explain-sel")
    end,
})

function M.list_actions()
    local list = {}
    for _, id in ipairs(ACTION_ORDER) do
        local a = ACTIONS[id]
        if a and a.id == id then
            table.insert(list, a)
        end
    end
    return list
end

function M.get_action(id)
    local a = ACTIONS[id]
    if a then
        return a
    end
    local base = select(1, split_tail_id(id))
    if base ~= id then
        return ACTIONS[base]
    end
    return nil
end

-- Parse ask-line for docker intercept.
-- Returns nil (not docker), or { mode="picker"|"run"|"attach", id?, extra?, count? }
function M.parse_line(line)
    local token = trim(line or "")
    if token == "@docker" or token == "@docker:" then
        return { mode = "picker" }
    end
    local rest_only = token:match("^@docker%s+(.+)$")
    if rest_only then
        return { mode = "attach", id = "ps" }
    end
    local id, rest = token:match("^@docker:([%w%-]+)%s*(.-)%s*$")
    if not id then
        return nil
    end
    local embedded_n
    id, embedded_n = split_tail_id(id)
    local action = ACTIONS[id]
    if not action then
        return nil
    end
    rest = trim(rest or "")
    local count = embedded_n
    if not count and (id == "logs" or id == "logs-f" or id == "compose-logs") and positive_count(rest) then
        count = positive_count(rest)
        rest = ""
    end
    if rest == "" and not count then
        return { mode = "run", id = action.id }
    end
    if action.kind == "ai" then
        local out = { mode = "run", id = action.id }
        if rest ~= "" then
            out.extra = rest
        end
        return out
    end
    if (action.attach or action.kind == "show") and rest ~= "" then
        return { mode = "attach", id = action.id }
    end
    local out = { mode = "run", id = action.id }
    if rest ~= "" then
        out.extra = rest
    end
    if count then
        out.count = count
    end
    return out
end

function M.run_action(window, pane, config, id, extra, opts)
    opts = opts or {}
    local shell_pane = ui.shell_pane_for(window, pane)
    local ai_pane = ui.ensure_ai_pane(window, shell_pane, config)
    local cwd = util.get_pane_cwd(shell_pane)
    local embedded_n
    id, embedded_n = split_tail_id(id)
    local action = ACTIONS[id]
    if not action then
        ui.ai_print(ai_pane, "Unknown @docker:" .. tostring(id) .. " — try @docker for the picker", "error")
        return
    end
    local count = opts.count or embedded_n
    local ctx = {
        window = window,
        pane = shell_pane,
        ai_pane = ai_pane,
        config = config,
        cwd = cwd,
        extra = extra,
        count = count,
    }
    local function go()
        if action.kind == "show" or action.kind == "ai" then
            local bin = M.docker_bin(config)
            local ok, _, verr = util.run_cmd({ bin, "version", "--format", "{{.Client.Version}}" })
            if not ok then
                ui.ai_print(
                    ai_pane,
                    "docker not available ("
                        .. tostring(bin)
                        .. "): "
                        .. tostring(verr)
                        .. "\nSet docker.docker = \"/absolute/path/to/docker\" in wezai config if needed.",
                    "error"
                )
                return
            end
        end
        if (action.id == "compose-ps" or action.id == "compose-up" or action.id == "compose-down" or action.id == "compose-logs")
            and not cwd
        then
            ui.ai_print(ai_pane, "no pane cwd (open a shell in a compose project)", "error")
            return
        end
        action.run(ctx)
    end
    if action.kind == "show" then
        ui.with_busy(ai_pane, {
            title = "docker",
            command = "@docker:" .. action.id,
            config = config,
        }, go)
        return
    end
    go()
end

function M.open_picker(window, pane, config)
    require("palette").show(window, pane, config, { scope = "docker" })
end

return M
