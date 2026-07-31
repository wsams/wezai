local util = require("util")
local ui = require("ui")

local M = {}

local RISK_PATTERNS = {
    "rm%s+%-rf",
    "rm%s+%-fr",
    "dd%s+if=",
    "mkfs",
    "kubectl%s+delete",
    "git%s+push%s+[^\n]*%-%-force",
    "git%s+push%s+[^\n]*%-f%s",
    "git%s+push",
    "git%s+reset",
    "git%s+rebase",
    "git%s+checkout%s+[^\n]*%-%-force",
    "git%s+clean%s+%-",
    "chmod%s+%-R%s+777",
    ">:?/dev/sd",
    "curl%s+[^\n]*%|%s*sh",
    "wget%s+[^\n]*%|%s*sh",
    "DROP%s+TABLE",
    "TRUNCATE%s+",
    "diskutil%s+erase",
}

local function classify_shell_name(name)
    if not name or name == "" then
        return nil
    end
    name = name:lower()
    -- basename from path
    name = name:match("([^/\\]+)$") or name
    if name:find("fish", 1, true) then
        return "fish"
    end
    if name:find("zsh", 1, true) then
        return "zsh"
    end
    if name == "bash" or name:find("bash", 1, true) then
        return "bash"
    end
    if name:find("pwsh", 1, true) or name:find("powershell", 1, true) then
        return "powershell"
    end
    if name == "sh" or name == "dash" then
        return "bash" -- treat posix sh like bash for history purposes
    end
    return nil
end

--- Login/$SHELL fallback (no pane). Used at plugin load and when pane probe fails.
function M.env_shell()
    return classify_shell_name(os.getenv("SHELL")) or "unknown"
end

function M.detect_shell(pane)
    if pane then
        -- 1) Foreground process name
        local ok, name = pcall(function()
            return pane:get_foreground_process_name()
        end)
        if ok then
            local kind = classify_shell_name(name)
            if kind then
                return kind
            end
        end

        -- 2) Process info (executable / argv) when available
        local ok_info, info = pcall(function()
            return pane:get_foreground_process_info()
        end)
        if ok_info and type(info) == "table" then
            local kind = classify_shell_name(info.executable or info.name)
            if kind then
                return kind
            end
            if type(info.argv) == "table" then
                for _, arg in ipairs(info.argv) do
                    kind = classify_shell_name(arg)
                    if kind then
                        return kind
                    end
                end
            end
        end
    end

    return M.env_shell()
end

--- Injected into system_prompt on every ask so commands match the active shell.
function M.dialect_hint(kind)
    if kind == "fish" then
        return table.concat({
            "ALWAYS provide commands in Fish shell syntax (not bash/zsh).",
            "Rules:",
            "- Use `and` / `or` for conditionals; do NOT use bash `&&` / `||` / `[[ ]]` / `export FOO=bar` (use `set -x FOO bar`).",
            "- `end` is ONLY valid to close `if` / `else if` / `switch` / `while` / `for` / `begin` / `function`. Never trail a one-liner with `; end`.",
            "- Confirm prompts: either",
            '  `read -l -P "Prompt? (y/N) " confirm; and test "$confirm" = "y"; and some_command`',
            "  (no `end`) OR a real block:",
            '  `read -l -P "Prompt? (y/N) " confirm; if test "$confirm" = "y"; some_command; end`',
            "- Prefer a single pasteable command line when possible.",
        }, " ")
    elseif kind == "zsh" then
        return "ALWAYS provide commands in zsh format (zsh/bash-compatible is fine)."
    elseif kind == "bash" then
        return "ALWAYS provide commands in bash format (prefer portable bash)."
    elseif kind == "powershell" then
        return "ALWAYS provide commands in PowerShell format (prefer cmdlets)."
    end
    return "Shell unknown — prefer portable POSIX commands."
end

function M.is_risky(command)
    if not command or command == "" then
        return false
    end
    for _, pat in ipairs(RISK_PATTERNS) do
        if command:lower():find(pat) then
            return true
        end
    end
    return false
end

function M.read_clipboard()
    local args
    if util.is_windows then
        args = { "powershell", "-NoProfile", "-Command", "Get-Clipboard" }
    else
        -- macOS first, then Wayland/X11
        local ok, stdout = util.run_cmd({ "pbpaste" })
        if ok and stdout then
            return stdout
        end
        ok, stdout = util.run_cmd({ "wl-paste", "-n" })
        if ok and stdout then
            return stdout
        end
        ok, stdout = util.run_cmd({ "xclip", "-selection", "clipboard", "-o" })
        if ok and stdout then
            return stdout
        end
        return nil
    end
    local ok, stdout = util.run_cmd(args)
    if ok then
        return stdout
    end
    return nil
end

function M.write_clipboard(text)
    if not text then
        return false
    end
    if util.is_windows then
        local ok = util.run_cmd({
            "powershell",
            "-NoProfile",
            "-Command",
            "Set-Clipboard -Value @'\n" .. text .. "\n'@",
        })
        return ok
    end
    -- Prefer pbcopy on macOS
    local tmp = os.tmpname()
    local f = io.open(tmp, "wb")
    if not f then
        return false
    end
    f:write(text)
    f:close()
    local ok = util.run_cmd({ "sh", "-c", "cat '" .. tmp .. "' | pbcopy" })
    if not ok then
        ok = util.run_cmd({ "sh", "-c", "cat '" .. tmp .. "' | xclip -selection clipboard" })
    end
    if not ok then
        ok = util.run_cmd({ "sh", "-c", "cat '" .. tmp .. "' | wl-copy" })
    end
    os.remove(tmp)
    return ok
end

-- Send command to shell pane, optionally confirming risky commands.
-- opts.skip_risk_confirm: when true, skip the risk gate (caller already confirmed).
-- callback(sent:boolean)
function M.send_command(window, shell_pane, ai_pane, config, command, callback, opts)
    callback = callback or function() end
    opts = opts or {}
    if not command or command == "" then
        callback(false)
        return
    end

    local function do_send()
        util.clear_line(shell_pane)
        shell_pane:send_text(command)
        callback(true)
    end

    if opts.skip_risk_confirm then
        do_send()
        return
    end

    if config.require_risk_confirm ~= false and M.is_risky(command) then
        ui.ai_print(ai_pane, "Risky command:\n" .. command, "warn")
        ui.confirm(window, shell_pane, "Send risky command to shell?", "send", function(_, _, yes)
            if yes then
                do_send()
            else
                ui.ai_print(ai_pane, "Cancelled — command not sent.", "warn")
                callback(false)
            end
        end)
    else
        do_send()
    end
end

return M
