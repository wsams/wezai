-- Fuzzy file attach/edit via WezTerm InputSelector (built-in fuzzy filter).
local wezterm = require("wezterm")
local util = require("util")
local ui = require("ui")

local M = {}

local SKIP_DIR = {
    [".git"] = true,
    ["node_modules"] = true,
    [".venv"] = true,
    ["venv"] = true,
    ["__pycache__"] = true,
    [".tox"] = true,
    ["dist"] = true,
    ["build"] = true,
    [".next"] = true,
    ["target"] = true,
}

local function max_n(config)
    local f = config and config.files
    return (f and f.max_candidates) or 400
end

local function should_skip(rel)
    for part in (rel .. "/"):gmatch("([^/]+)/") do
        if SKIP_DIR[part] then
            return true
        end
        -- Skip other dot-directories, but keep .github / .config files reachable
        if part:sub(1, 1) == "." and part ~= ".github" and part ~= ".config" then
            return true
        end
    end
    return false
end

local function collect_via_fd(cwd, limit)
    local ok, stdout = util.run_cmd({
        "fd",
        "--type",
        "f",
        "--hidden",
        "--exclude",
        ".git",
        "--exclude",
        "node_modules",
        ".",
        cwd,
    })
    if not ok or not stdout or stdout == "" then
        return nil
    end
    local out = {}
    for line in (stdout .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then
            local rel = line
            if rel:sub(1, #cwd + 1) == cwd .. "/" then
                rel = rel:sub(#cwd + 2)
            end
            if not should_skip(rel) then
                out[#out + 1] = rel
                if #out >= limit then
                    break
                end
            end
        end
    end
    return out
end

local function collect_via_git(cwd, limit)
    local ok, stdout = util.run_cmd({ "git", "-C", cwd, "ls-files", "-z", "--cached", "--others", "--exclude-standard" })
    if not ok or not stdout or stdout == "" then
        return nil
    end
    local out = {}
    for rel in stdout:gmatch("([^%z]+)") do
        if rel ~= "" and not should_skip(rel) then
            out[#out + 1] = rel
            if #out >= limit then
                break
            end
        end
    end
    return out
end

local function collect_via_find(cwd, limit)
    local ok, stdout = util.run_cmd({
        "find",
        cwd,
        "-type",
        "f",
        "-not",
        "-path",
        "*/.git/*",
        "-not",
        "-path",
        "*/node_modules/*",
        "-print",
    })
    if not ok or not stdout then
        return {}
    end
    local out = {}
    for line in (stdout .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then
            local rel = line
            if rel:sub(1, #cwd + 1) == cwd .. "/" then
                rel = rel:sub(#cwd + 2)
            end
            if rel ~= "" and not should_skip(rel) then
                out[#out + 1] = rel
                if #out >= limit then
                    break
                end
            end
        end
    end
    return out
end

--- Relative paths under cwd, newest sources preferred.
function M.list_relative(cwd, config)
    if not cwd or cwd == "" then
        return {}
    end
    local limit = max_n(config)
    local list = collect_via_fd(cwd, limit)
        or collect_via_git(cwd, limit)
        or collect_via_find(cwd, limit)
    table.sort(list)
    return list
end

--- opts: mode "attach"|"edit", title?, fuzzy_description?, on_chosen(window,pane,rel_path)
function M.show_picker(window, pane, config, opts)
    opts = opts or {}
    pane = ui.shell_pane_for(window, pane)
    local cwd = util.get_pane_cwd(pane)
    if not cwd then
        ui.ai_print(ui.ensure_ai_pane(window, pane, config), "No pane cwd — cannot list files.", "error")
        return
    end

    local rels = M.list_relative(cwd, config)
    if #rels == 0 then
        ui.ai_print(ui.ensure_ai_pane(window, pane, config), "No files found under " .. cwd, "warn")
        return
    end

    local choices = {}
    for _, rel in ipairs(rels) do
        choices[#choices + 1] = { id = rel, label = rel }
    end

    local mode = opts.mode or "attach"
    local title = opts.title
        or (mode == "edit" and "wezai — pick file to edit (@@)" or "wezai — pick file to attach (@)")
    local fuzzy_description = opts.fuzzy_description or "Fuzzy file: "

    ui.input_select(window, pane, title, choices, function(win, p, id)
        if not id or id == "" then
            return
        end
        if opts.on_chosen then
            opts.on_chosen(win, p, id, cwd)
        end
    end, {
        fuzzy = true,
        fuzzy_description = fuzzy_description,
    })
end

--- Detect bare @ / @@ / @pick / @@pick (optional trailing query text).
--- @return table|nil { mode="attach"|"edit", rest=string }
function M.parse_pick_line(line)
    if type(line) ~= "string" then
        return nil
    end
    local trimmed = line:match("^%s*(.-)%s*$") or ""
    local edit, rest = trimmed:match("^@@pick%s*(.*)$")
    if edit ~= nil then
        return { mode = "edit", rest = rest or "" }
    end
    local attach, arest = trimmed:match("^@pick%s*(.*)$")
    if attach ~= nil then
        return { mode = "attach", rest = arest or "" }
    end
    if trimmed == "@" or trimmed == "@@" then
        return { mode = (trimmed == "@@") and "edit" or "attach", rest = "" }
    end
    return nil
end

return M
