-- Persistent usage metrics for wezai (~/.local/share/wezai/stats.json).
local wezterm = require("wezterm")
local util = require("util")

local M = {}

local VERSION = 1

local function data_dir()
    local xdg = os.getenv("XDG_DATA_HOME")
    if type(xdg) == "string" and xdg ~= "" then
        return xdg .. util.separator .. "wezai"
    end
    if util.is_windows then
        local localapp = os.getenv("LOCALAPPDATA")
        if type(localapp) == "string" and localapp ~= "" then
            return localapp .. util.separator .. "wezai"
        end
    end
    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "."
    return home .. util.separator .. ".local" .. util.separator .. "share" .. util.separator .. "wezai"
end

function M.db_path(config)
    local override = config and config.stats and config.stats.path
    if type(override) == "string" and override ~= "" then
        return override
    end
    return data_dir() .. util.separator .. "stats.json"
end

local function empty_db()
    return {
        version = VERSION,
        totals = {
            requests = 0,
            prompt_tokens = 0,
            completion_tokens = 0,
        },
        by_model = {},
        last = nil,
    }
end

local function ensure_dir(path)
    local dir = path:match("^(.*)[/\\][^/\\]+$")
    if not dir or dir == "" then
        return
    end
    if util.path_exists_as_dir(dir) then
        return
    end
    if util.is_windows then
        wezterm.run_child_process({ "cmd", "/c", "mkdir", dir })
    else
        wezterm.run_child_process({ "mkdir", "-p", dir })
    end
end

function M.load(config)
    local path = M.db_path(config)
    local ok, raw = util.read_text_file(path, 2 * 1024 * 1024)
    if not ok or not raw or raw == "" then
        return empty_db()
    end
    local parsed_ok, data = pcall(wezterm.json_parse, raw)
    if not parsed_ok or type(data) ~= "table" then
        return empty_db()
    end
    if type(data.totals) ~= "table" then
        data.totals = empty_db().totals
    end
    if type(data.by_model) ~= "table" then
        data.by_model = {}
    end
    data.version = VERSION
    return data
end

function M.save(config, db)
    local path = M.db_path(config)
    ensure_dir(path)
    local ok, err = util.write_text_file(path, wezterm.json_encode(db) .. "\n")
    if not ok then
        wezterm.log_warn("wezai: could not write stats: " .. tostring(err))
    end
    return ok
end

--- Rough token estimate when the provider does not report usage (~4 chars/token).
function M.estimate_tokens(text)
    if type(text) ~= "string" or text == "" then
        return 0
    end
    return math.max(1, math.floor(#text / 4))
end

local function fmt_n(n)
    n = tonumber(n) or 0
    if n >= 1000000 then
        return string.format("%.1fM", n / 1000000)
    end
    if n >= 1000 then
        return string.format("%.1fk", n / 1000)
    end
    return tostring(math.floor(n))
end

function M.format_compact(db)
    db = db or empty_db()
    local t = db.totals or {}
    local lines = {
        "usage  req "
            .. tostring(t.requests or 0)
            .. "  ↑"
            .. fmt_n(t.prompt_tokens)
            .. "  ↓"
            .. fmt_n(t.completion_tokens),
    }
    local last = db.last
    if type(last) == "table" and last.model then
        local est = last.estimated and "~" or ""
        lines[#lines + 1] = "last   "
            .. tostring(last.model)
            .. "  ↑"
            .. est
            .. fmt_n(last.prompt_tokens)
            .. "  ↓"
            .. est
            .. fmt_n(last.completion_tokens)
    end
    return table.concat(lines, "\n")
end

function M.format_turn(meta, db)
    meta = meta or {}
    local est = meta.estimated and "~" or ""
    local turn = "tokens  ↑"
        .. est
        .. fmt_n(meta.prompt_tokens)
        .. "  ↓"
        .. est
        .. fmt_n(meta.completion_tokens)
        .. "  ·  "
        .. tostring(meta.model or "?")
    local t = db and db.totals
    if t then
        turn = turn
            .. "  ·  total ↑"
            .. fmt_n(t.prompt_tokens)
            .. " ↓"
            .. fmt_n(t.completion_tokens)
    end
    return turn
end

--- Record one completed request. meta: model, prompt_tokens, completion_tokens, estimated?
function M.record(config, meta)
    if config and config.stats and config.stats.enabled == false then
        return M.load(config)
    end
    meta = meta or {}
    local db = M.load(config)
    local prompt = tonumber(meta.prompt_tokens) or 0
    local completion = tonumber(meta.completion_tokens) or 0
    local model = tostring(meta.model or "unknown")

    db.totals.requests = (db.totals.requests or 0) + 1
    db.totals.prompt_tokens = (db.totals.prompt_tokens or 0) + prompt
    db.totals.completion_tokens = (db.totals.completion_tokens or 0) + completion

    local row = db.by_model[model]
    if type(row) ~= "table" then
        row = { requests = 0, prompt_tokens = 0, completion_tokens = 0 }
        db.by_model[model] = row
    end
    row.requests = (row.requests or 0) + 1
    row.prompt_tokens = (row.prompt_tokens or 0) + prompt
    row.completion_tokens = (row.completion_tokens or 0) + completion

    db.last = {
        model = model,
        prompt_tokens = prompt,
        completion_tokens = completion,
        estimated = meta.estimated == true,
        at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }

    M.save(config, db)
    return db
end

return M
