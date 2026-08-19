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
    keybinding_kube = { key = "k", mods = "CTRL|SHIFT" },
    -- CTRL|SHIFT+T is WezTerm's SpawnTab — use CTRL|ALT+T for @tf instead.
    keybinding_tf = { key = "t", mods = "CTRL|ALT" },
    -- CTRL|SHIFT+W is WezTerm's CloseCurrentTab — use CTRL|ALT+W for @weather.
    keybinding_weather = { key = "w", mods = "CTRL|ALT" },
    -- Shell dialect (fish/zsh/bash/…) is appended automatically per request.
    system_prompt = "You are a concise terminal assistant. Provide direct commands or brief explanations. "
        .. "Warn of dangerous commands. Avoid unnecessary verbosity. Prefer interactive commands that "
        .. "require user verification before proceeding when possible."
        .. REPLY_CONTRACT,
    -- curl --max-time. 30s is too short for cold-loading large local models
    -- (Ollama aborts the load if the client disconnects mid-warmup). Cloud
    -- APIs usually answer faster; raise further for big local GGUFs.
    timeout = 120,
    -- Scroll timed status lines in the AI pane while Ask/Edit waits on the model.
    show_loading = true,
    type = "http",
    api_key = nil,
    -- Soft budget for @attach (oversized files send head+tail by default).
    -- @@edit still requires the full file under this limit.
    max_file_bytes = 200000,
    -- @@ edit / .gitignore backups. Prefer nested `backup.*`; flat backup_suffix
    -- is still accepted for older configs and mirrored after finalize.
    backup = {
        enabled = true,
        suffix = ".wezai.bak",
        -- nil → write next to the target file; or e.g. "~/.local/share/wezai/bak"
        dir = nil,
    },
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
    kube = {
        namespace = nil, -- nil → kubectl current context namespace
        kubectl = nil, -- absolute path; nil → auto-resolve (GUI PATH is often incomplete)
        confirm_mutate = true,
        max_attach_bytes = 80000,
    },
    tf = {
        terraform = nil, -- absolute path; nil → auto-resolve (GUI PATH is often incomplete)
        confirm_mutate = true,
        max_attach_bytes = 80000,
    },
    weather = {
        zip = nil, -- e.g. "90210"; plugin @weather:zip overrides via ~/.local/share/wezai/weather.json
        country = "US", -- ISO 3166-1 alpha-2 for geocoding
        units = "auto", -- "auto" (US → imperial) | "imperial" | "metric"
        path = nil, -- overlay JSON; nil → ~/.local/share/wezai/weather.json
    },
    chat_max_turns = 6,
    require_edit_confirm = true,
    require_risk_confirm = true,
    -- Usage DB: ~/.local/share/wezai/stats.json (override with stats.path)
    stats = { enabled = true, path = nil },
    -- Fuzzy @pick + large-file attach policy
    files = {
        max_candidates = 400,
        large_file = "head_tail", -- "head_tail" | "head" | "error"
        head_bytes = nil, -- default: ~60% of max_file_bytes
        tail_bytes = nil, -- default: remainder
    },
}

local NESTED = {
    ai_pane = true,
    history = true,
    git = true,
    kube = true,
    tf = true,
    weather = true,
    stats = true,
    files = true,
    backup = true,
}

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
    -- Allow backup = false as a shorthand for disabled.
    if user.backup == false then
        cfg.backup = deep_copy_table(BASE.backup)
        cfg.backup.enabled = false
    elseif type(cfg.backup) ~= "table" then
        cfg.backup = deep_copy_table(BASE.backup)
    end
    -- Legacy flat backup_suffix → backup.suffix when nested suffix was not set.
    if user.backup_suffix ~= nil and (type(user.backup) ~= "table" or user.backup.suffix == nil) then
        cfg.backup.suffix = user.backup_suffix
    end
    if cfg.backup.suffix == nil or cfg.backup.suffix == "" then
        cfg.backup.suffix = ".wezai.bak"
    end
    if cfg.backup.enabled == nil then
        cfg.backup.enabled = true
    end
    -- Keep flat key in sync for any callers still reading backup_suffix.
    cfg.backup_suffix = cfg.backup.suffix
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
