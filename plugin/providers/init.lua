-- wezai backend registry.
-- Config `type` values stay stable for users; module names/API are wezai-specific.
local wezterm = require("wezterm")
local stats = require("stats")

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

local function finalize_meta(cfg, user_text, text, meta)
    meta = type(meta) == "table" and meta or {}
    meta.model = meta.model or (cfg and cfg.model) or "unknown"
    local prompt = tonumber(meta.prompt_tokens)
    local completion = tonumber(meta.completion_tokens)
    if not prompt or not completion then
        local sys = (cfg and cfg.system_prompt) or ""
        meta.prompt_tokens = prompt or stats.estimate_tokens(sys .. "\n" .. (user_text or ""))
        meta.completion_tokens = completion or stats.estimate_tokens(text or "")
        meta.estimated = true
    else
        meta.prompt_tokens = prompt
        meta.completion_tokens = completion
        if meta.estimated == nil then
            meta.estimated = false
        end
    end
    return meta
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

--- @return boolean ok, string|nil text, string|nil err, table|nil meta
function M.ask(cfg, user_text)
    local backend, err = load_backend(cfg and cfg.type or "http")
    if not backend then
        return false, nil, err, nil
    end
    local ok, text, ask_err, meta = backend.ask(cfg, user_text)
    if not ok then
        return false, nil, ask_err, nil
    end
    return true, text, nil, finalize_meta(cfg, user_text, text, meta)
end

return M
