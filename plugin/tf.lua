-- @tf catalog for wezai — terraform helpers.
-- Show/shell actions are no-model; AI helpers generate and debug HCL.
-- Mutating apply/destroy/state-rm/unlock confirm first.
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
local MAX_TF_FILE = 40000

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$") or ""
end

local function tf_opts(config)
    local t = (config and config.tf) or {}
    return {
        terraform = t.terraform,
        confirm_mutate = t.confirm_mutate ~= false,
        max_attach_bytes = t.max_attach_bytes or MAX_ATTACH,
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

-- Cached absolute terraform for WezTerm's process (GUI PATH is often incomplete).
local _tf_resolved = nil

local function home_dir()
    return wezterm.home_dir or os.getenv("HOME") or ""
end

function M.terraform_bin(config)
    local override = tf_opts(config).terraform
    if override and override ~= "" then
        return override
    end
    if _tf_resolved then
        return _tf_resolved
    end
    local home = home_dir()
    local found = util.resolve_executable("terraform", {
        candidates = {
            "/opt/homebrew/bin/terraform",
            "/usr/local/bin/terraform",
            "/usr/bin/terraform",
            home .. "/.local/bin/terraform",
            home .. "/.asdf/shims/terraform",
            home .. "/.mise/shims/terraform",
            home .. "/bin/terraform",
        },
        login_shell = true,
    })
    _tf_resolved = found or "terraform"
    return _tf_resolved
end

local function tf_cmd(cwd, args, config)
    local cmd = { M.terraform_bin(config), "-chdir=" .. cwd }
    for _, a in ipairs(args) do
        table.insert(cmd, a)
    end
    return util.run_cmd(cmd)
end

function M.ensure_cwd(pane)
    local cwd = util.get_pane_cwd(pane)
    if not cwd then
        return nil, "no pane cwd (open a shell in a terraform directory)"
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
        ui.confirm(window, shell_pane, "Run terraform: " .. util.truncate(command, 50) .. " ?", "run", function(_, _, yes)
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

local function show_cmd(ctx, title, args)
    local ok, stdout, stderr = tf_cmd(ctx.cwd, args, ctx.config)
    local body = ok and stdout or (stderr ~= "" and stderr or stdout)
    if ok and trim(body) == "" then
        body = "(empty output)"
    end
    print_show(ctx.ai_pane, title .. "  (cwd=" .. ctx.cwd .. ")", cap(body, tf_opts(ctx.config).max_attach_bytes))
end

local function ask_ai(ctx, prompt, user_text)
    if M._ask then
        M._ask(ctx.window, ctx.pane, ctx.config, prompt, user_text)
    else
        ui.ai_print(ctx.ai_pane, "Terraform AI hook not wired.", "error")
    end
end

--- Collect *.tf / *.tf.json from cwd (shallow) for AI helpers.
function M.collect_tf_sources(cwd, max_bytes)
    max_bytes = max_bytes or MAX_ATTACH
    local ok, stdout, stderr = util.run_cmd({
        "sh",
        "-c",
        'cd "$1" && ls -1 *.tf *.tf.json 2>/dev/null | head -n 40',
        "sh",
        cwd,
    })
    if not ok then
        return nil, stderr ~= "" and stderr or "failed to list .tf files"
    end
    local names = {}
    for line in ((stdout or "") .. "\n"):gmatch("(.-)\n") do
        line = trim(line)
        if line ~= "" then
            table.insert(names, line)
        end
    end
    if #names == 0 then
        return "(no *.tf / *.tf.json in " .. cwd .. ")", nil
    end
    local parts = {}
    local used = 0
    local per = math.max(4000, math.floor(max_bytes / math.max(#names, 1)))
    per = math.min(per, MAX_TF_FILE)
    for _, name in ipairs(names) do
        if used >= max_bytes then
            table.insert(parts, "… (more files omitted)")
            break
        end
        local abs = cwd .. util.separator .. name
        local rok, content = util.read_text_file(abs, per)
        if rok then
            table.insert(parts, "===== " .. name .. " =====\n" .. content)
            used = used + #content
        else
            table.insert(parts, "===== " .. name .. " =====\n(unreadable)")
        end
    end
    return cap(table.concat(parts, "\n\n"), max_bytes), nil
end

-- --- Attach collectors (shared with context.lua) ---

function M.collect_version(cwd, config)
    local ok, stdout, stderr = tf_cmd(cwd, { "version" }, config)
    if not ok then
        return nil, stderr ~= "" and stderr or stdout
    end
    return stdout ~= "" and stdout or "(empty)", nil
end

function M.collect_validate(cwd, config)
    local ok, stdout, stderr = tf_cmd(cwd, { "validate", "-no-color" }, config)
    local body = trim((stdout or "") .. ((stderr and stderr ~= "") and ("\n" .. stderr) or ""))
    if body == "" then
        body = ok and "Success! The configuration is valid." or "terraform validate failed"
    end
    if not ok then
        return body, nil -- still attach failure output for AI
    end
    return body, nil
end

function M.collect_providers(cwd, config)
    local ok, stdout, stderr = tf_cmd(cwd, { "providers" }, config)
    if not ok then
        return nil, stderr ~= "" and stderr or stdout
    end
    return stdout ~= "" and stdout or "(no providers)", nil
end

function M.collect_workspace(cwd, config)
    local ok_s, show = tf_cmd(cwd, { "workspace", "show" }, config)
    local ok_l, list = tf_cmd(cwd, { "workspace", "list" }, config)
    local parts = {
        "current: " .. (ok_s and trim(show) or "?"),
        "",
        ok_l and list or "(workspace list failed)",
    }
    return table.concat(parts, "\n"), nil
end

function M.collect_state(cwd, config)
    local ok, stdout, stderr = tf_cmd(cwd, { "state", "list" }, config)
    if not ok then
        return nil, stderr ~= "" and stderr or stdout
    end
    return stdout ~= "" and stdout or "(empty state)", nil
end

function M.collect_output(cwd, config)
    local ok, stdout, stderr = tf_cmd(cwd, { "output", "-no-color" }, config)
    if not ok then
        return nil, stderr ~= "" and stderr or stdout
    end
    return stdout ~= "" and stdout or "(no outputs)", nil
end

function M.collect_fmt_check(cwd, config)
    local ok, stdout, stderr = tf_cmd(cwd, { "fmt", "-check", "-diff", "-recursive" }, config)
    local body = trim((stdout or "") .. ((stderr and stderr ~= "") and ("\n" .. stderr) or ""))
    if body == "" then
        body = ok and "(fmt clean — no changes needed)" or "terraform fmt -check failed"
    end
    return body, nil
end

function M.collect_attach(syn, cwd, config)
    local raw = syn:match("^tf:(.+)$") or syn
    local id = trim(raw)
    local maxb = tf_opts(config).max_attach_bytes
    if id == "version" then
        local body, err = M.collect_version(cwd, config)
        return body and cap(body, maxb) or nil, err
    elseif id == "validate" then
        local body, err = M.collect_validate(cwd, config)
        return body and cap(body, maxb) or nil, err
    elseif id == "providers" then
        local body, err = M.collect_providers(cwd, config)
        return body and cap(body, maxb) or nil, err
    elseif id == "workspace" or id == "ws" then
        local body, err = M.collect_workspace(cwd, config)
        return body and cap(body, maxb) or nil, err
    elseif id == "state" then
        local body, err = M.collect_state(cwd, config)
        return body and cap(body, maxb) or nil, err
    elseif id == "output" or id == "outputs" then
        local body, err = M.collect_output(cwd, config)
        return body and cap(body, maxb) or nil, err
    elseif id == "fmt-check" or id == "fmtcheck" then
        local body, err = M.collect_fmt_check(cwd, config)
        return body and cap(body, maxb) or nil, err
    elseif id == "sources" or id == "files" then
        return M.collect_tf_sources(cwd, maxb)
    end
    return nil, "unknown @tf attach: " .. tostring(syn)
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

-- Show (no model)
add({
    id = "version",
    kind = "show",
    label = "terraform version",
    attach = true,
    run = function(ctx)
        show_cmd(ctx, "@tf:version", { "version" })
    end,
})

add({
    id = "validate",
    kind = "show",
    label = "terraform validate",
    attach = true,
    run = function(ctx)
        show_cmd(ctx, "@tf:validate", { "validate", "-no-color" })
    end,
})

add({
    id = "providers",
    kind = "show",
    label = "terraform providers",
    attach = true,
    run = function(ctx)
        show_cmd(ctx, "@tf:providers", { "providers" })
    end,
})

add({
    id = "workspace",
    kind = "show",
    label = "workspace show + list",
    aliases = { "ws" },
    attach = true,
    run = function(ctx)
        local body = select(1, M.collect_workspace(ctx.cwd, ctx.config)) or ""
        print_show(ctx.ai_pane, "@tf:workspace  (cwd=" .. ctx.cwd .. ")", body)
    end,
})

add({
    id = "state",
    kind = "show",
    label = "terraform state list",
    attach = true,
    run = function(ctx)
        show_cmd(ctx, "@tf:state", { "state", "list" })
    end,
})

add({
    id = "output",
    kind = "show",
    label = "terraform output",
    aliases = { "outputs" },
    attach = true,
    run = function(ctx)
        show_cmd(ctx, "@tf:output", { "output", "-no-color" })
    end,
})

add({
    id = "fmt-check",
    kind = "show",
    label = "terraform fmt -check -diff",
    aliases = { "fmtcheck" },
    attach = true,
    run = function(ctx)
        local body = select(1, M.collect_fmt_check(ctx.cwd, ctx.config)) or ""
        print_show(ctx.ai_pane, "@tf:fmt-check  (cwd=" .. ctx.cwd .. ")", cap(body, tf_opts(ctx.config).max_attach_bytes))
    end,
})

-- Shell shortcuts (no model)
add({
    id = "init",
    kind = "shell",
    label = "terraform init",
    run = function(ctx)
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, "terraform init", { execute = true })
    end,
})

add({
    id = "fmt",
    kind = "shell",
    label = "terraform fmt -recursive",
    run = function(ctx)
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, "terraform fmt -recursive", { execute = true })
    end,
})

add({
    id = "plan",
    kind = "shell",
    label = "terraform plan",
    run = function(ctx)
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, "terraform plan", { execute = true })
    end,
})

add({
    id = "apply",
    kind = "shell",
    label = "terraform apply (confirm)",
    mutate = true,
    run = function(ctx)
        local confirm = tf_opts(ctx.config).confirm_mutate
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, "terraform apply", {
            execute = true,
            confirm = confirm,
        })
    end,
})

add({
    id = "destroy",
    kind = "shell",
    label = "terraform destroy (confirm)",
    mutate = true,
    run = function(ctx)
        local confirm = tf_opts(ctx.config).confirm_mutate
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, "terraform destroy", {
            execute = true,
            confirm = confirm,
        })
    end,
})

