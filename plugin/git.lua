local wezterm = require("wezterm")
local act = wezterm.action
local util = require("util")
local ui = require("ui")
local shell = require("shell")

local M = {}

local function redact(text)
    return require("context").redact(text)
end

-- Set by init.lua
M._ask = nil

local MAX_ATTACH = 80000
local MAX_CONFLICT_FILE = 24000

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$") or ""
end

local function git_opts(config)
    local g = (config and config.git) or {}
    return {
        default_branch = g.default_branch,
        confirm_push = g.confirm_push ~= false,
        max_attach_bytes = g.max_attach_bytes or MAX_ATTACH,
    }
end

function M.git_cmd(cwd, args)
    -- Never let git emit its own ANSI — AI pane applies theme-friendly styling
    local cmd = {
        "git",
        "-C",
        cwd,
        "-c",
        "color.ui=never",
        "-c",
        "color.status=never",
        "-c",
        "color.branch=never",
        "-c",
        "color.diff=never",
    }
    for _, a in ipairs(args) do
        table.insert(cmd, a)
    end
    local ok, stdout, stderr = util.run_cmd(cmd)
    local function strip_ansi(s)
        return (s or ""):gsub("\27%[[%d;]*[a-zA-Z]", "")
    end
    return ok, strip_ansi(stdout), strip_ansi(stderr)
end

function M.ensure_repo(pane)
    local cwd = util.get_pane_cwd(pane)
    if not cwd then
        return nil, "no pane cwd (open a shell in a git repo)"
    end
    local ok, stdout, stderr = M.git_cmd(cwd, { "rev-parse", "--is-inside-work-tree" })
    if not ok or trim(stdout) ~= "true" then
        return nil, "not a git repository: " .. cwd .. (stderr ~= "" and (" — " .. stderr) or "")
    end
    return cwd, nil
end

function M.default_branch(cwd, config)
    local opts = git_opts(config)
    if opts.default_branch and opts.default_branch ~= "" then
        return opts.default_branch
    end
    local ok, stdout = M.git_cmd(cwd, { "symbolic-ref", "refs/remotes/origin/HEAD" })
    if ok and stdout then
        local b = stdout:match("refs/remotes/origin/([%w%._%-/]+)")
        if b and b ~= "" then
            return trim(b)
        end
    end
    for _, name in ipairs({ "main", "master" }) do
        local okb = M.git_cmd(cwd, { "show-ref", "--verify", "--quiet", "refs/heads/" .. name })
        if okb then
            return name
        end
    end
    return "main"
end

local function cap(text, max_bytes)
    max_bytes = max_bytes or MAX_ATTACH
    text = text or ""
    if #text <= max_bytes then
        return text
    end
    return text:sub(1, max_bytes) .. "\n… (truncated)"
end

