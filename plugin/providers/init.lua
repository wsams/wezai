-- wezai backend registry.
-- Config `type` values stay stable for users; module names/API are wezai-specific.
local wezterm = require("wezterm")

local ALIAS = {
    http = "providers.chat_http",
    google = "providers.gemini_api",
    ollama = "providers.ollama_bin",
    ["local"] = "providers.lms_bin",
}

local cache = {}

local function load_backend(kind)
    local mod = ALIAS[kind]
    if not mod then
        return nil, "unknown type " .. tostring(kind)
    end
    if cache[mod] then
        return cache[mod]
    end
    local ok, backend = pcall(require, mod)
    if not ok then
        return nil, tostring(backend)
    end
    cache[mod] = backend
    return backend
end

local M = {}

function M.ready(cfg)
    local backend, err = load_backend(cfg and cfg.type or "http")
    if not backend then
        wezterm.log_error("wezai: " .. tostring(err))
        return false
    end
    return backend.ready(cfg) == true
end

--- @return boolean ok, string|nil text, string|nil err
function M.ask(cfg, user_text)
    local backend, err = load_backend(cfg and cfg.type or "http")
    if not backend then
        return false, nil, err
    end
    return backend.ask(cfg, user_text)
end

return M