add({
    id = "refresh",
    kind = "shell",
    label = "terraform apply -refresh-only",
    run = function(ctx)
        run_in_shell(
            ctx.window,
            ctx.pane,
            ctx.ai_pane,
            ctx.config,
            "terraform apply -refresh-only",
            { execute = true }
        )
    end,
})

add({
    id = "import",
    kind = "shell",
    label = "terraform import <addr> <id>",
    mutate = true,
    run = function(ctx)
        prompt_line(ctx.window, ctx.pane, "Resource address (e.g. aws_instance.web)", function(win, p, addr)
            if addr == "" then
                return
            end
            prompt_line(win, p, "Provider ID to import", function(win2, p2, id)
                if id == "" then
                    return
                end
                local ap = ui.ensure_ai_pane(win2, p2, ctx.config)
                local cmd = "terraform import " .. addr .. " " .. id
                run_in_shell(win2, p2, ap, ctx.config, cmd, {
                    execute = true,
                    confirm = tf_opts(ctx.config).confirm_mutate,
                })
            end)
        end)
    end,
})

add({
    id = "workspace-select",
    kind = "shell",
    label = "terraform workspace select <name>",
    aliases = { "ws-select" },
    run = function(ctx)
        local from_extra = trim(ctx.extra or "")
        local function go(name)
            if not name or name == "" then
                return
            end
            run_in_shell(
                ctx.window,
                ctx.pane,
                ctx.ai_pane,
                ctx.config,
                "terraform workspace select " .. name,
                { execute = true }
            )
        end
        if from_extra ~= "" then
            go(from_extra:match("^(%S+)") or from_extra)
            return
        end
        prompt_line(ctx.window, ctx.pane, "Workspace name to select", function(_, _, name)
            go(name)
        end)
    end,
})