local function lines_from(stdout)
    local out = {}
    for line in ((stdout or "") .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then
            table.insert(out, line)
        end
    end
    return out
end

-- --- Attach collectors (shared with context.lua) ---

function M.collect_status(cwd)
    local ok, stdout, stderr = M.git_cmd(cwd, { "status", "--short", "--branch" })
    if not ok then
        return nil, stderr ~= "" and stderr or stdout
    end
    return stdout, nil
end

function M.collect_diff(cwd, max_bytes)
    local ok, stdout, stderr = M.git_cmd(cwd, { "diff", "HEAD" })
    if not ok then
        return nil, stderr ~= "" and stderr or stdout
    end
    if stdout == "" then
        ok, stdout = M.git_cmd(cwd, { "diff" })
    end
    local okc, cached = M.git_cmd(cwd, { "diff", "--cached" })
    local parts = {}
    if okc and cached and cached ~= "" then
        table.insert(parts, "=== staged (cached) ===\n" .. cached)
    end
    if stdout and stdout ~= "" then
        table.insert(parts, "=== worktree ===\n" .. stdout)
    end
    if #parts == 0 then
        return "(no diff)", nil
    end
    return cap(table.concat(parts, "\n\n"), max_bytes), nil
end

function M.collect_log(cwd, n)
    n = tonumber(n) or 15
    if n < 1 then
        n = 15
    end
    n = math.floor(n)
    local ok, stdout, stderr = M.git_cmd(cwd, { "log", "--oneline", "-" .. tostring(n) })
    if not ok then
        return nil, stderr ~= "" and stderr or stdout
    end
    return stdout ~= "" and stdout or "(no commits)", nil
end

function M.collect_branch(cwd)
    local ok, stdout, stderr = M.git_cmd(cwd, { "branch", "-vv" })
    if not ok then
        return nil, stderr ~= "" and stderr or stdout
    end
    return stdout, nil
end

function M.collect_stash(cwd)
    local ok, stdout, stderr = M.git_cmd(cwd, { "stash", "list" })
    if not ok then
        return nil, stderr ~= "" and stderr or stdout
    end
    return (stdout ~= "" and stdout or "(empty stash list)"), nil
end

function M.collect_remote(cwd)
    local ok, stdout, stderr = M.git_cmd(cwd, { "remote", "-v" })
    if not ok then
        return nil, stderr ~= "" and stderr or stdout
    end
    return (stdout ~= "" and stdout or "(no remotes)"), nil
end

function M.collect_whoami(cwd)
    local _, name = M.git_cmd(cwd, { "config", "user.name" })
    local _, email = M.git_cmd(cwd, { "config", "user.email" })
    name = trim(name)
    email = trim(email)
    local lines = {
        "user.name=" .. (name ~= "" and name or "(unset)"),
        "user.email=" .. (email ~= "" and email or "(unset)"),
    }
    if name == "" or email == "" then
        table.insert(lines, "Hint: use @git:identity to set name/email (global by default).")
    end
    return table.concat(lines, "\n"), nil
end

function M.collect_staged_diff(cwd, max_bytes)
    local ok, stdout, stderr = M.git_cmd(cwd, { "diff", "--cached" })
    if not ok then
        return nil, stderr ~= "" and stderr or stdout
    end
    if stdout == "" then
        return nil, "nothing staged — git add first"
    end
    return cap(stdout, max_bytes), nil
end

function M.collect_attach(cwd, syn, config)
    local opts = git_opts(config)
    local max_bytes = opts.max_attach_bytes
    local id = syn:match("^git:(.+)$") or syn
    local log_n
    id, log_n = (function(raw)
        local base, num = (raw or ""):match("^(log)(%d+)$")
        if base then
            return base, tonumber(num)
        end
        return raw, nil
    end)(id)
    if id == "status" then
        return M.collect_status(cwd)
    elseif id == "diff" then
        return M.collect_diff(cwd, max_bytes)
    elseif id == "log" then
        return M.collect_log(cwd, log_n)
    elseif id == "branch" then
        return M.collect_branch(cwd)
    elseif id == "stash" then
        return M.collect_stash(cwd)
    elseif id == "remote" then
        return M.collect_remote(cwd)
    elseif id == "whoami" then
        return M.collect_whoami(cwd)
    elseif id == "msg" or id == "commit-msg" then
        return M.collect_staged_diff(cwd, max_bytes)
    end
    return nil, "unknown @git attach: " .. tostring(syn) .. " (try @git for the picker)"
end

local function print_show(ai_pane, title, body)
    ui.begin_turn(ai_pane, os.date("%H:%M:%S") .. "  git")
    ui.ai_print(ai_pane, title, "attach")
    -- "git" kind: default terminal fg for paths; readable accents for ## / status XY
    ui.ai_print(ai_pane, body ~= "" and body or "(empty)", "git")
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
        ui.confirm(window, shell_pane, "Run: " .. util.truncate(command, 60) .. " ?", "run", function(_, _, yes)
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

local function ask_ai(window, pane, config, prompt, user_text)
    if M._ask then
        M._ask(window, pane, config, prompt, user_text)
    else
        local ai_pane = ui.ensure_ai_pane(window, pane, config)
        ui.ai_print(ai_pane, "Git AI hook not wired.", "error")
    end
end

-- Parse embedded count from ids like rebase15 / soft3 / log30 → base id + number.
local function split_count_id(id)
    local base, num = (id or ""):match("^(rebase)(%d+)$")
    if not base then
        base, num = (id or ""):match("^(soft)(%d+)$")
    end
    if not base then
        base, num = (id or ""):match("^(log)(%d+)$")
    end
    if base and num then
        return base, tonumber(num)
    end
    return id, nil
end

local function positive_count(raw)
    local n = tonumber(raw)
    if n and n == math.floor(n) and n >= 1 then
        return n
    end
    return nil
end

-- --- Actions ---

local ACTIONS = {}
local ACTION_ORDER = {}

local function add_action(a)
    ACTIONS[a.id] = a
    table.insert(ACTION_ORDER, a.id)
    if a.aliases then
        for _, al in ipairs(a.aliases) do
            ACTIONS[al] = a
        end
    end
end

-- Show
add_action({
    id = "status",
    label = "status — git status -sb",
    kind = "show",
    attach = true,
    run = function(ctx)
        local body, err = M.collect_status(ctx.cwd)
        if err then
            ui.ai_print(ctx.ai_pane, err, "error")
            return
        end
        print_show(ctx.ai_pane, "@git:status", body)
    end,
})

add_action({
    id = "diff",
    label = "diff — staged + worktree",
    kind = "show",
    attach = true,
    run = function(ctx)
        local body, err = M.collect_diff(ctx.cwd, git_opts(ctx.config).max_attach_bytes)
        if err then
            ui.ai_print(ctx.ai_pane, err, "error")
            return
        end
        print_show(ctx.ai_pane, "@git:diff", body)
    end,
})

add_action({
    id = "log",
    label = "logN — last N commits (default 15, e.g. log30)",
    kind = "show",
    attach = true,
    run = function(ctx)
        local n = positive_count(ctx.extra) or 15
        local body, err = M.collect_log(ctx.cwd, n)
        if err then
            ui.ai_print(ctx.ai_pane, err, "error")
            return
        end
        print_show(ctx.ai_pane, "@git:log" .. (n ~= 15 and tostring(n) or ""), body)
    end,
})

add_action({
    id = "branch",
    label = "branch — branch -vv",
    kind = "show",
    attach = true,
    run = function(ctx)
        local body, err = M.collect_branch(ctx.cwd)
        if err then
            ui.ai_print(ctx.ai_pane, err, "error")
            return
        end
        print_show(ctx.ai_pane, "@git:branch", body)
    end,
})

add_action({
    id = "stash",
    label = "stash — stash list",
    kind = "show",
    attach = true,
    run = function(ctx)
        local body, err = M.collect_stash(ctx.cwd)
        if err then
            ui.ai_print(ctx.ai_pane, err, "error")
            return
        end
        print_show(ctx.ai_pane, "@git:stash", body)
    end,
})

add_action({
    id = "remote",
    label = "remote — remote -v",
    kind = "show",
    attach = true,
    run = function(ctx)
        local body, err = M.collect_remote(ctx.cwd)
        if err then
            ui.ai_print(ctx.ai_pane, err, "error")
            return
        end
        print_show(ctx.ai_pane, "@git:remote", body)
    end,
})

add_action({
    id = "whoami",
    label = "whoami — user.name / user.email",
    kind = "show",
    attach = true,
    run = function(ctx)
        local body, err = M.collect_whoami(ctx.cwd)
        if err then
            ui.ai_print(ctx.ai_pane, err, "error")
            return
        end
        print_show(ctx.ai_pane, "@git:whoami", body)
    end,
})

-- Shell shortcuts — @git:rebase15 / @git:soft3 (any positive N); bare @git:rebase / @git:soft prompts.
add_action({
    id = "rebase",
    label = "rebaseN — rebase -i HEAD~N (e.g. rebase15)",
    kind = "shell",
    run = function(ctx)
        local function go(win, p, n)
            local ap = ui.ensure_ai_pane(win, p, ctx.config)
            if not n then
                ui.ai_print(ap, "Need a positive integer (e.g. @git:rebase15).", "error")
                return
            end
            run_in_shell(win, p, ap, ctx.config, "git rebase -i HEAD~" .. n, { confirm = true })
        end
        local n = positive_count(ctx.extra)
        if n then
            go(ctx.window, ctx.pane, n)
            return
        end
        prompt_line(ctx.window, ctx.pane, "Rebase how many commits? (e.g. 15)", function(win, p, line)
            go(win, p, positive_count(line))
        end)
    end,
})

add_action({
    id = "soft",
    label = "softN — reset --soft HEAD~N (e.g. soft1)",
    kind = "shell",
    run = function(ctx)
        local function go(win, p, n)
            local ap = ui.ensure_ai_pane(win, p, ctx.config)
            if not n then
                ui.ai_print(ap, "Need a positive integer (e.g. @git:soft1).", "error")
                return
            end
            run_in_shell(win, p, ap, ctx.config, "git reset --soft HEAD~" .. n, { confirm = true })
        end
        local n = positive_count(ctx.extra)
        if n then
            go(ctx.window, ctx.pane, n)
            return
        end
        prompt_line(ctx.window, ctx.pane, "Soft-reset how many commits? (e.g. 1)", function(win, p, line)
            go(win, p, positive_count(line))
        end)
    end,
})

add_action({
    id = "unstage",
    label = "unstage — restore --staged (pick files)",
    kind = "shell",
    run = function(ctx)
        local ok, stdout, stderr = M.git_cmd(ctx.cwd, { "diff", "--cached", "--name-only" })
        if not ok then
            ui.ai_print(ctx.ai_pane, stderr ~= "" and stderr or stdout, "error")
            return
        end
        local files = lines_from(stdout)
        if #files == 0 then
            ui.ai_print(ctx.ai_pane, "Nothing staged.", "warn")
            return
        end
        local choices = { { id = "__all__", label = "All staged files (" .. #files .. ")" } }
        for i, f in ipairs(files) do
            table.insert(choices, { id = tostring(i), label = f })
        end
        ui.input_select(ctx.window, ctx.pane, "Unstage — pick file(s)", choices, function(win, p, id)
            if not id then
                return
            end
            local ap = ui.ensure_ai_pane(win, p, ctx.config)
            local cmd
            if id == "__all__" then
                cmd = "git restore --staged ."
            else
                local f = files[tonumber(id)]
                if not f then
                    return
                end
                cmd = "git restore --staged -- " .. string.format("%q", f)
            end
            run_in_shell(win, p, ap, ctx.config, cmd, { confirm = true })
        end, { fuzzy = true })
    end,
})

add_action({
    id = "restore",
    label = "restore — discard worktree changes (pick)",
    kind = "shell",
    run = function(ctx)
        local ok, stdout, stderr = M.git_cmd(ctx.cwd, { "diff", "--name-only" })
        if not ok then
            ui.ai_print(ctx.ai_pane, stderr ~= "" and stderr or stdout, "error")
            return
        end
        local files = lines_from(stdout)
        if #files == 0 then
            ui.ai_print(ctx.ai_pane, "No unstaged modifications.", "warn")
            return
        end
        local choices = {}
        for i, f in ipairs(files) do
            table.insert(choices, { id = tostring(i), label = f })
        end
        ui.input_select(ctx.window, ctx.pane, "Restore worktree file (discards changes)", choices, function(win, p, id)
            if not id then
                return
            end
            local f = files[tonumber(id)]
            if not f then
                return
            end
            local ap = ui.ensure_ai_pane(win, p, ctx.config)
            local cmd = "git restore -- " .. string.format("%q", f)
            run_in_shell(win, p, ap, ctx.config, cmd, { confirm = true })
        end, { fuzzy = true })
    end,
})

add_action({
    id = "latest",
    label = "latest — checkout default branch + pull --ff-only",
    kind = "shell",
    run = function(ctx)
        local branch = M.default_branch(ctx.cwd, ctx.config)
        local cmd = "git checkout " .. branch .. " && git pull --ff-only"
        ui.ai_print(ctx.ai_pane, "Default branch: " .. branch, "status")
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, cmd, { confirm = true })
    end,
})

add_action({
    id = "fetch",
    label = "fetch — fetch --all --prune",
    kind = "shell",
    run = function(ctx)
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, "git fetch --all --prune", { confirm = false })
    end,
})

add_action({
    id = "pull",
    label = "pull — git pull --ff-only",
    kind = "shell",
    run = function(ctx)
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, "git pull --ff-only", { confirm = true })
    end,
})

add_action({
    id = "push",
    label = "push — git push",
    kind = "shell",
    run = function(ctx)
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, "git push", { confirm = true })
    end,
})

