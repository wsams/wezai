-- Default + user settings for wezai.
-- Merge order: BASE defaults < wezai.env file < process env < apply_to_config table.
local M = {}

local SEP = package.config:sub(1, 1)
local WIN = SEP == "\\"

local REPLY_CONTRACT =
    ' Output a single JSON object with "message" (string) and "command" (string|null). Nothing else.'

M.REPLY_CONTRACT = REPLY_CONTRACT

local BASE = {
    -- Copy-paste defaults: local Ollama over OpenAI-compatible HTTP. Override via
    -- ~/.config/wezterm/wezai.env or apply_to_config (see README).
    model = "llama3.2",
    models = {},
    type = "http",
    api_url = "http://127.0.0.1:11434/v1/chat/completions",
    api_key = nil,
    -- Ask prompt. CTRL+I matches the README / Linux default; set SUPER on macOS
    -- in wezterm.lua if you prefer Cmd+I.
    keybinding = { key = "i", mods = "CTRL" },
    keybinding_with_pane = { key = "e", mods = "CTRL|SHIFT" },
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
    -- APIs usually answer faster; 300s is the copy-paste local default.
    timeout = 300,
    -- Scroll timed status lines in the AI pane while Ask/Edit waits on the model.
    show_loading = true,
    -- Soft budget for @attach (oversized files send head+tail by default).
    -- #edit still requires the full file under this limit.
    max_file_bytes = 200000,
    -- # edit / wezai backups. Prefer nested `backup.*`; flat backup_suffix
    -- is still accepted for older configs and mirrored after finalize.
    backup = {
        enabled = true,
        suffix = ".wezai.bak",
        -- Sibling dotfile `.name.<timestamp>.wezai.bak` (easy to find: *wezai*.bak)
        dotfile = true,
        -- nil → write next to the target file; or e.g. "~/.local/share/wezai/bak"
        dir = nil,
    },
    backup_suffix = ".wezai.bak",
    ai_pane = { enabled = true, direction = "Right", size_percent = 35, pad_cols = 2 },
    -- Ask composer (CTRL+I): split of the shell pane so the AI log stays visible.
    composer = {
        enabled = true,
        size_percent = 32,
    },
    -- Token budget for @dir walks and large attaches.
    context = {
        max_prompt_tokens = 24000,
        warn_tokens = 6000,
        confirm_tokens = 12000,
        chars_per_token = 4,
        max_dir_files = 80,
        max_dir_bytes = 800000,
        compact_chars = 4000,
    },
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
    chat_max_turns = 40,
    chat_keep_turns = 2,
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
    composer = true,
    context = true,
}

-- Process / file keys wezai understands. Unknown KEY=VALUE lines are ignored.
local ENV_SPEC = {
    { env = "WEZAI_TYPE", key = "type" },
    { env = "WEZAI_API_URL", key = "api_url" },
    { env = "WEZAI_API_KEY", key = "api_key" },
    { env = "WEZAI_MODEL", key = "model" },
    { env = "WEZAI_MODELS", key = "models", kind = "csv" },
    { env = "WEZAI_TIMEOUT", key = "timeout", kind = "number" },
    { env = "WEZAI_OLLAMA_PATH", key = "ollama_path" },
    { env = "WEZAI_LMS_PATH", key = "lms_path" },
    { env = "WEZAI_KUBE_NS", nested = "kube", key = "namespace" },
    { env = "WEZAI_KUBE_KUBECTL", nested = "kube", key = "kubectl" },
    { env = "WEZAI_WEATHER_ZIP", nested = "weather", key = "zip" },
    { env = "WEZAI_WEATHER_COUNTRY", nested = "weather", key = "country" },
    { env = "WEZAI_WEATHER_UNITS", nested = "weather", key = "units" },
}

local function deep_copy_table(t)
    local out = {}
    for k, v in pairs(t) do
        out[k] = v
    end
    return out
end

