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
    local f, err = io.open(path, "rb")
    if not f then
        return false, "cannot read file: " .. (err or path)
    end
    local size = f:seek("end")
    if not size then
        f:close()
        return false, "cannot determine size: " .. path
    end
    if max_bytes and size > max_bytes then
        f:close()
        return false, string.format("file too large (%d bytes, max %d): %s", size, max_bytes, path)
    end
    f:seek("set")
    local content = f:read("*a")
    f:close()
    if content == nil then
        return false, "failed to read: " .. path
    end
    if content:find("\0", 1, true) then
        return false, "binary file not supported: " .. path
    end
    return true, content
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

function M.run_cmd(args)
    local ok, stdout, stderr = wezterm.run_child_process(args)
    return ok == true, stdout or "", stderr or ""
end

return M
