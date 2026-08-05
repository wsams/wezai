-- Shared helpers for wezai.
local wezterm = require("wezterm")

local SEP = package.config:sub(1, 1)
local WIN = SEP == "\\"

local M = {
    separator = SEP,
    is_windows = WIN,
}

local function trim(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Strip markdown code fences / leading junk so JSON parsers can try again.
function M.clean_response(raw)
    local s = trim(raw)
    if s == "" then
        return ""
    end
    -- Drop opening ```lang and closing ``` lines (any position).
    local lines = {}
    for line in (s .. "\n"):gmatch("(.-)\n") do
        local t = trim(line)
        if not t:match("^```") then
            table.insert(lines, line)
        end
    end
    return trim(table.concat(lines, "\n"))
end

--- First top-level `{ ... }` in `s`, respecting JSON strings/escapes.
--- Thinking models often wrap the required object in prose; extract it.
function M.extract_json_object(s)
    if type(s) ~= "string" then
        return nil
    end
    local start = s:find("{", 1, true)
    if not start then
        return nil
    end
    local depth = 0
    local in_str = false
    local escape = false
    for i = start, #s do
        local c = s:sub(i, i)
        if in_str then
            if escape then
                escape = false
            elseif c == "\\" then
                escape = true
            elseif c == '"' then
                in_str = false
            end
        else
            if c == '"' then
                in_str = true
            elseif c == "{" then
                depth = depth + 1
            elseif c == "}" then
                depth = depth - 1
                if depth == 0 then
                    return s:sub(start, i)
                end
            end
        end
    end
    return nil
end

function M.parse_json_response(raw)
    if type(raw) ~= "string" or trim(raw) == "" then
        return nil, "empty response"
    end
    local candidates = { trim(raw) }
    local body = raw:match("```[%w_]*%s*\r?\n(.-)\r?\n```")
        or raw:match("```[%w_]*%s*(.-)```")
    if body then
        table.insert(candidates, trim(body))
    end
    table.insert(candidates, M.clean_response(raw))
    local extracted = M.extract_json_object(raw)
    if extracted then
        table.insert(candidates, extracted)
    end
    local cleaned_extract = M.extract_json_object(M.clean_response(raw))
    if cleaned_extract then
        table.insert(candidates, cleaned_extract)
    end

    for _, blob in ipairs(candidates) do
        local ok, decoded = pcall(wezterm.json_parse, blob)
        if ok and type(decoded) == "table" then
            return decoded, nil
        end
    end
    return nil, "Failed to parse JSON response"
end

--- Clear the current input line in a shell pane before injecting text.
function M.clear_line(pane)
    if WIN then
        -- ESC [ 2 K = erase line; CR = column 0
        pane:send_text("\27[2K\r")
    else
        -- Ctrl-U then CR (common readline/fish binding)
        pane:send_text(string.char(21) .. "\r")
    end
end

function M.get_selection(window, pane)
    local ok, text = pcall(function()
        return window:get_selection_text_for_pane(pane)
    end)
    if not ok then
        return nil
    end
    text = trim(text)
    if text == "" then
        return nil
    end
    return text
end

function M.truncate(text, max_len)
    max_len = max_len or 200
    text = text or ""
    if #text <= max_len then
        return text
    end
    return text:sub(1, max_len) .. "…"
end

function M.get_pane_cwd(pane)
    local ok, cwd = pcall(function()
        return pane:get_current_working_dir()
    end)
    if not ok or cwd == nil then
        return nil
    end
    for _, key in ipairs({ "file_path", "path" }) do
        local pok, val = pcall(function()
            return cwd[key]
        end)
        if pok and type(val) == "string" and val ~= "" then
            return val
        end
    end
    if type(cwd) ~= "string" then
        return nil
    end
    local path = cwd:match("^file://[^/]*(/.*)$") or cwd:match("^file:(/.*)$")
    if not path then
        return nil
    end
    return (path:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

function M.is_absolute_path(path)
    if WIN then
        return path:match("^%a:[/\\]") ~= nil or path:match("^[/\\]") ~= nil
    end
    return path:sub(1, 1) == "/"
end

function M.basename(path)
    if not path or path == "" then
        return ""
    end
    return path:match("([^/\\]+)$") or path
end

function M.dirname(path)
    if not path or path == "" then
        return nil
    end
    return path:match("^(.*)[/\\][^/\\]+$")
end

--- Create parent directories for `path` (mkdir -p). No-op if already present.
function M.ensure_parent_dir(path)
    local dir = M.dirname(path)
    if not dir or dir == "" then
        return true
    end
    if M.path_exists_as_dir(dir) then
        return true
    end
    if not wezterm.run_child_process then
        return false
    end
    local ok
    if WIN then
        ok = wezterm.run_child_process({ "cmd", "/c", "mkdir", dir })
    else
        ok = wezterm.run_child_process({ "mkdir", "-p", dir })
    end
    return ok == true
end

function M.expand_path(path, cwd)
    if not path or path == "" then
        return nil
    end
    local home = os.getenv("HOME") or os.getenv("USERPROFILE")
    if path == "~" then
        return home
    end
    if path:sub(1, 2) == "~/" or (WIN and path:sub(1, 2) == "~\\") then
        if not home then
            return nil
        end
        path = home .. path:sub(2)
    end
    if not M.is_absolute_path(path) then
        if not cwd or cwd == "" then
            return nil
        end
        path = cwd:gsub("[/\\]+$", "") .. SEP .. path
    end
    return path:gsub("([/\\])[/\\]+", "%1")
end

local function proc_ok(argv)
    return wezterm.run_child_process and wezterm.run_child_process(argv) == true
end

function M.path_exists_as_file(path)
    if not path or path == "" or path:match("[/\\]$") then
        return false
    end
    if wezterm.run_child_process then
        if WIN then
            return proc_ok({
                "cmd",
                "/c",
                'if exist "' .. path .. '\\*" (exit 1) else if exist "' .. path .. '" (exit 0) else (exit 1)',
            })
        end
        return proc_ok({ "test", "-f", path })
    end
    local f = io.open(path, "rb")
    if not f then
        return false
    end
    f:close()
    return true
end

function M.path_exists_as_dir(path)
    if not path or path == "" then
        return false
    end
    if wezterm.run_child_process then
        if WIN then
            return proc_ok({ "cmd", "/c", 'if exist "' .. path .. '\\*" (exit 0) else (exit 1)' })
        end
        return proc_ok({ "test", "-d", path })
    end
    return false
end

function M.read_text_file(path, max_bytes)
    local ok, content_or_err, meta = M.read_text_file_smart(path, {
        max_bytes = max_bytes,
        large_file = "error",
    })
    if not ok then
        return false, content_or_err
    end
    return true, content_or_err, meta
end

--- Read a text file; oversized files can be head+tail truncated for AI attach.
--- opts: max_bytes, large_file ("error"|"head_tail"|"head"), head_bytes, tail_bytes
--- @return ok, content_or_err, meta
function M.read_text_file_smart(path, opts)
    opts = opts or {}
    local max_bytes = opts.max_bytes or 100000
    local mode = opts.large_file or "head_tail"
    local f, err = io.open(path, "rb")
    if not f then
        return false, "cannot read file: " .. (err or path), nil
    end
    local size = f:seek("end")
    if not size then
        f:close()
        return false, "cannot determine size: " .. path, nil
    end

    if size <= max_bytes then
        f:seek("set")
        local content = f:read("*a")
        f:close()
        if content == nil then
            return false, "failed to read: " .. path, nil
        end
        if content:find("\0", 1, true) then
            return false, "binary file not supported: " .. path, nil
        end
        return true, content, { truncated = false, size = size }
    end

    if mode == "error" then
        f:close()
        return false,
            string.format(
                "file too large (%d bytes, max %d): %s — raise max_file_bytes or rely on head/tail attach",
                size,
                max_bytes,
                path
            ),
            nil
    end

    local head_n = tonumber(opts.head_bytes) or math.floor(max_bytes * 0.6)
    local tail_n = tonumber(opts.tail_bytes) or math.max(0, max_bytes - head_n)
    if head_n < 1 then
        head_n = math.floor(max_bytes * 0.6)
    end
    if mode == "head" then
        tail_n = 0
        head_n = max_bytes
    end
    if head_n + tail_n > size then
        -- Degenerate: just read whole file
        f:seek("set")
        local content = f:read("*a")
        f:close()
        return true, content, { truncated = false, size = size }
    end

    f:seek("set")
    local head = f:read(head_n) or ""
    local tail = ""
    if tail_n > 0 then
        f:seek("end", -tail_n)
        tail = f:read(tail_n) or ""
    end
    f:close()

    if head:find("\0", 1, true) or (tail ~= "" and tail:find("\0", 1, true)) then
        return false, "binary file not supported: " .. path, nil
    end

    local omitted = size - #head - #tail
    local marker = string.format(
        "\n\n… [truncated %d bytes from middle — file is %d bytes; attached head %d + tail %d] …\n\n",
        omitted,
        size,
        #head,
        #tail
    )
    local content = head .. marker .. tail
    return true, content, {
        truncated = true,
        size = size,
        head_bytes = #head,
        tail_bytes = #tail,
        omitted_bytes = omitted,
    }
end

function M.write_text_file(path, content)
    local f, err = io.open(path, "wb")
    if not f then
        return false, "cannot write file: " .. (err or path)
    end
    local ok, write_err = f:write(content)
    f:close()
    if not ok then
        return false, "failed writing file: " .. (write_err or path)
    end
    return true, nil
end

function M.tab_id(window)
    local ok, tab = pcall(function()
        return window:active_tab()
    end)
    if not ok or not tab then
        return "default"
    end
    local ok2, id = pcall(function()
        return tab:tab_id()
    end)
    if ok2 and id ~= nil then
        return tostring(id)
    end
    return "default"
end

function M.copy_config(config)
    local c = {}
    for k, v in pairs(config) do
        c[k] = v
    end
    if config._model_override and config._model_override ~= "" then
        c.model = config._model_override
    end
    return c
end

--- Run a child process. Never throws — missing binaries become ok=false.
function M.run_cmd(args)
    if type(args) ~= "table" or #args == 0 then
        return false, "", "empty command"
    end
    local rok, ok, stdout, stderr = pcall(wezterm.run_child_process, args)
    if not rok then
        return false, "", tostring(ok)
    end
    return ok == true, stdout or "", stderr or ""
end

local function path_is_executable(path)
    if not path or path == "" then
        return false
    end
    -- Prefer absolute probe so GUI PATH gaps don't matter.
    local ok = M.run_cmd({ "test", "-x", path })
    return ok
end

--- Resolve a CLI tool for WezTerm's GUI process (often a tiny PATH).
--- opts.candidates: absolute paths to try first
--- opts.login_shell: also ask zsh/bash -lc 'command -v name' (default true)
function M.resolve_executable(name, opts)
    opts = opts or {}
    if not name or name == "" then
        return nil
    end
    -- Already absolute / explicit
    if name:sub(1, 1) == "/" or (WIN and name:match("^[A-Za-z]:[\\/]")) then
        if path_is_executable(name) then
            return name
        end
        return nil
    end

    for _, cand in ipairs(opts.candidates or {}) do
        if path_is_executable(cand) then
            return cand
        end
    end

    -- Current GUI PATH (may work if WezTerm was started from a shell)
    local ok, stdout = M.run_cmd({ "sh", "-c", "command -v " .. name })
    if ok then
        local p = trim(stdout)
        if p ~= "" and path_is_executable(p) then
            return p
        end
    end

    if opts.login_shell ~= false then
        for _, shell in ipairs({ "/bin/zsh", "/bin/bash" }) do
            if path_is_executable(shell) then
                local lok, lout = M.run_cmd({ shell, "-lc", "command -v " .. name })
                if lok then
                    local p = trim(lout)
                    if p ~= "" and path_is_executable(p) then
                        return p
                    end
                end
            end
        end
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Install identity (semantic version from package.json, else short git sha)
-- ---------------------------------------------------------------------------

local install = {
    plugin_dir = nil,
    repo_dir = nil,
    label = nil,
}

function M.set_install_dirs(plugin_dir, repo_dir)
    install.plugin_dir = plugin_dir
    install.repo_dir = repo_dir
    install.label = nil
end

function M.plugin_dir()
    return install.plugin_dir
end

function M.repo_dir()
    return install.repo_dir
end

local function read_package_semver(repo_dir)
    if not repo_dir or repo_dir == "" then
        return nil
    end
    local path = repo_dir .. SEP .. "package.json"
    local ok, content = M.read_text_file(path, 65536)
    if not ok or type(content) ~= "string" then
        return nil
    end
    local pok, data = pcall(wezterm.json_parse, content)
    if not pok or type(data) ~= "table" then
        return nil
    end
    local v = data.version
    if type(v) == "string" and v:match("^%d+%.%d+") then
        return v
    end
    return nil
end

local function read_git_sha_from_head_file(repo_dir)
    local head_path = repo_dir .. SEP .. ".git" .. SEP .. "HEAD"
    local ok, head = M.read_text_file(head_path, 4096)
    if not ok or type(head) ~= "string" then
        return nil
    end
    head = trim(head)
    local sha = head:match("^(%x+)$")
    if sha and #sha >= 7 then
        return sha:sub(1, 7)
    end
    local ref = head:match("^ref:%s*(.+)$")
    if not ref then
        return nil
    end
    ref = trim(ref)
    local ref_path = repo_dir .. SEP .. ".git" .. SEP .. ref:gsub("/", SEP)
    local rok, ref_body = M.read_text_file(ref_path, 4096)
    if rok and type(ref_body) == "string" then
        local ref_sha = trim(ref_body):match("^(%x+)")
        if ref_sha and #ref_sha >= 7 then
            return ref_sha:sub(1, 7)
        end
    end
    -- Packed refs fallback
    local pok, packed = M.read_text_file(repo_dir .. SEP .. ".git" .. SEP .. "packed-refs", 1024 * 1024)
    if not pok or type(packed) ~= "string" then
        return nil
    end
    for line in (packed .. "\n"):gmatch("(.-)\n") do
        if not line:match("^#") and not line:match("^%^") then
            local psha, pref = line:match("^(%x+)%s+(.+)$")
            if psha and trim(pref or "") == ref and #psha >= 7 then
                return psha:sub(1, 7)
            end
        end
    end
    return nil
end

local function read_git_sha(repo_dir)
    if not repo_dir or repo_dir == "" then
        return nil
    end
    local ok, stdout = M.run_cmd({ "git", "-C", repo_dir, "rev-parse", "--short=7", "HEAD" })
    if ok then
        local sha = trim(stdout or "")
        if sha:match("^%x+$") and #sha >= 7 then
            return sha:sub(1, 7)
        end
    end
    return read_git_sha_from_head_file(repo_dir)
end

--- Resolve install label: prefer package.json semver; include short sha when available
--- so `update_all` pulls on main are visible between releases.
--- Examples: `v1.7.0+fc6d5b5`, `v1.7.0`, `fc6d5b5`, or `?`.
function M.version_label()
    if install.label then
        return install.label
    end
    local semver = read_package_semver(install.repo_dir)
    local sha = read_git_sha(install.repo_dir)
    local label
    if semver and sha then
        label = "v" .. semver .. "+" .. sha
    elseif semver then
        label = "v" .. semver
    elseif sha then
        label = sha
    else
        label = "?"
    end
    install.label = label
    return label
end

--- Brand string with version, e.g. `wezai v1.7.0+fc6d5b5`.
function M.brand_with_version()
    return "wezai " .. M.version_label()
end

return M