add_action({
    id = "pushu",
    label = "pushu — push -u origin HEAD",
    kind = "shell",
    run = function(ctx)
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, "git push -u origin HEAD", { confirm = true })
    end,
})

add_action({
    id = "sync",
    label = "sync — fetch + status",
    kind = "shell",
    run = function(ctx)
        local ok, stdout, stderr = M.git_cmd(ctx.cwd, { "fetch", "--all", "--prune" })
        if not ok then
            ui.ai_print(ctx.ai_pane, "fetch failed: " .. (stderr ~= "" and stderr or stdout), "error")
            return
        end
        local body, err = M.collect_status(ctx.cwd)
        if err then
            ui.ai_print(ctx.ai_pane, err, "error")
            return
        end
        print_show(ctx.ai_pane, "@git:sync (after fetch)", body)
    end,
})

add_action({
    id = "stash-push",
    label = "stash-push — stash push -u",
    kind = "shell",
    run = function(ctx)
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, "git stash push -u", { confirm = true })
    end,
})

add_action({
    id = "stash-pop",
    label = "stash-pop — stash pop",
    kind = "shell",
    run = function(ctx)
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, "git stash pop", { confirm = true })
    end,
})

add_action({
    id = "switch",
    label = "switch — git switch <branch>",
    kind = "shell",
    run = function(ctx)
        prompt_line(ctx.window, ctx.pane, "Branch to switch to", function(win, p, name)
            if name == "" then
                return
            end
            local ap = ui.ensure_ai_pane(win, p, ctx.config)
            run_in_shell(win, p, ap, ctx.config, "git switch " .. string.format("%q", name), { confirm = true })
        end)
    end,
})

