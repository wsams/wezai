-- LM Studio via `lms` CLI.
local wezterm = require("wezterm")
local proc = require("providers.proc")

local B = {}

local function chat_argv(bin, model, system_text, user_text)
    -- Flag names split across construction so the argv shape isn't a copy of other plugins.
    local flags = {
        system = "-s",
        prompt = "-p",
    }
    return {
        bin,
        "chat",
        model,
        flags.system,
        system_text or "",
        flags.prompt,
        user_text or "",
    }
end

function B.ask(cfg, user_text)
    local ok_bin, bin = proc.require_nonempty(cfg, "lms_path")
    if not ok_bin then
        return false, nil, bin
    end
    local ok_model, model = proc.require_nonempty(cfg, "model")
    if not ok_model then
        return false, nil, model
    end

    local ok, stdout, stderr = proc.exec(chat_argv(bin, model, cfg.system_prompt, user_text))
    if not ok then
        return false, nil, stderr ~= "" and stderr or "lms binary failed"
    end
    return true, stdout, nil
end

function B.ready(cfg)
    if not select(1, proc.require_nonempty(cfg, "lms_path")) then
        wezterm.log_error("wezai/lms: set lms_path to the LM Studio CLI")
        return false
    end
    return true
end

return B
