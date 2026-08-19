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
    [".wezai"] = true,
}

local SKIP_FILE = {
    ["package-lock.json"] = true,
    ["yarn.lock"] = true,
    ["pnpm-lock.yaml"] = true,
    ["Cargo.lock"] = true,
    [".DS_Store"] = true,
}

local SOURCE_WEIGHT = {
    lua = 5,
    py = 5,
    js = 4,
    ts = 4,
    tsx = 4,
    jsx = 4,
    go = 5,
    rs = 5,
    tf = 5,
    hcl = 5,
    sh = 4,
    bash = 4,
    fish = 4,
    zsh = 4,
    md = 3,
    json = 3,
    yml = 3,
    yaml = 3,
    toml = 3,
    txt = 2,
    css = 2,
    html = 2,
    sql = 3,
    vim = 3,
}

local function max_n(config)
    local f = config and config.files
    return (f and f.max_candidates) or 400
end

local function max_dir_files(config)
    local c = config and config.context
    return (c and c.max_dir_files) or 80
end

function M.is_wezai_backup(name)
    if not name or name == "" then
        return false
    end
    local base = name:match("([^/\\]+)$") or name
    if base:find("wezai", 1, true) and base:match("%.bak$") then
        return true
    end
    if base:match("^%..+%.wezai%.bak$") then
        return true
    end
    if base:match("%.wezai%.bak$") then
        return true
    end
    return false
end

local function should_skip(rel)
    if not rel or rel == "" then
        return true
    end
    if M.is_wezai_backup(rel) then
        return true
    end
    local base = rel:match("([^/\\]+)$") or rel
    if SKIP_FILE[base] then
        return true
    end
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