local function trim(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function nonempty(s)
    return type(s) == "string" and trim(s) ~= ""
end

local function unquote(s)
    s = trim(s)
    local q = s:sub(1, 1)
    if (q == '"' or q == "'") and s:sub(-1) == q then
        return s:sub(2, -2)
    end
    return s
end

local function split_csv(s)
    local out = {}
    for part in (s .. ","):gmatch("([^,]*),") do
        local item = trim(part)
        if item ~= "" then
            out[#out + 1] = item
        end
    end
    return out
end

--- Parse KEY=VALUE text (comments, `export`, quotes). Returns a string map.
function M.parse_env_text(text)
    local map = {}
    if type(text) ~= "string" or text == "" then
        return map
    end
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local raw = trim(line)
        if raw ~= "" and not raw:match("^#") then
            raw = raw:gsub("^export%s+", "")
            local key, val = raw:match("^([A-Za-z_][A-Za-z0-9_]*)%s*=%s*(.*)$")
            if key then
                map[key] = unquote(val)
            end
        end
    end
    return map
end

--- Paths we try for a wezai.env file (first existing wins).
function M.env_file_candidates()
    local paths = {}
    local function add(p)
        if nonempty(p) then
            paths[#paths + 1] = p
        end
    end
    add(os.getenv("WEZAI_ENV_FILE"))
    local xdg = os.getenv("XDG_CONFIG_HOME")
    if nonempty(xdg) then
        add(xdg .. SEP .. "wezterm" .. SEP .. "wezai.env")
    end
    local home = os.getenv("HOME") or os.getenv("USERPROFILE")
    if nonempty(home) then
        add(home .. SEP .. ".config" .. SEP .. "wezterm" .. SEP .. "wezai.env")
        add(home .. SEP .. ".local" .. SEP .. "share" .. SEP .. "wezai" .. SEP .. "wezai.env")
    end
    if WIN then
        local localapp = os.getenv("LOCALAPPDATA")
        if nonempty(localapp) then
            add(localapp .. SEP .. "wezai" .. SEP .. "wezai.env")
        end
    end
    return paths
end

local function read_file(path)
    if not nonempty(path) then
        return nil
    end
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

--- Load the first existing env file. Returns map, path (path may be nil).
function M.load_env_file(candidates)
    for _, path in ipairs(candidates or M.env_file_candidates()) do
        local content = read_file(path)
        if type(content) == "string" then
            return M.parse_env_text(content), path
        end
    end
    return {}, nil
end

local function process_env_map()
    local map = {}
    for _, spec in ipairs(ENV_SPEC) do
        local v = os.getenv(spec.env)
        if nonempty(v) then
            map[spec.env] = v
        end
    end
    local openai = os.getenv("OPENAI_API_KEY")
    if nonempty(openai) then
        map.OPENAI_API_KEY = openai
    end
    local gemini = os.getenv("GEMINI_API_KEY")
    if nonempty(gemini) then
        map.GEMINI_API_KEY = gemini
    end
    return map
end

--- Merge string maps; later keys win when non-empty.
function M.merge_env_maps(...)
    local out = {}
    for i = 1, select("#", ...) do
        local map = select(i, ...)
        if type(map) == "table" then
            for k, v in pairs(map) do
                if nonempty(v) then
                    out[k] = v
                end
            end
        end
    end
    return out
end

local function set_field(overlay, spec, raw)
    if not nonempty(raw) then
        return
    end
    local value = raw
    if spec.kind == "number" then
        value = tonumber(raw)
        if not value then
            return
        end
    elseif spec.kind == "csv" then
        value = split_csv(raw)
        if #value == 0 then
            return
        end
    end
    if spec.nested then
        overlay[spec.nested] = overlay[spec.nested] or {}
        overlay[spec.nested][spec.key] = value
    else
        overlay[spec.key] = value
    end
end

--- Map a KEY=VALUE table onto a wezai config overlay (not a full config).
function M.config_from_env_map(map)
    local overlay = {}
    if type(map) ~= "table" then
        return overlay
    end
    for _, spec in ipairs(ENV_SPEC) do
        set_field(overlay, spec, map[spec.env])
    end
    if not nonempty(overlay.api_key) then
        if overlay.type == "google" then
            overlay.api_key = nonempty(map.GEMINI_API_KEY) and map.GEMINI_API_KEY
                or (nonempty(map.OPENAI_API_KEY) and map.OPENAI_API_KEY or nil)
        else
            overlay.api_key = nonempty(map.OPENAI_API_KEY) and map.OPENAI_API_KEY
                or (nonempty(map.GEMINI_API_KEY) and map.GEMINI_API_KEY or nil)
        end
    end
    return overlay
end

local function apply_overlay(cfg, overlay)
    if type(overlay) ~= "table" then
        return
    end
    for k, v in pairs(overlay) do
        if NESTED[k] and type(v) == "table" and type(cfg[k]) == "table" then
            for nk, nv in pairs(v) do
                if nv ~= nil and nv ~= "" then
                    cfg[k][nk] = nv
                end
            end
        elseif v ~= nil and v ~= "" then
            cfg[k] = v
        end
    end
end

local function apply_user(cfg, user)
    if type(user) ~= "table" then
        return
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
    if user.backup == false then
        cfg.backup = deep_copy_table(BASE.backup)
        cfg.backup.enabled = false
    elseif type(cfg.backup) ~= "table" then
        cfg.backup = deep_copy_table(BASE.backup)
    end
    if user.backup_suffix ~= nil and (type(user.backup) ~= "table" or user.backup.suffix == nil) then
        cfg.backup.suffix = user.backup_suffix
    end
end

--- Merge user overrides onto wezai defaults.
--- opts (tests / advanced): skip_live_env, env_text, env_map, env_file_candidates
function M.finalize(user, opts)
    opts = opts or {}
    local cfg = {}
    for k, v in pairs(BASE) do
        if type(v) == "table" then
            cfg[k] = deep_copy_table(v)
        else
            cfg[k] = v
        end
    end

    local env_map = {}
    local env_path
    if not opts.skip_live_env then
        local file_map
        file_map, env_path = M.load_env_file(opts.env_file_candidates)
        env_map = M.merge_env_maps(file_map, process_env_map())
        cfg._env_file = env_path
    end
    if type(opts.env_text) == "string" then
        env_map = M.merge_env_maps(env_map, M.parse_env_text(opts.env_text))
    end
    if type(opts.env_map) == "table" then
        env_map = M.merge_env_maps(env_map, opts.env_map)
    end
    apply_overlay(cfg, M.config_from_env_map(env_map))
    apply_user(cfg, user)

    if type(cfg.backup) ~= "table" then
        cfg.backup = deep_copy_table(BASE.backup)
    end
    if cfg.backup.suffix == nil or cfg.backup.suffix == "" then
        cfg.backup.suffix = ".wezai.bak"
    end
    if cfg.backup.enabled == nil then
        cfg.backup.enabled = true
    end
    if cfg.backup.dotfile == nil then
        cfg.backup.dotfile = true
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