add_action({
    id = "newbranch",
    label = "newbranch — switch -c <name>",
    kind = "shell",
    run = function(ctx)
        prompt_line(ctx.window, ctx.pane, "New branch name", function(win, p, name)
            if name == "" then
                return
            end
            local ap = ui.ensure_ai_pane(win, p, ctx.config)
            run_in_shell(win, p, ap, ctx.config, "git switch -c " .. string.format("%q", name), { confirm = true })
        end)
    end,
})

add_action({
    id = "add",
    label = "add — git add -A (confirm)",
    kind = "shell",
    run = function(ctx)
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, "git add -A", { confirm = true })
    end,
})

add_action({
    id = "commit",
    label = "commit — insert git commit (editor)",
    kind = "shell",
    run = function(ctx)
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, "git commit", { execute = true, confirm = false })
    end,
})

add_action({
    id = "amend",
    label = "amend — commit --amend --no-edit",
    kind = "shell",
    run = function(ctx)
        local pushed = false
        local ok = M.git_cmd(ctx.cwd, { "rev-parse", "--abbrev-ref", "@{u}" })
        if ok then
            local ok2, counts = M.git_cmd(ctx.cwd, { "rev-list", "--left-right", "--count", "HEAD...@{u}" })
            if ok2 and counts then
                local ahead = tonumber(counts:match("^(%d+)")) or 0
                if ahead == 0 then
                    pushed = true
                end
            end
        end
        local msg = "git commit --amend --no-edit"
        if pushed then
            ui.ai_print(ctx.ai_pane, "Warning: branch appears to track a remote tip — amending may rewrite published history.", "warn")
        end
        run_in_shell(ctx.window, ctx.pane, ctx.ai_pane, ctx.config, msg, { confirm = true })
    end,
})

