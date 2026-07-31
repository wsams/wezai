-- @kube catalog for wezai — kubectl helpers with placeholders (no org-specific names).
-- Uses the user's current kubectl context / KUBECONFIG; never injects --kubeconfig.
-- Mutate actions confirm first.
local wezterm = require("wezterm")
local act = wezterm.action
local util = require("util")
local ui = require("ui")
local shell = require("shell")

local M = {}

-- Wired by init.lua
M._ask = nil
M._dispatch = nil

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$") or ""
end

local function kube_opts(config)
    local k = (config and config.kube) or {}
    return {
        namespace = k.namespace,
        kubectl = k.kubectl,
        confirm_mutate = k.confirm_mutate ~= false,
        max_attach_bytes = k.max_attach_bytes or 80000,
    }
end

local function cap(text, max_bytes)
    text = text or ""
    max_bytes = max_bytes or 80000
    if #text <= max_bytes then
        return text
    end
    return text:sub(1, max_bytes) .. "\n… (truncated)"
end

-- Cached absolute kubectl for WezTerm's process (Dock/Spotlight PATH often lacks brew/Docker).
local _kubectl_resolved = nil

local function home_dir()
    return wezterm.home_dir or os.getenv("HOME") or ""
end

function M.kubectl_bin(config)
    local override = kube_opts(config).kubectl
    if override and override ~= "" then
        return override
    end
    if _kubectl_resolved then
        return _kubectl_resolved
    end
    local home = home_dir()
    local found = util.resolve_executable("kubectl", {
        candidates = {
            "/opt/homebrew/bin/kubectl",
            "/usr/local/bin/kubectl",
            "/usr/bin/kubectl",
            home .. "/.local/bin/kubectl",
            home .. "/.asdf/shims/kubectl",
            home .. "/.mise/shims/kubectl",
            "/Applications/Docker.app/Contents/Resources/bin/kubectl",
        },
        login_shell = true,
    })
    _kubectl_resolved = found or "kubectl"
    return _kubectl_resolved
end

local function kubectl(args, opts)
    opts = opts or {}
    local cmd = { M.kubectl_bin(opts.config) }
    if opts.namespace and opts.namespace ~= "" and opts.namespace ~= "-" then
        table.insert(cmd, "-n")
        table.insert(cmd, opts.namespace)
    end
    for _, a in ipairs(args) do
        table.insert(cmd, a)
    end
    return util.run_cmd(cmd)
end

function M.current_namespace(config)
    local opts = kube_opts(config)
    if opts.namespace and opts.namespace ~= "" then
        return opts.namespace
    end
    local ok, stdout = util.run_cmd({
        M.kubectl_bin(config),
        "config",
        "view",
        "--minify",
        "--output",
        "jsonpath={..namespace}",
    })
    if ok and stdout and trim(stdout) ~= "" then
        return trim(stdout)
    end
    return "default"
end

function M.current_context(config)
    local ok, stdout = util.run_cmd({ M.kubectl_bin(config), "config", "current-context" })
    if ok then
        return trim(stdout)
    end
    return "?"
end

--- Namespace for this run: action extra → config.kube.namespace → kubectl context ns.
--- extra may be "kube-system", "-A", or "kube-system -l app=foo" (first token wins for ns).
function M.resolve_namespace(config, extra)
    local rest = trim(extra or "")
    if rest == "-A" or rest == "--all-namespaces" then
        return nil, true, "" -- all namespaces
    end
    if rest ~= "" then
        local ns, more = rest:match("^(%S+)%s*(.-)%s*$")
        if ns and ns ~= "" then
            return ns, false, more or ""
        end
    end
    return M.current_namespace(config), false, ""
end

local function fill_ns(template, ns)
    return (template or ""):gsub("<namespace>", ns or "default")
end

local function still_needs_placeholder(cmd)
    return cmd:find("<[%w%-]+>", 1) ~= nil
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

