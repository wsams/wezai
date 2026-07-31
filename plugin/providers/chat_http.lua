-- OpenAI-style chat/completions transport.
local wezterm = require("wezterm")
local proc = require("providers.proc")

local B = {}

local function messages(cfg, user_text)
    return {
        { role = "system", content = cfg.system_prompt or "" },
        { role = "user", content = user_text or "" },
    }
end

local function header_lines(cfg)
    local lines = {}
    if type(cfg.api_key) == "string" and cfg.api_key ~= "" then
        lines[#lines + 1] = "Authorization: Bearer " .. cfg.api_key
    end
    if type(cfg.headers) == "table" then
        for name, value in pairs(cfg.headers) do
            lines[#lines + 1] = tostring(name) .. ": " .. tostring(value)
        end
    end
    return lines
end

function B.ask(cfg, user_text)
    local ok_url, url = proc.require_nonempty(cfg, "api_url")
    if not ok_url then
        return false, nil, url
    end
    local ok_model = proc.require_nonempty(cfg, "model")
    if not ok_model then
        return false, nil, "model missing"
    end

    local ok, stdout, stderr = proc.post_json(
        url,
        { model = cfg.model, messages = messages(cfg, user_text) },
        header_lines(cfg),
        cfg.timeout or 60
    )
    if not ok then
        return false, nil, stderr ~= "" and stderr or "HTTP transport failed"
    end

    local data, perr = proc.parse_json(stdout)
    if not data then
        return false, nil, perr
    end
    if data.error then
        local detail = data.error
        if type(detail) == "table" then
            detail = detail.message or wezterm.json_encode(detail)
        end
        return false, nil, "upstream: " .. tostring(detail)
    end

    local text = (((data.choices or {})[1] or {}).message or {}).content
    if type(text) ~= "string" or text == "" then
        return false, nil, "no assistant content in response"
    end
    return true, text, nil
end

function B.ready(cfg)
    local a = proc.require_nonempty(cfg, "api_url")
    local b = proc.require_nonempty(cfg, "model")
    if not a then
        wezterm.log_error("wezai/chat_http: api_url required")
        return false
    end
    if not b then
        wezterm.log_error("wezai/chat_http: model required")
        return false
    end
    return true
end

return B