add_action({
    id = "identity",
    label = "identity — set user.name + user.email (global)",
    kind = "shell",
    run = function(ctx)
        prompt_line(ctx.window, ctx.pane, "git user.name", function(win, p, name)
            if name == "" then
                return
            end
            prompt_line(win, p, "git user.email", function(win2, p2, email)
                if email == "" then
                    return
                end
                local ap = ui.ensure_ai_pane(win2, p2, ctx.config)
                local cmd = string.format(
                    "git config --global user.name %s && git config --global user.email %s",
                    string.format("%q", name),
                    string.format("%q", email)
                )
                ui.ai_print(ap, "Will set GLOBAL identity:\n  name=" .. name .. "\n  email=" .. email, "warn")
                run_in_shell(win2, p2, ap, ctx.config, cmd, { confirm = true })
            end)
        end)
    end,
})

add_action({
    id = "ignore",
    label = "ignore — append pattern to .gitignore",
    kind = "shell",
    run = function(ctx)
        prompt_line(ctx.window, ctx.pane, "Pattern to append to .gitignore", function(win, p, pattern)
            if pattern == "" then
                return
            end
            local ap = ui.ensure_ai_pane(win, p, ctx.config)
            local gi = ctx.cwd .. util.separator .. ".gitignore"
            local existing = ""
            local ok_read, content = util.read_text_file(gi, 500000)
            if ok_read then
                existing = content
                if not existing:match("\n$") and existing ~= "" then
                    existing = existing .. "\n"
                end
            end
            local new_content = existing .. pattern .. "\n"
            ui.confirm(win, p, "Append to .gitignore: " .. pattern .. " ?", "ok", function(_, _, yes)
                if not yes then
                    ui.ai_print(ap, "Cancelled.", "warn")
                    return
                end
                if ok_read then
                    local bak = gi .. ((ctx.config.backup_suffix) or ".wezai.bak")
                    util.write_text_file(bak, existing)
                end
                local wok, werr = util.write_text_file(gi, new_content)
                if not wok then
                    ui.ai_print(ap, werr or "write failed", "error")
                    return
                end
                ui.ai_print(ap, "Appended to .gitignore: " .. pattern, "success")
            end)
        end)
    end,
})

