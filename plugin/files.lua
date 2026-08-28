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

local function collect_via_fd(cwd, limit, want_dirs, max_depth)
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
    if max_depth then
        args[#args + 1] = "--max-depth"
        args[#args + 1] = tostring(max_depth)
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

local function collect_via_git(cwd, limit, want_dirs, max_depth)
    if max_depth then
        return nil
    end
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

local function collect_via_find(cwd, limit, want_dirs, max_depth)
    local args = {
        "find",
        cwd,
    }
    if max_depth then
        args[#args + 1] = "-maxdepth"
        args[#args + 1] = tostring(max_depth)
    end
    args[#args + 1] = "("
    args[#args + 1] = "-type"
    args[#args + 1] = "f"
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

--- Relative paths under cwd (or another root). opts.dirs includes directories.
--- opts.max_depth limits fd/find recursion (used for / and ~/ browsing).
function M.list_relative(cwd, config, opts)
    opts = opts or {}
    if not cwd or cwd == "" then
        return {}
    end
    local limit = max_n(config)
    local want_dirs = opts.dirs ~= false
    local max_depth = opts.max_depth
    local list = collect_via_fd(cwd, limit, want_dirs, max_depth)
        or collect_via_git(cwd, limit, want_dirs, max_depth)
        or collect_via_find(cwd, limit, want_dirs, max_depth)
    table.sort(list)
    return list
end

local function home_dir()
    return os.getenv("HOME") or os.getenv("USERPROFILE")
end

--- True when the typed @/# query is an absolute, ~/…, or ./ / ../ path.
function M.query_is_outside(query)
    if type(query) ~= "string" or query == "" then
        return false
    end
    if query:sub(1, 1) == "~" or query:sub(1, 1) == "/" then
        return true
    end
    if query == "." or query == ".." or query:sub(1, 2) == "./" or query:sub(1, 3) == "../" then
        return true
    end
    if query:sub(1, 2) == ".\\" or query:sub(1, 3) == "..\\" then
        return true
    end
    if query:match("^%a:[/\\]") then
        return true
    end
    return false
end

local function relpath_from(start, path)
    if not start or not path or start == "" or path == "" then
        return path
    end
    start = start:gsub("[/\\]+$", "")
    path = path:gsub("[/\\]+$", "")
    if path == start then
        return "."
    end
    local prefix = start .. "/"
    if path:sub(1, #prefix) == prefix then
        return path:sub(#prefix + 1)
    end
    local up = ""
    local cur = start
    for _ = 1, 32 do
        up = up .. "../"
        local parent = cur:match("^(.*)[/\\][^/\\]+$")
        if not parent or parent == "" or parent == cur then
            return path
        end
        cur = parent
        if path == cur then
            return up:gsub("/$", "")
        end
        local cur_prefix = cur .. "/"
        if path:sub(1, #cur_prefix) == cur_prefix then
            return up .. path:sub(#cur_prefix + 1)
        end
    end
    return path
end

local function max_depth_for(root, empty_filter)
    if empty_filter then
        return 1
    end
    if not root or root == "/" or root:match("^%a:[/\\]?$") then
        return 1
    end
    local home = home_dir()
    if home and root == home:gsub("[/\\]+$", "") then
        return 3
    end
    return 4
end

--- Split a ~/ /abs ../ query into a directory to list and a display prefix.
--- @return table|nil { root, filter, display_prefix, max_depth }
function M.resolve_outside_query(query, cwd)
    if not M.query_is_outside(query) then
        return nil
    end
    local trailing = query:match("[/\\]$") ~= nil
    local trimmed = query
    if trailing and query ~= "/" and not query:match("^%a:[/\\]$") then
        trimmed = query:gsub("[/\\]+$", "")
    end
    local expanded = util.expand_path(trimmed, cwd)
    if not expanded then
        return nil
    end
    expanded = expanded:gsub("[/\\]+$", "")
    if trimmed == "/" or query == "/" then
        expanded = "/"
    end

    local root, filt
    local treat_as_dir = trailing or query == "~" or query == ".." or query == "." or query == "~/"
    if treat_as_dir and util.path_exists_as_dir(expanded) then
        root, filt = expanded, ""
    elseif util.path_exists_as_dir(expanded) then
        root, filt = expanded, ""
    else
        local parent = util.dirname(expanded)
        filt = util.basename(expanded)
        while parent and parent ~= "" and not util.path_exists_as_dir(parent) do
            local name = util.basename(parent)
            filt = (name and name ~= "" and (name .. "/" .. filt)) or filt
            local next_parent = util.dirname(parent)
            if not next_parent or next_parent == parent then
                break
            end
            parent = next_parent
        end
        root = (parent and util.path_exists_as_dir(parent)) and parent or cwd
        filt = filt or ""
    end
    if not root or root == "" then
        return nil
    end

    local empty = not filt or filt == ""
    local home = home_dir()
    local prefix
    if query:sub(1, 1) == "~" and home then
        local home_n = home:gsub("[/\\]+$", "")
        if root == home_n then
            prefix = "~/"
        elseif root:sub(1, #home_n + 1) == home_n .. "/" then
            prefix = "~/" .. root:sub(#home_n + 2) .. "/"
        else
            prefix = root .. "/"
        end
    elseif query:sub(1, 1) == "/" or query:match("^%a:[/\\]") then
        if root == "/" then
            prefix = "/"
        else
            prefix = root:gsub("[/\\]+$", "") .. "/"
        end
    else
        local rel = relpath_from(cwd, root)
        if rel == "." then
            prefix = query:sub(1, 2) == "./" and "./" or ""
        else
            prefix = rel:match("[/\\]$") and rel or (rel .. "/")
        end
    end

    return {
        root = root,
        filter = filt or "",
        display_prefix = prefix,
        max_depth = max_depth_for(root, empty),
    }
end

local function join_display(prefix, rel)
    prefix = prefix or ""
    rel = rel or ""
    if prefix == "" then
        return rel
    end
    if rel == "" then
        return prefix
    end
    if prefix:match("[/\\]$") then
        return prefix .. rel
    end
    return prefix .. "/" .. rel
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
--- CTRL+I does not call this — composer.py indexes cwd on a background thread
--- so the input pane can appear immediately.
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

local function add_listed_choices(choices, rels, list_root, display_prefix, filter)
    filter = (filter or ""):lower()
    for _, rel in ipairs(rels) do
        local shown = join_display(display_prefix, rel)
        if filter == "" or shown:lower():find(filter, 1, true) or rel:lower():find(filter, 1, true) then
            local kind = M.entry_kind(list_root, rel)
            local label = shown
            if kind == "dir" and not label:match("/$") then
                label = label .. "/"
            end
            choices[#choices + 1] = { id = shown, label = label }
        end
    end
end

--- opts: mode "attach"|"edit", title?, fuzzy_description?, prefix?, root?, display_prefix?,
---       max_depth?, on_chosen(window,pane,rel_path)
function M.show_picker(window, pane, config, opts)
    opts = opts or {}
    pane = ui.shell_pane_for(window, pane)
    local cwd = util.get_pane_cwd(pane)
    if not cwd then
        ui.ai_print(ui.ensure_ai_pane(window, pane, config), "No pane cwd — cannot list files.", "error")
        return
    end

    local prefix = opts.prefix or ""
    local list_root = opts.root or cwd
    local display_prefix = opts.display_prefix or ""
    local max_depth = opts.max_depth
    local filter = prefix
    local browsing = opts.root ~= nil

    if not browsing and M.query_is_outside(prefix) then
        local info = M.resolve_outside_query(prefix, cwd)
        if info and info.root then
            list_root = info.root
            display_prefix = info.display_prefix or ""
            max_depth = info.max_depth
            filter = info.filter or prefix
            browsing = true
        end
    end

    local rels = M.list_relative(list_root, config, { dirs = true, max_depth = max_depth })
    local choices = {}
    if browsing then
        choices[#choices + 1] = { id = "__nav:cwd", label = "(cwd)  back to current directory" }
        choices[#choices + 1] = { id = "__nav:..", label = "../  parent directory" }
    elseif prefix == "" then
        choices[#choices + 1] = { id = "__nav:~/", label = "~/  home" }
        choices[#choices + 1] = { id = "__nav:..", label = "../  parent of cwd" }
        choices[#choices + 1] = { id = "__nav:/", label = "/  filesystem root" }
    end
    local nav_n = #choices

    add_listed_choices(choices, rels, list_root, display_prefix, browsing and "" or prefix)
    if browsing and filter ~= "" and #choices <= nav_n then
        -- No substring hits with the leftover segment — show the whole listing.
        choices = {
            { id = "__nav:cwd", label = "(cwd)  back to current directory" },
            { id = "__nav:..", label = "../  parent directory" },
        }
        add_listed_choices(choices, rels, list_root, display_prefix, "")
    elseif not browsing and prefix ~= "" and #choices <= nav_n then
        local fallback = {}
        add_listed_choices(fallback, rels, cwd, "", "")
        for _, c in ipairs(fallback) do
            choices[#choices + 1] = c
        end
    end

    if #choices <= nav_n and #rels == 0 then
        ui.ai_print(ui.ensure_ai_pane(window, pane, config), "No files found under " .. list_root, "warn")
        return
    end

    local mode = opts.mode or "attach"
    local title = opts.title
        or (mode == "edit" and "wezai — pick file to edit (#)" or "wezai — pick file to attach (@)")
    if browsing and display_prefix ~= "" then
        title = title .. "  " .. display_prefix
    end
    local fuzzy_description = opts.fuzzy_description or "Fuzzy file (cwd, ~/ , / , ../): "

    local function reopen(next_opts)
        next_opts.mode = mode
        next_opts.title = opts.title
        next_opts.on_chosen = opts.on_chosen
        next_opts.fuzzy_description = fuzzy_description
        M.show_picker(window, pane, config, next_opts)
    end

    ui.input_select(window, pane, title, choices, function(win, p, id)
        if not id or id == "" then
            return
        end
        if id == "__nav:cwd" then
            reopen({})
            return
        end
        if id == "__nav:~/" then
            local home = home_dir()
            if not home then
                return
            end
            reopen({ root = home, display_prefix = "~/", max_depth = 1 })
            return
        end
        if id == "__nav:/" then
            reopen({ root = "/", display_prefix = "/", max_depth = 1 })
            return
        end
        if id == "__nav:.." then
            local from = list_root
            local parent = util.dirname(from)
            if not parent or parent == "" then
                parent = from
            end
            local disp
            if parent == cwd then
                reopen({})
                return
            end
            local home = home_dir()
            if home and parent == home:gsub("[/\\]+$", "") then
                disp = "~/"
            elseif parent == "/" then
                disp = "/"
            else
                local rel = relpath_from(cwd, parent)
                if rel == "." then
                    disp = ""
                else
                    disp = rel:match("[/\\]$") and rel or (rel .. "/")
                end
            end
            reopen({
                root = parent,
                display_prefix = disp,
                max_depth = max_depth_for(parent, true),
            })
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
