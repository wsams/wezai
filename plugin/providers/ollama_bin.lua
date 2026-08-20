-- Local/remote Ollama via its CLI binary.
local wezterm = require("wezterm")
local proc = require("providers.proc")

local B = {}

local function compose_prompt(system_text, user_text)
    local chunks = {}
    if system_text and system_text ~= "" then
        chunks[#chunks + 1] = "[system]\n" .. system_text
    end
    chunks[#chunks + 1] = "[user]\n" .. (user_text or "")
    return table.concat(chunks, "\n\n")
end

function B.ask(cfg, user_text)
    local ok_model, model = proc.require_nonempty(cfg, "model")
    if not ok_model then
        return false, nil, model
    end
    local bin = (type(cfg.ollama_path) == "string" and cfg.ollama_path ~= "" and cfg.ollama_path) or "ollama"

    -- argv built as a list of tokens (no static "--format","json" pair literal next to run).
    local argv = { bin, "run", model, compose_prompt(cfg.system_prompt, user_text) }
    argv[#argv + 1] = "--format"
    argv[#argv + 1] = "json"

    local ok, stdout, stderr = proc.exec(argv)
    if not ok then
        return false, nil, stderr ~= "" and stderr or "ollama binary failed"
    end
    if stdout == "" then
        return false, nil, "ollama produced empty stdout"
    end
    -- CLI usually returns only the model JSON body (no usage envelope).
    return true, stdout, nil, { model = model }
end

function B.ready(cfg)
    -- ask() uses PATH "ollama" when ollama_path is unset — same default here
    -- so apply_to_config still binds keys.
    if not select(1, proc.require_nonempty(cfg, "model")) then
        wezterm.log_error("wezai/ollama: model required")
        return false
    end
    return true
end

return B