-- AI flows
add_action({
    id = "msg",
    aliases = { "commit-msg" },
    label = "msg — AI commit message from staged diff",
    kind = "ai",
    run = function(ctx)
        local diff, err = M.collect_staged_diff(ctx.cwd, git_opts(ctx.config).max_attach_bytes)
        if err then
            ui.ai_print(ctx.ai_pane, err, "error")
            return
        end
        local extra = ctx.extra and ctx.extra ~= "" and ("\nExtra instruction: " .. ctx.extra) or ""
        local prompt = "Write a Conventional Commit message for the staged diff below. "
            .. "Put the full commit message (subject + optional body) in JSON field \"message\". "
            .. "Put a single shell-safe command in \"command\" like: git commit -m \"subject here\" "
            .. "(escape quotes properly). Do not run other git commands."
            .. extra
            .. "\n\nStaged diff:\n```\n"
            .. redact(diff)
            .. "\n```"
        ask_ai(ctx.window, ctx.pane, ctx.config, prompt, "git:msg")
    end,
})

add_action({
    id = "explain",
    label = "explain — AI summarize status + diff",
    kind = "ai",
    run = function(ctx)
        local status = select(1, M.collect_status(ctx.cwd)) or ""
        local diff = select(1, M.collect_diff(ctx.cwd, git_opts(ctx.config).max_attach_bytes)) or ""
        local extra = ctx.extra and ctx.extra ~= "" and ("\nExtra: " .. ctx.extra) or ""
        local prompt = "Explain this git working tree in plain English: what changed, what looks risky. "
            .. "Set command to null unless a single safe git command clearly helps."
            .. extra
            .. "\n\nStatus:\n```\n"
            .. redact(status)
            .. "\n```\n\nDiff:\n```\n"
            .. redact(diff)
            .. "\n```"
        ask_ai(ctx.window, ctx.pane, ctx.config, prompt, "git:explain")
    end,
})

