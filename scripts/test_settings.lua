-- Tests for settings env overlay. Run: lua scripts/test_settings.lua
package.path = "./plugin/?.lua;./plugin/?/init.lua;" .. package.path

local settings = require("settings")

local failed = 0
local passed = 0

local function expect(cond, msg)
    if cond then
        passed = passed + 1
        return
    end
    failed = failed + 1
    io.stderr:write("FAIL: " .. msg .. "\n")
end

local function eq(a, b, msg)
    expect(a == b, (msg or "eq") .. " got " .. tostring(a) .. " expected " .. tostring(b))
end

-- parse_env_text
local parsed = settings.parse_env_text([[
# comment
export WEZAI_MODEL=llama3.2
WEZAI_TIMEOUT = 300
WEZAI_API_KEY="sk-test"
WEZAI_WEATHER_ZIP='90210'
not a line
=novalue
]])
eq(parsed.WEZAI_MODEL, "llama3.2", "model")
eq(parsed.WEZAI_TIMEOUT, "300", "timeout")
eq(parsed.WEZAI_API_KEY, "sk-test", "quoted key")
eq(parsed.WEZAI_WEATHER_ZIP, "90210", "single quotes")
expect(parsed["not"] == nil, "invalid line ignored")

-- config_from_env_map
local overlay = settings.config_from_env_map({
    WEZAI_TYPE = "http",
    WEZAI_MODEL = "qwen2.5:14b",
    WEZAI_MODELS = "a, b,c",
    WEZAI_TIMEOUT = "450",
    WEZAI_WEATHER_ZIP = "02139",
    WEZAI_WEATHER_COUNTRY = "US",
    WEZAI_KUBE_NS = "kube-system",
    OPENAI_API_KEY = "from-openai",
})
eq(overlay.type, "http", "type")
eq(overlay.model, "qwen2.5:14b", "overlay model")
eq(overlay.timeout, 450, "timeout number")
eq(overlay.api_key, "from-openai", "openai fallback")
eq(overlay.weather.zip, "02139", "weather zip")
eq(overlay.kube.namespace, "kube-system", "kube ns")
eq(#overlay.models, 3, "models csv count")
eq(overlay.models[2], "b", "models csv trim")

local gemini = settings.config_from_env_map({
    WEZAI_TYPE = "google",
    GEMINI_API_KEY = "gemi",
    OPENAI_API_KEY = "oai",
})
eq(gemini.api_key, "gemi", "google prefers GEMINI_API_KEY")

local wezai_wins = settings.config_from_env_map({
    WEZAI_API_KEY = "explicit",
    OPENAI_API_KEY = "oai",
})
eq(wezai_wins.api_key, "explicit", "WEZAI_API_KEY beats OPENAI")

-- merge order: BASE < env < user
local cfg = settings.finalize({
    model = "from-lua",
    weather = { zip = "99999" },
}, {
    skip_live_env = true,
    env_text = "WEZAI_MODEL=from-env\nWEZAI_WEATHER_ZIP=11111\nWEZAI_TIMEOUT=60\n",
})
eq(cfg.model, "from-lua", "lua table wins model")
eq(cfg.weather.zip, "99999", "lua table wins weather.zip")
eq(cfg.timeout, 60, "env timeout when lua omitted")
eq(cfg.api_url, "http://127.0.0.1:11434/v1/chat/completions", "ollama default url")
eq(cfg.type, "http", "default type")
eq(cfg.keybinding.mods, "CTRL", "CTRL+I default")
eq(cfg.keybinding_with_pane.key, "e", "CTRL+SHIFT+E default")

local base = settings.finalize(nil, { skip_live_env = true })
eq(base.model, "llama3.2", "default model")
eq(base.timeout, 300, "default timeout")
eq(base.weather.country, "US", "default weather country")

-- process-like map wins over file text when passed as env_map after env_text
local stacked = settings.finalize(nil, {
    skip_live_env = true,
    env_text = "WEZAI_MODEL=file-model\n",
    env_map = { WEZAI_MODEL = "proc-model" },
})
eq(stacked.model, "proc-model", "later env_map wins")

-- merge_env_maps
local merged = settings.merge_env_maps(
    { WEZAI_MODEL = "a", WEZAI_TIMEOUT = "1" },
    { WEZAI_MODEL = "b", WEZAI_TIMEOUT = "" }
)
eq(merged.WEZAI_MODEL, "b", "merge later")
eq(merged.WEZAI_TIMEOUT, "1", "empty does not clobber")

local ver = dofile("plugin/version.lua")
expect(type(ver) == "table" and type(ver.version) == "string", "version.lua table")
expect(ver.version:match("^%d+%.%d+") ~= nil, "version.lua semver")

if failed > 0 then
    io.stderr:write(string.format("%d failed, %d passed\n", failed, passed))
    os.exit(1)
end
print(string.format("ok — %d passed", passed))