local function print_show(ai_pane, title, body)
    ui.begin_turn(ai_pane, os.date("%H:%M:%S") .. "  kube")
    ui.ai_print(ai_pane, title, "attach")
    ui.ai_print(ai_pane, body ~= "" and body or "(empty)", "plain")
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
        ui.confirm(window, shell_pane, "Run kubectl: " .. util.truncate(command, 50) .. " ?", "run", function(_, _, yes)
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

--- Fill remaining placeholders via prompts, then insert/run.
local function finalize_command(ctx, template, opts)
    opts = opts or {}
    local ns = M.current_namespace(ctx.config)
    local cmd = fill_ns(template, ns)
    local mutate = opts.mutate == true
    local confirm = mutate and kube_opts(ctx.config).confirm_mutate

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

    -- Prompt order for common tokens
    local need_name = cmd:find("<name>", 1, true) or cmd:find("<pod>", 1, true) or cmd:find("<deploy>", 1, true)
    local need_container = cmd:find("<container>", 1, true)
    local need_file = cmd:find("<file>", 1, true)
    local need_kind = cmd:find("<kind>", 1, true)
    local need_label = cmd:find("<label%-selector>", 1) or cmd:find("<label-selector>", 1, true)
    local need_local = cmd:find("<local%-port>", 1) or cmd:find("<local-port>", 1, true)
    local need_remote = cmd:find("<remote%-port>", 1) or cmd:find("<remote-port>", 1, true)

    local function step_ports(c)
        if need_local or c:find("<local-port>", 1, true) then
            prompt_line(ctx.window, ctx.pane, "Local port (e.g. 8080)", function(_, _, local_port)
                if local_port == "" then
                    return
                end
                c = c:gsub("<local%-port>", local_port)
                c = c:gsub("<local-port>", local_port)
                if need_remote or c:find("<remote-port>", 1, true) then
                    prompt_line(ctx.window, ctx.pane, "Remote/container port (e.g. 8080)", function(_, _, remote_port)
                        if remote_port == "" then
                            return
                        end
                        c = c:gsub("<remote%-port>", remote_port)
                        c = c:gsub("<remote-port>", remote_port)
                        after_filled(c)
                    end)
                else
                    after_filled(c)
                end
            end)
            return
        end
        after_filled(c)
    end

    local function step_container(c)
        if need_container or c:find("<container>", 1, true) then
            prompt_line(ctx.window, ctx.pane, "Container name (optional — Enter to omit -c)", function(_, _, container)
                if container == "" then
                    c = c:gsub("%s*%-c%s*<container>", ""):gsub("<container>", "")
                else
                    c = c:gsub("<container>", container)
                end
                step_ports(c)
            end)
            return
        end
        step_ports(c)
    end

    local function step_name(c)
        if need_name then
            local which = c:find("<pod>", 1, true) and "Pod name"
                or c:find("<deploy>", 1, true) and "Deployment name"
                or "Resource name"
            prompt_line(ctx.window, ctx.pane, which .. " (namespace=" .. ns .. ")", function(_, _, name)
                if name == "" then
                    return
                end
                c = c:gsub("<pod>", name):gsub("<deploy>", name):gsub("<name>", name)
                step_container(c)
            end)
            return
        end
        step_container(c)
    end

    local function step_kind(c)
        if need_kind or c:find("<kind>", 1, true) then
            prompt_line(ctx.window, ctx.pane, "Resource kind (pod, deploy, sts, svc, …)", function(_, _, kind)
                if kind == "" then
                    return
                end
                c = c:gsub("<kind>", kind)
                step_name(c)
            end)
            return
        end
        step_name(c)
    end

    local function step_label(c)
        if need_label or c:find("<label-selector>", 1, true) then
            prompt_line(ctx.window, ctx.pane, "Label selector (e.g. app=myapp)", function(_, _, sel)
                if sel == "" then
                    return
                end
                c = c:gsub("<label%-selector>", sel):gsub("<label-selector>", sel)
                step_kind(c)
            end)
            return
        end
        step_kind(c)
    end

    local function step_file(c)
        if need_file or c:find("<file>", 1, true) then
            prompt_line(ctx.window, ctx.pane, "Manifest path (e.g. ./deploy.yaml)", function(_, _, file)
                if file == "" then
                    return
                end
                c = c:gsub("<file>", file)
                step_label(c)
            end)
            return
        end
        step_label(c)
    end

    step_file(cmd)
end

local function show_cmd(ctx, title, args, use_ns)
    local ns, all_ns = nil, false
    if use_ns then
        ns, all_ns = M.resolve_namespace(ctx.config, ctx.extra)
    end
    local cmd_args = {}
    for _, a in ipairs(args) do
        table.insert(cmd_args, a)
    end
    if all_ns then
        table.insert(cmd_args, "-A")
        ns = nil
    end
    local ok, stdout, stderr = kubectl(cmd_args, { namespace = ns, config = ctx.config })
    local body = ok and stdout or (stderr ~= "" and stderr or stdout)
    if ok and trim(body) == "" then
        body = all_ns and "(no resources)" or ("(no resources in namespace " .. tostring(ns) .. ")")
    end
    local ctxname = M.current_context(ctx.config)
    local where = all_ns and ", ns=*" or (ns and (", ns=" .. ns) or "")
    print_show(
        ctx.ai_pane,
        title .. "  (context=" .. ctxname .. where .. ")",
        cap(body, kube_opts(ctx.config).max_attach_bytes)
    )
end

local function ask_ai(ctx, prompt, user_text)
    if M._ask then
        M._ask(ctx.window, ctx.pane, ctx.config, prompt, user_text)
    else
        ui.ai_print(ctx.ai_pane, "Kube AI hook not wired.", "error")
    end
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

-- Context / cluster (read-only show)
add({
    id = "ctx",
    kind = "show",
    label = "current context + namespace",
    aliases = { "context", "whoami" },
    run = function(ctx)
        local ctxname = M.current_context(ctx.config)
        local ns = M.current_namespace(ctx.config)
        local ok, contexts = util.run_cmd({ M.kubectl_bin(ctx.config), "config", "get-contexts" })
        local body = "current-context: "
            .. ctxname
            .. "\nnamespace: "
            .. ns
            .. "\n\n"
            .. (ok and contexts or "")
        print_show(ctx.ai_pane, "@kube:ctx", body)
    end,
})

add({
    id = "ns",
    kind = "show",
    label = "list namespaces",
    aliases = { "namespaces" },
    run = function(ctx)
        show_cmd(ctx, "@kube:ns", { "get", "namespaces", "-o", "wide" }, false)
    end,
})

add({
    id = "nodes",
    kind = "show",
    label = "get nodes -o wide",
    run = function(ctx)
        show_cmd(ctx, "@kube:nodes", { "get", "nodes", "-o", "wide" }, false)
    end,
})

add({
    id = "pods",
    kind = "show",
    label = "get pods (ns; optional: @kube:pods <ns>|-A)",
    run = function(ctx)
        show_cmd(ctx, "@kube:pods", { "get", "pods", "-o", "wide" }, true)
    end,
})

add({
    id = "pods-all",
    kind = "show",
    label = "get pods -A",
    aliases = { "podsA" },
    run = function(ctx)
        show_cmd(ctx, "@kube:pods-all", { "get", "pods", "-A", "-o", "wide" }, false)
    end,
})

add({
    id = "all",
    kind = "show",
    label = "get all (optional ns / -A)",
    run = function(ctx)
        show_cmd(ctx, "@kube:all", { "get", "all" }, true)
    end,
})

add({
    id = "deploy",
    kind = "show",
    label = "get deploy (optional ns)",
    aliases = { "deployments" },
    run = function(ctx)
        show_cmd(ctx, "@kube:deploy", { "get", "deploy", "-o", "wide" }, true)
    end,
})

add({
    id = "sts",
    kind = "show",
    label = "get statefulsets",
    run = function(ctx)
        show_cmd(ctx, "@kube:sts", { "get", "sts", "-o", "wide" }, true)
    end,
})

add({
    id = "svc",
    kind = "show",
    label = "get services",
    aliases = { "services" },
    run = function(ctx)
        show_cmd(ctx, "@kube:svc", { "get", "svc", "-o", "wide" }, true)
    end,
})

add({
    id = "ing",
    kind = "show",
    label = "get ingress",
    aliases = { "ingress" },
    run = function(ctx)
        show_cmd(ctx, "@kube:ing", { "get", "ingress" }, true)
    end,
})

add({
    id = "cm",
    kind = "show",
    label = "get configmaps",
    run = function(ctx)
        show_cmd(ctx, "@kube:cm", { "get", "cm" }, true)
    end,
})

add({
    id = "secrets",
    kind = "show",
    label = "get secrets (names only)",
    run = function(ctx)
        show_cmd(ctx, "@kube:secrets", { "get", "secrets" }, true)
    end,
})

add({
    id = "pvc",
    kind = "show",
    label = "get pvc",
    run = function(ctx)
        show_cmd(ctx, "@kube:pvc", { "get", "pvc" }, true)
    end,
})

add({
    id = "events",
    kind = "show",
    label = "get events (optional ns / -A)",
    run = function(ctx)
        show_cmd(ctx, "@kube:events", { "get", "events", "--sort-by=.lastTimestamp" }, true)
    end,
})

add({
    id = "top-nodes",
    kind = "show",
    label = "top nodes",
    run = function(ctx)
        show_cmd(ctx, "@kube:top-nodes", { "top", "nodes" }, false)
    end,
})

add({
    id = "top-pods",
    kind = "show",
    label = "top pods (optional ns / -A)",
    run = function(ctx)
        show_cmd(ctx, "@kube:top-pods", { "top", "pods" }, true)
    end,
})

add({
    id = "api-resources",
    kind = "show",
    label = "api-resources",
    run = function(ctx)
        show_cmd(ctx, "@kube:api-resources", { "api-resources" }, false)
    end,
})

add({
    id = "can-i",
    kind = "show",
    label = "auth can-i --list (current ns)",
    aliases = { "auth" },
    run = function(ctx)
        show_cmd(ctx, "@kube:can-i", { "auth", "can-i", "--list" }, true)
    end,
})

add({
    id = "describe",
    kind = "shell",
    label = "describe <kind>/<name>",
    run = function(ctx)
        finalize_command(ctx, "kubectl describe <kind>/<name> -n <namespace>", { execute = true })
    end,
})

add({
    id = "logs",
    kind = "shell",
    label = "logs <pod> (current ns)",
    run = function(ctx)
        finalize_command(ctx, "kubectl logs <pod> -n <namespace> --tail=200", { execute = true })
    end,
})

add({
    id = "logs-f",
    kind = "shell",
    label = "logs -f <pod>",
    aliases = { "logs-follow" },
    run = function(ctx)
        finalize_command(ctx, "kubectl logs -f <pod> -n <namespace> --tail=100", { execute = true })
    end,
})

add({
    id = "logs-deploy",
    kind = "shell",
    label = "logs deployment/<name>",
    run = function(ctx)
        finalize_command(ctx, "kubectl logs deployment/<deploy> -n <namespace> --tail=200", { execute = true })
    end,
})

add({
    id = "exec",
    kind = "shell",
    label = "exec -it <pod> -- sh",
    run = function(ctx)
        finalize_command(ctx, "kubectl exec -it <pod> -n <namespace> -- sh", { execute = true })
    end,
})

add({
    id = "pf",
    kind = "shell",
    label = "port-forward pod/<name> local:remote",
    aliases = { "port-forward" },
    run = function(ctx)
        finalize_command(
            ctx,
            "kubectl port-forward pod/<pod> -n <namespace> <local-port>:<remote-port>",
            { execute = true }
        )
    end,
})

add({
    id = "pf-svc",
    kind = "shell",
    label = "port-forward svc/<name>",
    run = function(ctx)
        finalize_command(
            ctx,
            "kubectl port-forward svc/<name> -n <namespace> <local-port>:<remote-port>",
            { execute = true }
        )
    end,
})

add({
    id = "rollout",
    kind = "shell",
    label = "rollout status deploy/<name>",
    run = function(ctx)
        finalize_command(ctx, "kubectl rollout status deploy/<deploy> -n <namespace>", { execute = true })
    end,
})

add({
    id = "restart",
    kind = "shell",
    label = "rollout restart deploy/<name> (confirm)",
    mutate = true,
    run = function(ctx)
        finalize_command(ctx, "kubectl rollout restart deploy/<deploy> -n <namespace>", {
            execute = true,
            mutate = true,
        })
    end,
})

add({
    id = "scale",
    kind = "shell",
    label = "scale deploy/<name> (confirm)",
    mutate = true,
    run = function(ctx)
        prompt_line(ctx.window, ctx.pane, "Deployment name", function(_, _, name)
            if name == "" then
                return
            end
            prompt_line(ctx.window, ctx.pane, "Replica count", function(_, _, replicas)
                if replicas == "" then
                    return
                end
                local ns = M.current_namespace(ctx.config)
                finalize_command(ctx, "kubectl scale deploy/" .. name .. " -n " .. ns .. " --replicas=" .. replicas, {
                    execute = true,
                    mutate = true,
                })
            end)
        end)
    end,
})

add({
    id = "wait",
    kind = "shell",
    label = "wait pods -l <selector> --for=Ready",
    run = function(ctx)
        finalize_command(
            ctx,
            "kubectl wait pods -l <label-selector> -n <namespace> --for=condition=Ready --timeout=300s",
            { execute = true }
        )
    end,
})

add({
    id = "diff",
    kind = "shell",
    label = "diff -f <file> (current ns)",
    run = function(ctx)
        finalize_command(ctx, "kubectl diff -f <file> -n <namespace>", { execute = true })
    end,
})

add({
    id = "apply",
    kind = "shell",
    label = "apply -f <file> (confirm)",
    mutate = true,
    run = function(ctx)
        finalize_command(ctx, "kubectl apply -f <file> -n <namespace>", { execute = true, mutate = true })
    end,
})

add({
    id = "delete-f",
    kind = "shell",
    label = "delete -f <file> (confirm)",
    mutate = true,
    aliases = { "delete" },
    run = function(ctx)
        finalize_command(ctx, "kubectl delete -f <file> -n <namespace>", { execute = true, mutate = true })
    end,
})

add({
    id = "get-yaml",
    kind = "shell",
    label = "get <kind>/<name> -o yaml",
    run = function(ctx)
        finalize_command(ctx, "kubectl get <kind>/<name> -n <namespace> -o yaml", { execute = true })
    end,
})

add({
    id = "use-ns",
    kind = "shell",
    label = "config set-context --current --namespace=…",
    run = function(ctx)
        local function apply(ns)
            if not ns or ns == "" then
                return
            end
            finalize_command(ctx, "kubectl config set-context --current --namespace=" .. ns, {
                execute = true,
                mutate = false,
            })
        end
        local from_extra = trim(ctx.extra or "")
        if from_extra ~= "" then
            apply(from_extra:match("^(%S+)") or from_extra)
            return
        end
        prompt_line(ctx.window, ctx.pane, "Namespace to switch to", function(_, _, ns)
            apply(ns)
        end)
    end,
})

-- Careful AI helpers (read-only context collection)
add({
    id = "diagnose",
    kind = "ai",
    label = "AI: diagnose failing pods / events (read-only)",
    run = function(ctx)
        local ns = M.resolve_namespace(ctx.config, ctx.extra)
        local ok_p, pods = kubectl({ "get", "pods", "-o", "wide" }, { namespace = ns, config = ctx.config })
        local ok_e, events =
            kubectl({ "get", "events", "--sort-by=.lastTimestamp" }, { namespace = ns, config = ctx.config })
        local selection = util.get_selection(ctx.window, ctx.pane)
        local maxb = kube_opts(ctx.config).max_attach_bytes
        local blob = "Namespace: "
            .. tostring(ns)
            .. "\nContext: "
            .. M.current_context(ctx.config)
            .. "\n\n=== pods ===\n"
            .. cap(ok_p and pods or "(failed to get pods)", maxb / 2)
            .. "\n\n=== events ===\n"
            .. cap(ok_e and events or "(failed to get events)", maxb / 2)
        if selection and selection ~= "" then
            blob = blob .. "\n\n=== selection ===\n" .. cap(selection, 20000)
        end
        local prompt = "You are helping debug Kubernetes. Using ONLY the read-only kubectl output below, "
            .. "diagnose likely issues (CrashLoopBackOff, ImagePull, Pending, probes, quotas, etc.). "
            .. "Be specific and brief. Prefer non-destructive next steps. "
            .. "If a single safe investigative command helps, put it in \"command\" "
            .. "(get/describe/logs only — never delete/apply/drain/exec as root unless clearly necessary). "
            .. "Use placeholders like <pod> / <namespace> if a name is unclear.\n\n```\n"
            .. blob
            .. "\n```"
        ask_ai(ctx, prompt, "kube:diagnose")
    end,
})

add({
    id = "explain-sel",
    kind = "ai",
    label = "AI: explain selected kubectl error/output",
    aliases = { "explain" },
    run = function(ctx)
        local selection = util.get_selection(ctx.window, ctx.pane)
        if not selection or selection:match("^%s*$") then
            selection = ctx.pane:get_logical_lines_as_text(100)
        end
        if not selection or selection:match("^%s*$") then
            ui.ai_print(ctx.ai_pane, "Nothing selected / empty scrollback to explain.", "error")
            return
        end
        local prompt = "Explain this Kubernetes/kubectl output or error. "
            .. "Suggest the next safe investigative command only (get/describe/logs). "
            .. "Do not suggest delete/apply/drain unless the user clearly already asked to mutate.\n\n```\n"
            .. cap(require("context").redact(selection), 60000)
            .. "\n```"
        ask_ai(ctx, prompt, "kube:explain")
    end,
})

add({
    id = "not-ready",
    kind = "ai",
    label = "AI: why aren't pods Ready?",
    run = function(ctx)
        local ns = M.resolve_namespace(ctx.config, ctx.extra)
        local ok, pods = kubectl({
            "get",
            "pods",
            "--field-selector=status.phase!=Succeeded",
            "-o",
            "wide",
        }, { namespace = ns, config = ctx.config })
        local ok2, desc = kubectl({ "get", "pods" }, { namespace = ns, config = ctx.config })
        local prompt = "Pods in namespace "
            .. tostring(ns)
            .. " may be unhealthy. Identify which are not Ready and why. "
            .. "Propose safe next describe/logs commands (placeholders OK).\n\n```\n"
            .. cap((ok and pods or "") .. "\n" .. (ok2 and desc or ""), 80000)
            .. "\n```"
        ask_ai(ctx, prompt, "kube:not-ready")
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

function M.parse_line(line)
    local token = trim(line or "")
    if token == "@kube" or token == "@kube:" then
        return { mode = "picker" }
    end
    -- @kube:pods | @kube:pods kube-system | @kube:pods/kube-system | @kube:pods:kube-system
    local id, inline, rest = token:match("^@kube:([%w%-]+)([/:][^%s]+)?%s*(.-)%s*$")
    if not id then
        return nil
    end
    local action = ACTIONS[id]
    if not action then
        return nil
    end
    local extra = trim(rest or "")
    if inline and inline ~= "" then
        local from_inline = inline:sub(2) -- drop / or :
        if extra == "" then
            extra = from_inline
        else
            extra = from_inline .. " " .. extra
        end
    end
    if extra == "" then
        return { mode = "run", id = action.id }
    end
    return { mode = "run", id = action.id, extra = extra }
end

function M.collect_attach(syn, config)
    local raw = syn:match("^kube:(.+)$") or syn
    local id, inline = raw:match("^([%w%-]+)([/:][^%s]+)?$")
    if not id then
        id = raw
    end
    local ns_extra = inline and inline:sub(2) or nil
    local ns, all_ns = M.resolve_namespace(config, ns_extra)
    local maxb = kube_opts(config).max_attach_bytes
    local kopts = { namespace = all_ns and nil or ns, config = config }
    local function get(args)
        local cmd = {}
        for _, a in ipairs(args) do
            table.insert(cmd, a)
        end
        if all_ns then
            table.insert(cmd, "-A")
        end
        return kubectl(cmd, kopts)
    end
    if id == "pods" then
        local ok, stdout, stderr = get({ "get", "pods", "-o", "wide" })
        return ok and cap(stdout, maxb) or nil, ok and nil or (stderr or stdout)
    elseif id == "events" then
        local ok, stdout, stderr = get({ "get", "events", "--sort-by=.lastTimestamp" })
        return ok and cap(stdout, maxb) or nil, ok and nil or (stderr or stdout)
    elseif id == "all" then
        local ok, stdout, stderr = get({ "get", "all" })
        return ok and cap(stdout, maxb) or nil, ok and nil or (stderr or stdout)
    elseif id == "nodes" then
        local ok, stdout, stderr = kubectl({ "get", "nodes", "-o", "wide" }, { config = config })
        return ok and cap(stdout, maxb) or nil, ok and nil or (stderr or stdout)
    elseif id == "ctx" or id == "context" then
        return "context=" .. M.current_context(config) .. " namespace=" .. tostring(ns), nil
    end
    return nil, "unknown @kube attach: " .. tostring(syn)
end

function M.run_action(window, pane, config, id, extra)
    local shell_pane = ui.shell_pane_for(window, pane)
    local ai_pane = ui.ensure_ai_pane(window, shell_pane, config)
    local action = ACTIONS[id]
    if not action then
        ui.ai_print(ai_pane, "Unknown @kube:" .. tostring(id) .. " — try @kube for the picker", "error")
        return
    end
    -- Quick connectivity check for show/ai
    if action.kind == "show" or action.kind == "ai" then
        local bin = M.kubectl_bin(config)
        local ok, _, err = util.run_cmd({ bin, "version", "--client", "--output=yaml" })
        if not ok then
            ui.ai_print(
                ai_pane,
                "kubectl not available ("
                    .. tostring(bin)
                    .. "): "
                    .. tostring(err)
                    .. "\nSet kube.kubectl = \"/absolute/path/to/kubectl\" in wezai config if needed.",
                "error"
            )
            return
        end
    end
    action.run({
        window = window,
        pane = shell_pane,
        ai_pane = ai_pane,
        config = config,
        extra = extra,
    })
end

function M.open_picker(window, pane, config)
    require("palette").show(window, pane, config, { scope = "kube" })
end

return M