add_action({
    id = "review",
    label = "review — AI review changes for bugs/secrets",
    kind = "ai",
    run = function(ctx)
        local status = select(1, M.collect_status(ctx.cwd)) or ""
        local diff = select(1, M.collect_diff(ctx.cwd, git_opts(ctx.config).max_attach_bytes)) or ""
        local extra = ctx.extra and ctx.extra ~= "" and ("\nExtra: " .. ctx.extra) or ""
        local prompt = "Review these git changes for bugs, secrets, and missing tests. Be concrete. "
            .. "Set command null unless one specific safe git command helps."
            .. extra
            .. "\n\nStatus:\n```\n"
            .. redact(status)
            .. "\n```\n\nDiff:\n```\n"
            .. redact(diff)
            .. "\n```"
        ask_ai(ctx.window, ctx.pane, ctx.config, prompt, "git:review")
    end,
})

add_action({
    id = "pr",
    label = "pr — AI draft PR title + summary vs default branch",
    kind = "ai",
    run = function(ctx)
        local base = M.default_branch(ctx.cwd, ctx.config)
        local ok_log, log = M.git_cmd(ctx.cwd, { "log", "--oneline", base .. "..HEAD" })
        local ok_diff, diff = M.git_cmd(ctx.cwd, { "diff", base .. "...HEAD" })
        if (not ok_log or not log or log == "") and base == "main" then
            ok_log, log = M.git_cmd(ctx.cwd, { "log", "--oneline", "master..HEAD" })
            ok_diff, diff = M.git_cmd(ctx.cwd, { "diff", "master...HEAD" })
            base = "master"
        end
        if not ok_diff then
            ui.ai_print(ctx.ai_pane, "Could not diff against " .. base, "error")
            return
        end
        local extra = ctx.extra and ctx.extra ~= "" and ("\nExtra: " .. ctx.extra) or ""
        local prompt = "Draft a pull request against `"
            .. base
            .. "`: a short title and bullet summary. Put that in \"message\". Set command to null."
            .. extra
            .. "\n\nCommits:\n```\n"
            .. redact(log or "(none)")
            .. "\n```\n\nDiff:\n```\n"
            .. redact(cap(diff or "", git_opts(ctx.config).max_attach_bytes))
            .. "\n```"
        ask_ai(ctx.window, ctx.pane, ctx.config, prompt, "git:pr")
    end,
})

add_action({
    id = "resolve",
    aliases = { "conflicts" },
    label = "resolve — AI help with merge conflicts",
    kind = "ai",
    run = function(ctx)
        local ok, stdout, stderr = M.git_cmd(ctx.cwd, { "diff", "--name-only", "--diff-filter=U" })
        if not ok then
            ui.ai_print(ctx.ai_pane, stderr ~= "" and stderr or stdout, "error")
            return
        end
        local files = lines_from(stdout)
        if #files == 0 then
            ui.ai_print(ctx.ai_pane, "No unmerged (conflicted) files.", "success")
            return
        end
        local parts = { "Conflicted files:", table.concat(files, "\n"), "" }
        for _, rel in ipairs(files) do
            local abs = ctx.cwd .. util.separator .. rel
            local rok, content = util.read_text_file(abs, MAX_CONFLICT_FILE)
            if rok then
                table.insert(parts, "===== " .. rel .. " =====\n" .. content)
            else
                table.insert(parts, "===== " .. rel .. " =====\n(unreadable: " .. tostring(content) .. ")")
            end
        end
        local extra = ctx.extra and ctx.extra ~= "" and ("\nExtra: " .. ctx.extra) or ""
        local prompt = "Help resolve these merge conflicts. For each file, explain both sides and recommend a resolution. "
            .. "If a file should be edited, mention using @@path with a clear instruction. "
            .. "Set command null unless a single safe git command helps (e.g. git checkout --ours path)."
            .. extra
            .. "\n\n"
            .. redact(cap(table.concat(parts, "\n"), git_opts(ctx.config).max_attach_bytes))
        ask_ai(ctx.window, ctx.pane, ctx.config, prompt, "git:resolve")

        local first = files[1]
        ui.input_select(ctx.window, ctx.pane, "Conflict follow-up", {
            { id = "edit", label = "Edit first conflict with @@ — " .. first },
            { id = "done", label = "Done — read AI advice only" },
        }, function(win, p, id)
            if id ~= "edit" then
                return
            end
            local line = "@@"
                .. first
                .. " resolve merge conflict markers; keep the correct final content and remove all conflict marker lines"
            local ctxmod = require("context")
            local request, err = ctxmod.prepare_request(win, p, line, nil, ctx.config)
            if err then
                ui.ai_print(ui.ensure_ai_pane(win, p, ctx.config), err, "error")
                return
            end
            if request and M._dispatch then
                M._dispatch(win, p, request, ctx.config)
            end
        end)
    end,
})