add({
    id = "workspace-new",
    kind = "shell",
    label = "terraform workspace new <name>",
    aliases = { "ws-new" },
    run = function(ctx)
        local from_extra = trim(ctx.extra or "")
        local function go(name)
            if not name or name == "" then
                return
            end
            run_in_shell(
                ctx.window,
                ctx.pane,
                ctx.ai_pane,
                ctx.config,
                "terraform workspace new " .. name,
                { execute = true }
            )
        end
        if from_extra ~= "" then
            go(from_extra:match("^(%S+)") or from_extra)
            return
        end
        prompt_line(ctx.window, ctx.pane, "New workspace name", function(_, _, name)
            go(name)
        end)
    end,
})

add({
    id = "state-rm",
    kind = "shell",
    label = "terraform state rm <addr> (confirm)",
    mutate = true,
    run = function(ctx)
        prompt_line(ctx.window, ctx.pane, "Address to remove from state (not destroy)", function(_, _, addr)
            if addr == "" then
                return
            end
            run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, "terraform state rm " .. addr, {
                execute = true,
                confirm = tf_opts(ctx.config).confirm_mutate,
            })
        end)
    end,
})

add({
    id = "unlock",
    kind = "shell",
    label = "terraform force-unlock <LOCK_ID> (confirm)",
    mutate = true,
    run = function(ctx)
        local from_extra = trim(ctx.extra or "")
        local function go(lock_id)
            if not lock_id or lock_id == "" then
                return
            end
            run_in_shell(
                ctx.window,
                ctx.pane,
                ctx.ai_pane,
                ctx.config,
                "terraform force-unlock " .. lock_id,
                {
                    execute = true,
                    confirm = true,
                }
            )
        end
        if from_extra ~= "" then
            go(from_extra:match("^(%S+)") or from_extra)
            return
        end
        prompt_line(ctx.window, ctx.pane, "Lock ID (from error message)", function(_, _, lock_id)
            go(lock_id)
        end)
    end,
})

