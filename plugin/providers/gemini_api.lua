-- Gemini generateContent transport for wezai.
local wezterm = require("wezterm")
local proc = require("providers.proc")

local B = {}

local HOST = "https://generativelanguage.googleapis.com/v1beta/models"

-- Build structured-output schema from a field list (avoids a static schema blob).
local function json_object_schema(fields, required)
    local properties = {}
    for _, name in ipairs(fields) do
        properties[name] = { type = "STRING" }
    end
    return {
        type = "OBJECT",
        properties = properties,
        required = required,
    }
end

-- Ask: message + optional command. Edit also needs file / files or Gemini
-- will refuse those keys (responseSchema is a closed allow-list).
local ASK_SCHEMA = json_object_schema({ "message", "command" }, { "message" })

local FILE_ITEM_SCHEMA = {
    type = "OBJECT",
    properties = {
        path = { type = "STRING" },
        file = { type = "STRING" },
        content = { type = "STRING" },
        new_content = { type = "STRING" },
    },
}

local EDIT_SCHEMA = {
    type = "OBJECT",
    properties = {
        message = { type = "STRING" },
        command = { type = "STRING" },
        file = { type = "STRING" },
        content = { type = "STRING" },
        new_content = { type = "STRING" },
        files = { type = "ARRAY", items = FILE_ITEM_SCHEMA },
    },
    required = { "message" },
}

local function is_edit_prompt(sys)
    return type(sys) == "string" and sys:find("You create or rewrite one or more files", 1, true) ~= nil
end

local function endpoint(model, key)
    return string.format("%s/%s:generateContent?key=%s", HOST, model, key)
end

local function request_body(cfg, user_text)
    local sys = cfg.system_instruction or cfg.system_prompt
    local body = {
        contents = {
            {
                role = "user",
                parts = { { text = user_text or "" } },
            },
        },
        generationConfig = {
            responseMimeType = "application/json",
            responseSchema = is_edit_prompt(sys) and EDIT_SCHEMA or ASK_SCHEMA,
        },
    }
    if type(sys) == "string" and sys ~= "" then
        body.systemInstruction = { parts = { { text = sys } } }
    end
    return body
end

local function first_text(payload)
    local parts = ((((payload or {}).candidates or {})[1] or {}).content or {}).parts
    if type(parts) ~= "table" then
        return nil
    end
    for i = 1, #parts do
        local t = parts[i].text
        if type(t) == "string" and t ~= "" then
            return t
        end
    end
    return nil
end

function B.ask(cfg, user_text)
    local ok_key, key = proc.require_nonempty(cfg, "api_key")
    if not ok_key then
        return false, nil, key
    end
    local ok_model, model = proc.require_nonempty(cfg, "model")
    if not ok_model then
        return false, nil, model
    end

    local ok, stdout, stderr = proc.post_json(endpoint(model, key), request_body(cfg, user_text), nil, cfg.timeout or 60)
    if not ok then
        return false, nil, stderr ~= "" and stderr or "gemini call failed"
    end
    if stdout == "" then
        return false, nil, "gemini returned no body"
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
        return false, nil, "gemini: " .. tostring(detail)
    end

    local text = first_text(data)
    if not text then
        wezterm.log_error("wezai/gemini: unexpected body " .. stdout:sub(1, 400))
        return false, nil, "gemini missing text part"
    end
    local um = data.usageMetadata or {}
    local meta = {
        model = model,
        prompt_tokens = tonumber(um.promptTokenCount),
        completion_tokens = tonumber(um.candidatesTokenCount),
    }
    return true, text, nil, meta
end

function B.ready(cfg)
    if not select(1, proc.require_nonempty(cfg, "api_key")) then
        wezterm.log_error("wezai/gemini: api_key required")
        return false
    end
    if not select(1, proc.require_nonempty(cfg, "model")) then
        wezterm.log_error("wezai/gemini: model required")
        return false
    end
    return true
end

return B