add_action({
    id = "fixup",
    label = "fixup — AI suggest clean-up command sequence",
    kind = "ai",
    run = function(ctx)
        local status = select(1, M.collect_status(ctx.cwd)) or ""
        local extra = ctx.extra and ctx.extra ~= "" and ("\nExtra: " .. ctx.extra) or ""
        local prompt = "Given this dirty git status, propose a short safe sequence to clean up "
            .. "(stash, restore, checkout, etc.). Put explanation in message. "
            .. "Put ONE recommended next command in \"command\" (user will review; do not chain destructive resets)."
            .. extra
            .. "\n\nStatus:\n```\n"
            .. redact(status)
            .. "\n```"
        ask_ai(ctx.window, ctx.pane, ctx.config, prompt, "git:fixup")
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
    local base = select(1, split_count_id(id))
    if base ~= id then
        return ACTIONS[base]
    end
    return nil
end

-- Parse ask-line for git intercept.
-- Returns nil (not git), or { mode="picker"|"run"|"attach", id?, extra? }
-- @git:rebase15 / @git:soft3 / @git:log30 embed N; space form also works for those.
function M.parse_line(line)
    local token = trim(line or "")
    if token == "@git" or token == "@git:" then
        return { mode = "picker" }
    end
    local id, rest = token:match("^@git:([%w%-]+)%s*(.-)%s*$")
    if not id then
        return nil
    end
    local embedded_n
    id, embedded_n = split_count_id(id)
    local action = ACTIONS[id]
    if not action then
        return nil
    end
    rest = trim(rest)
    if rest == "" and embedded_n then
        rest = tostring(embedded_n)
    end
    if rest == "" then
        return { mode = "run", id = action.id }
    end
    if action.kind == "ai" then
        return { mode = "run", id = action.id, extra = rest }
    end
    -- Count-taking show actions: trailing integer is N, not an ask prompt.
    if (action.id == "log" or action.id == "rebase" or action.id == "soft") and positive_count(rest) then
        return { mode = "run", id = action.id, extra = rest }
    end
    if action.attach or action.kind == "show" then
        return { mode = "attach", id = action.id }
    end
    -- shell action with trailing text → still run the action
    return { mode = "run", id = action.id, extra = rest }
end

function M.run_action(window, pane, config, id, extra)
    -- Always use the real shell pane for cwd/git — never the AI output pane
    local shell_pane = ui.shell_pane_for(window, pane)
    local ai_pane = ui.ensure_ai_pane(window, shell_pane, config)
    local cwd, err = M.ensure_repo(shell_pane)
    if not cwd then
        ui.ai_print(ai_pane, err, "error")
        return
    end
    local embedded_n
    id, embedded_n = split_count_id(id)
    if (not extra or trim(extra) == "") and embedded_n then
        extra = tostring(embedded_n)
    end
    local action = ACTIONS[id]
    if not action then
        ui.ai_print(ai_pane, "Unknown @git:" .. tostring(id) .. " — try @git for the picker", "error")
        return
    end
    action.run({
        window = window,
        pane = shell_pane,
        ai_pane = ai_pane,
        config = config,
        cwd = cwd,
        extra = extra,
    })
end

function M.open_picker(window, pane, config)
    require("palette").show(window, pane, config, { scope = "git" })
end

M._dispatch = nil

return M
