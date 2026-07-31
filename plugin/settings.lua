-- Default + user settings for wezai.
local M = {}

local REPLY_CONTRACT =
    ' Output a single JSON object with "message" (string) and "command" (string|null). Nothing else.'

M.REPLY_CONTRACT = REPLY_CONTRACT

local BASE = {
    model = "gpt-4o-mini",
    models = {},
    keybinding = { key = "i", mods = "SUPER" },
    keybinding_with_pane = { key = "I", mods = "SUPER" },
    keybinding_palette = { key = "p", mods = "CTRL|SHIFT" },
    keybinding_history = { key = "h", mods = "CTRL|SHIFT" },
    keybinding_git = { key = "g", mods = "CTRL|SHIFT" },
    system_prompt = "You are wezai, a concise CLI helper for the user's shell. "
        .. "Prefer short answers. When a shell command helps, put a single copy-pasteable command "
        .. "in the command field (chain with && / || when useful). Otherwise set command to null."
        .. REPLY_CONTRACT,
    timeout = 30,
    show_loading = true,
    type = "http",
    api_key = nil,
    max_file_bytes = 100000,
    backup_suffix = ".wezai.bak",
    ai_pane = { enabled = true, direction = "Right", size_percent = 35, pad_cols = 2 },
    history = {
        max_shell = 500,
        max_session = 50,
        attach_n = 40,
        include_scrollback = true,
        palette_n = 200,
        tail_bytes = 4 * 1024 * 1024,
    },
    git = {
        default_branch = nil,
        confirm_push = true,
        max_attach_bytes = 80000,
    },
    chat_max_turns = 6,
    require_edit_confirm = true,
    require_risk_confirm = true,
}

local NESTED = { ai_pane = true, history = true, git = true }

local function deep_copy_table(t)
    local out = {}
    for k, v in pairs(t) do
        out[k] = v
    end
    return out
end

--- Merge user overrides onto wezai defaults.
function M.finalize(user)
    local cfg = {}
    for k, v in pairs(BASE) do
        if type(v) == "table" then
            cfg[k] = deep_copy_table(v)
        else
            cfg[k] = v
        end
    end
    if type(user) ~= "table" then
        return cfg
    end
    for k, v in pairs(user) do
        if NESTED[k] and type(v) == "table" and type(cfg[k]) == "table" then
            for nk, nv in pairs(v) do
                cfg[k][nk] = nv
            end
        else
            cfg[k] = v
        end
        if k == "system_prompt" and type(v) == "string" and not v:find('"message"', 1, true) then
            cfg.system_prompt = v .. REPLY_CONTRACT
        end
    end
    return cfg
end

--- Optional: if user sets rocks_bin, append that tool's LUA_PATH.
function M.maybe_extend_rocks_path(cfg)
    local bin = cfg and cfg.rocks_bin
    if type(bin) ~= "string" or bin == "" then
        return
    end
    local ok, pipe = pcall(io.popen, bin .. " path --bin 2>&1")
    if not ok or not pipe then
        return
    end
    local text = pipe:read("*a") or ""
    if not pipe:close() then
        return
    end
    local added = text:match("LUA_PATH=([^\n]+)")
    if added and added ~= "" then
        package.path = package.path .. ";" .. added
    end
end

return M