-- AI helpers: generate + debug terraform
add({
    id = "generate",
    kind = "ai",
    label = "AI: generate Terraform from description",
    aliases = { "gen", "new" },
    run = function(ctx)
        local instruction = trim(ctx.extra or "")
        if instruction == "" then
            prompt_line(ctx.window, ctx.pane, "Describe the Terraform to generate", function(win, p, desc)
                if desc == "" then
                    return
                end
                ACTIONS.generate.run({
                    window = win,
                    pane = p,
                    ai_pane = ui.ensure_ai_pane(win, p, ctx.config),
                    config = ctx.config,
                    cwd = ctx.cwd,
                    extra = desc,
                })
            end)
            return
        end
        local sources = select(1, M.collect_tf_sources(ctx.cwd, tf_opts(ctx.config).max_attach_bytes / 2)) or ""
        local prompt = "You are a Terraform expert. Generate clean, idiomatic HCL for the request below. "
            .. "Prefer current provider schemas and required_providers blocks. "
            .. "Put a brief summary in \"message\" and include the full HCL there (or clearly fenced). "
            .. "Set \"command\" to null unless a single safe next step helps (e.g. terraform fmt / validate). "
            .. "Do not suggest terraform apply/destroy. "
            .. "If writing a file would help, mention using #path with wezai.\n\n"
            .. "Request: "
            .. instruction
            .. "\n\nExisting sources in cwd (may be empty):\n```\n"
            .. redact(sources)
            .. "\n```"
        ask_ai(ctx, prompt, "tf:generate")
    end,
})

add({
    id = "debug",
    kind = "ai",
    label = "AI: debug Terraform error / plan output",
    aliases = { "diagnose", "fix" },
    run = function(ctx)
        local selection = util.get_selection(ctx.window, ctx.pane)
        if not selection or selection:match("^%s*$") then
            selection = ctx.pane:get_logical_lines_as_text(120)
        end
        local maxb = tf_opts(ctx.config).max_attach_bytes
        local validate = select(1, M.collect_validate(ctx.cwd, ctx.config)) or ""
        local state = select(1, M.collect_state(ctx.cwd, ctx.config)) or ""
        local sources = select(1, M.collect_tf_sources(ctx.cwd, maxb / 3)) or ""
        local extra = trim(ctx.extra or "")
        local prompt = "You are helping debug Terraform. Using the error/output and configuration below, "
            .. "diagnose the issue briefly and propose safe next steps. "
            .. "Prefer terraform validate, fmt, plan, state list, or #file edits. "
            .. "Never put terraform apply/destroy/force-unlock in \"command\" unless the user clearly asked to mutate. "
            .. "Use placeholders like <resource> if a name is unclear.\n"
            .. (extra ~= "" and ("\nExtra instruction: " .. extra .. "\n") or "")
            .. "\n=== terminal output / selection ===\n```\n"
            .. cap(redact(selection or "(empty)"), maxb / 3)
            .. "\n```\n\n=== terraform validate ===\n```\n"
            .. cap(redact(validate), 20000)
            .. "\n```\n\n=== state list ===\n```\n"
            .. cap(redact(state), 20000)
            .. "\n```\n\n=== sources ===\n```\n"
            .. redact(sources)
            .. "\n```"
        ask_ai(ctx, prompt, "tf:debug")
    end,
})

