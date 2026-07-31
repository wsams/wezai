-- Child-process helpers for wezai backends.
local wezterm = require("wezterm")

local P = {}

function P.exec(argv)
    local status, out, err = wezterm.run_child_process(argv)
    return status == true, out or "", err or ""
end

function P.post_json(url, body, extra_headers, seconds)
    local encoded = wezterm.json_encode(body)
    local argv = { "curl", "-sS", "-X", "POST", "--max-time", tostring(seconds or 60) }
    table.insert(argv, "-H")
    table.insert(argv, "Content-Type: application/json")
    if type(extra_headers) == "table" then
        for _, line in ipairs(extra_headers) do
            table.insert(argv, "-H")
            table.insert(argv, line)
        end
    end
    table.insert(argv, url)
    table.insert(argv, "-d")
    table.insert(argv, encoded)
    return P.exec(argv)
end

function P.parse_json(raw)
    local ok, data = pcall(wezterm.json_parse, raw or "")
    if not ok or type(data) ~= "table" then
        return nil, "unreadable JSON: " .. tostring(raw):sub(1, 400)
    end
    return data
end

function P.require_nonempty(cfg, field)
    local v = cfg and cfg[field]
    if type(v) ~= "string" or v == "" then
        return false, field .. " missing"
    end
    return true, v
end

return P