local function strip_cwd(cwd, path)
    if cwd and path:sub(1, #cwd + 1) == cwd .. "/" then
        return path:sub(#cwd + 2)
    end
    return path
end

local function collect_via_fd(cwd, limit, want_dirs)
    local args = {
        "fd",
        "--hidden",
        "--exclude",
        ".git",
        "--exclude",
        "node_modules",
        "--exclude",
        "*.wezai.bak",
    }
    if want_dirs then
        args[#args + 1] = "--type"
        args[#args + 1] = "f"
        args[#args + 1] = "--type"
        args[#args + 1] = "d"
    else
        args[#args + 1] = "--type"
        args[#args + 1] = "f"
    end
    args[#args + 1] = "."
    args[#args + 1] = cwd
    local ok, stdout = util.run_cmd(args)
    if not ok or not stdout or stdout == "" then
        return nil
    end
    local out = {}
    for line in (stdout .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then
            local rel = strip_cwd(cwd, line)
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

local function collect_via_git(cwd, limit, want_dirs)
    local ok, stdout = util.run_cmd({ "git", "-C", cwd, "ls-files", "-z", "--cached", "--others", "--exclude-standard" })
    if not ok or not stdout or stdout == "" then
        return nil
    end
    local out = {}
    local seen = {}
    local function add(rel)
        if rel == "" or seen[rel] or should_skip(rel) then
            return
        end
        seen[rel] = true
        out[#out + 1] = rel
    end
    for rel in stdout:gmatch("([^%z]+)") do
        add(rel)
        if want_dirs then
            local acc = ""
            for part in rel:gmatch("([^/]+)/") do
                acc = (acc == "") and part or (acc .. "/" .. part)
                add(acc)
                if #out >= limit then
                    break
                end
            end
        end
        if #out >= limit then
            break
        end
    end
    return out
end

local function collect_via_find(cwd, limit, want_dirs)
    local args = {
        "find",
        cwd,
        "(",
        "-type",
        "f",
    }
    if want_dirs then
        args[#args + 1] = "-o"
        args[#args + 1] = "-type"
        args[#args + 1] = "d"
    end
    args[#args + 1] = ")"
    args[#args + 1] = "-not"
    args[#args + 1] = "-path"
    args[#args + 1] = "*/.git/*"
    args[#args + 1] = "-not"
    args[#args + 1] = "-path"
    args[#args + 1] = "*/node_modules/*"
    args[#args + 1] = "-print"
    local ok, stdout = util.run_cmd(args)
    if not ok or not stdout then
        return {}
    end
    local out = {}
    for line in (stdout .. "\n"):gmatch("(.-)\n") do
        if line ~= "" and line ~= cwd then
            local rel = strip_cwd(cwd, line)
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

--- Relative paths under cwd. opts.dirs includes directories (for @dir/ completion).
function M.list_relative(cwd, config, opts)
    opts = opts or {}
    if not cwd or cwd == "" then
        return {}
    end
    local limit = max_n(config)
    local want_dirs = opts.dirs ~= false
    local list = collect_via_fd(cwd, limit, want_dirs)
        or collect_via_git(cwd, limit, want_dirs)
        or collect_via_find(cwd, limit, want_dirs)
    table.sort(list)
    return list
end

--- Classify a relative path as file or directory (best-effort; trailing / → dir).
function M.entry_kind(cwd, rel)
    if not rel or rel == "" then
        return "file"
    end
    if rel:match("[/\\]$") then
        return "dir"
    end
    local abs = util.expand_path(rel, cwd)
    if abs and util.path_exists_as_dir(abs) then
        return "dir"
    end
    return "file"
end

--- Write composer candidate list: "F\trel" / "D\trel" lines.
function M.write_candidate_list(cwd, config, dest)
    local rels = M.list_relative(cwd, config, { dirs = true })
    local lines = {}
    for _, rel in ipairs(rels) do
        local kind = M.entry_kind(cwd, rel)
        local tag = (kind == "dir") and "D" or "F"
        local shown = rel
        if kind == "dir" and not shown:match("/$") then
            shown = shown .. "/"
        end
        lines[#lines + 1] = tag .. "\t" .. shown
    end
    return util.write_text_file(dest, table.concat(lines, "\n") .. "\n")
end

local function ext_of(path)
    local base = path:match("([^/\\]+)$") or path
    return (base:match("%.([%w]+)$") or ""):lower()
end

function M.attach_weight(path)
    local base = path:match("([^/\\]+)$") or path
    if SKIP_FILE[base] or M.is_wezai_backup(base) then
        return -1
    end
    return SOURCE_WEIGHT[ext_of(path)] or 1
end

--- Recursively list files under abs_dir (absolute paths).
function M.walk_files(abs_dir, config)
    if not abs_dir or abs_dir == "" or not util.path_exists_as_dir(abs_dir) then
        return {}
    end
    local limit = max_dir_files(config)
    local rels = M.list_relative(abs_dir, config, { dirs = false })
    local out = {}
    for _, rel in ipairs(rels) do
        if M.attach_weight(rel) >= 0 then
            local abs = abs_dir:gsub("[/\\]+$", "") .. util.separator .. rel
            abs = abs:gsub("([/\\])[/\\]+", "%1")
            if not util.path_exists_as_dir(abs) then
                out[#out + 1] = abs
                if #out >= limit then
                    break
                end
            end
        end
    end
    table.sort(out, function(a, b)
        local wa, wb = M.attach_weight(a), M.attach_weight(b)
        if wa ~= wb then
            return wa > wb
        end
        return a < b
    end)
    return out
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

    local rels = M.list_relative(cwd, config, { dirs = true })
    if #rels == 0 then
        ui.ai_print(ui.ensure_ai_pane(window, pane, config), "No files found under " .. cwd, "warn")
        return
    end

    local prefix = opts.prefix
    local choices = {}
    for _, rel in ipairs(rels) do
        if not prefix or prefix == "" or rel:lower():find(prefix:lower(), 1, true) then
            local kind = M.entry_kind(cwd, rel)
            local label = rel
            if kind == "dir" and not label:match("/$") then
                label = label .. "/"
            end
            choices[#choices + 1] = { id = rel, label = label }
        end
    end
    if #choices == 0 then
        for _, rel in ipairs(rels) do
            local kind = M.entry_kind(cwd, rel)
            local label = rel
            if kind == "dir" and not label:match("/$") then
                label = label .. "/"
            end
            choices[#choices + 1] = { id = rel, label = label }
        end
    end

    local mode = opts.mode or "attach"
    local title = opts.title
        or (mode == "edit" and "wezai — pick file to edit (#)" or "wezai — pick file to attach (@)")
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

--- Detect bare @ / @@ / # / @pick / @@pick / #pick (optional trailing query text).
--- @return table|nil { mode="attach"|"edit", rest=string }
function M.parse_pick_line(line)
    if type(line) ~= "string" then
        return nil
    end
    local trimmed = line:match("^%s*(.-)%s*$") or ""
    local hash_pick, hrest = trimmed:match("^#pick%s*(.*)$")
    if hash_pick ~= nil then
        return { mode = "edit", rest = hrest or "" }
    end
    local edit, rest = trimmed:match("^@@pick%s*(.*)$")
    if edit ~= nil then
        return { mode = "edit", rest = rest or "" }
    end
    local attach, arest = trimmed:match("^@pick%s*(.*)$")
    if attach ~= nil then
        return { mode = "attach", rest = arest or "" }
    end
    if trimmed == "#" or trimmed == "@@" then
        return { mode = "edit", rest = "" }
    end
    if trimmed == "@" then
        return { mode = "attach", rest = "" }
    end
    return nil
end

M.SKIP_DIR = SKIP_DIR
M.should_skip = should_skip

return M