add({
    id = "explain",
    kind = "ai",
    label = "AI: explain Terraform sources / selection",
    run = function(ctx)
        local selection = util.get_selection(ctx.window, ctx.pane)
        local maxb = tf_opts(ctx.config).max_attach_bytes
        local blob
        if selection and not selection:match("^%s*$") then
            blob = "=== selection ===\n" .. cap(redact(selection), maxb)
        else
            blob = "=== sources ===\n" .. (select(1, M.collect_tf_sources(ctx.cwd, maxb)) or "(none)")
        end
        local extra = trim(ctx.extra or "")
        local prompt = "Explain this Terraform configuration in plain English: resources, data sources, "
            .. "variables, and notable risks. Set command to null unless one safe investigative command helps "
            .. "(validate / state list / plan — never apply/destroy).\n"
            .. (extra ~= "" and ("\nExtra: " .. extra .. "\n") or "")
            .. "\n```\n"
            .. redact(blob)
            .. "\n```"
        ask_ai(ctx, prompt, "tf:explain")
    end,
})

add({
    id = "review",
    kind = "ai",
    label = "AI: review Terraform for bugs/security",
    run = function(ctx)
        local maxb = tf_opts(ctx.config).max_attach_bytes
        local sources = select(1, M.collect_tf_sources(ctx.cwd, maxb)) or ""
        local state = select(1, M.collect_state(ctx.cwd, ctx.config)) or ""
        local extra = trim(ctx.extra or "")
        local prompt = "Review this Terraform for bugs, insecure defaults, missing required_providers, "
            .. "hardcoded secrets, and drift risks. Be concrete. "
            .. "Set command null unless one safe next command helps (fmt/validate). "
            .. "Do not suggest apply/destroy.\n"
            .. (extra ~= "" and ("\nExtra: " .. extra .. "\n") or "")
            .. "\nSources:\n```\n"
            .. redact(sources)
            .. "\n```\n\nState list:\n```\n"
            .. cap(redact(state), 20000)
            .. "\n```"
        ask_ai(ctx, prompt, "tf:review")
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
    return ACTIONS[id]
end

-- Parse ask-line for tf intercept.
-- Returns nil (not tf), or { mode="picker"|"run"|"attach", id?, extra? }
function M.parse_line(line)
    local token = trim(line or "")
    if token == "@tf" or token == "@tf:" or token == "@terraform" or token == "@terraform:" then
        return { mode = "picker" }
    end
    -- Allow @terraform:id as alias for @tf:id
    local id, rest = token:match("^@tf:([%w%-]+)%s*(.-)%s*$")
    if not id then
        id, rest = token:match("^@terraform:([%w%-]+)%s*(.-)%s*$")
    end
    if not id then
        return nil
    end
    local action = ACTIONS[id]
    if not action then
        return nil
    end
    rest = trim(rest or "")
    if rest == "" then
        return { mode = "run", id = action.id }
    end
    if action.kind == "ai" then
        return { mode = "run", id = action.id, extra = rest }
    end
    if action.attach or action.kind == "show" then
        return { mode = "attach", id = action.id }
    end
    return { mode = "run", id = action.id, extra = rest }
end

function M.run_action(window, pane, config, id, extra)
    local shell_pane = ui.shell_pane_for(window, pane)
    local ai_pane = ui.ensure_ai_pane(window, shell_pane, config)
    local cwd, err = M.ensure_cwd(shell_pane)
    if not cwd then
        ui.ai_print(ai_pane, err, "error")
        return
    end
    local action = ACTIONS[id]
    if not action then
        ui.ai_print(ai_pane, "Unknown @tf:" .. tostring(id) .. " — try @tf for the picker", "error")
        return
    end
    local ctx = {
        window = window,
        pane = shell_pane,
        ai_pane = ai_pane,
        config = config,
        cwd = cwd,
        extra = extra,
    }
    local function go()
        if action.kind == "show" or action.kind == "ai" then
            local bin = M.terraform_bin(config)
            local ok, _, verr = util.run_cmd({ bin, "version" })
            if not ok then
                ui.ai_print(
                    ai_pane,
                    "terraform not available ("
                        .. tostring(bin)
                        .. "): "
                        .. tostring(verr)
                        .. "\nSet tf.terraform = \"/absolute/path/to/terraform\" in wezai config if needed.",
                    "error"
                )
                return
            end
        end
        action.run(ctx)
    end
    if action.kind == "show" then
        ui.with_busy(ai_pane, {
            title = "tf",
            command = "@tf:" .. action.id,
            config = config,
        }, go)
        return
    end
    go()
end

function M.open_picker(window, pane, config)
    require("palette").show(window, pane, config, { scope = "tf" })
end

return M
