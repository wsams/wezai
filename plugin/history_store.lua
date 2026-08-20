-- Pure Lua history store: parse fish/zsh/bash files, unique newest-first index,
-- fuzzy filter, and exact-command rewrite. No wezterm / subprocess.
-- Used by history.lua and scripts/test_history.lua.

local M = {}

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$") or ""
end

M.trim = trim

function M.unescape_fish_cmd(cmd)
    if not cmd then
        return ""
    end
    cmd = cmd:gsub("\\n", "\n")
    cmd = cmd:gsub("\\\\", "\\")
    return trim(cmd)
end

local function split_lines(text)
    local lines = {}
    if not text or text == "" then
        return lines
    end
    local n = 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
        n = n + 1
        lines[n] = line
    end
    -- Drop the extra empty from a trailing newline-only split at EOF
    if n > 0 and lines[n] == "" and text:sub(-1) == "\n" then
        lines[n] = nil
    end
    return lines
end

M.split_lines = split_lines

--- Newest-first unique, preserving first-seen (which is newest when walking reverse).
function M.unique_newest(cmds, max_n)
    local seen = {}
    local out = {}
    for i = 1, #(cmds or {}) do
        local cmd = cmds[i]
        if cmd and cmd ~= "" and not seen[cmd] then
            seen[cmd] = true
            out[#out + 1] = cmd
            if max_n and #out >= max_n then
                break
            end
        end
    end
    return out
end

--- Reverse an array (oldest-first ↔ newest-first).
function M.reverse(list)
    local n = #(list or {})
    local out = {}
    for i = n, 1, -1 do
        out[#out + 1] = list[i]
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Parsers — return command lists in file order (oldest first, duplicates kept).
-- ---------------------------------------------------------------------------

function M.parse_bash_commands(text)
    local cmds = {}
    for _, line in ipairs(split_lines(text)) do
        if not line:match("^#%d+$") then
            local cmd = trim(line)
            if cmd ~= "" and not cmd:match("^#") then
                cmds[#cmds + 1] = cmd
            end
        end
    end
    return cmds
end

--- Unique newest-first from bash lines without building the full duplicate list.
function M.unique_bash_newest(lines, max_n)
    local seen = {}
    local out = {}
    for i = #lines, 1, -1 do
        local line = lines[i]
        if not line:match("^#%d+$") then
            local cmd = trim(line)
            if cmd ~= "" and not cmd:match("^#") and not seen[cmd] then
                seen[cmd] = true
                out[#out + 1] = cmd
                if max_n and #out >= max_n then
                    break
                end
            end
        end
    end
    return out
end

local function zsh_cmd_from_line(line)
    return line:match("^: %d+:%d+;(.*)$") or line
end

function M.parse_zsh_commands(text)
    local cmds = {}
    local pending = nil
    for _, line in ipairs(split_lines(text)) do
        if pending then
            pending = pending .. line
            if pending:sub(-1) ~= "\\" then
                local cmd = trim(pending)
                if cmd ~= "" and not cmd:match("^#") then
                    cmds[#cmds + 1] = cmd
                end
                pending = nil
            else
                pending = pending:sub(1, -2)
            end
        else
            local cmd = zsh_cmd_from_line(line)
            if cmd:sub(-1) == "\\" then
                pending = cmd:sub(1, -2)
            else
                cmd = trim(cmd)
                if cmd ~= "" and not cmd:match("^#") then
                    cmds[#cmds + 1] = cmd
                end
            end
        end
    end
    if pending then
        local cmd = trim(pending)
        if cmd ~= "" then
            cmds[#cmds + 1] = cmd
        end
    end
    return cmds
end

function M.unique_zsh_newest(lines, max_n)
    -- Extended-history lines are one command each; walk from the end.
    -- Continuation lines (no `: ts:dur;` prefix following a backslash) are rare;
    -- fall back to a full parse when we see a trailing backslash.
    local need_full = false
    for i = 1, #lines do
        if lines[i]:sub(-1) == "\\" then
            need_full = true
            break
        end
    end
    if need_full then
        return M.unique_newest(M.reverse(M.parse_zsh_commands(table.concat(lines, "\n") .. "\n")), max_n)
    end
    local seen = {}
    local out = {}
    for i = #lines, 1, -1 do
        local cmd = trim(zsh_cmd_from_line(lines[i]))
        if cmd ~= "" and not cmd:match("^#") and not seen[cmd] then
            seen[cmd] = true
            out[#out + 1] = cmd
            if max_n and #out >= max_n then
                break
            end
        end
    end
    return out
end

function M.parse_fish_commands(text)
    local lines = split_lines(text)
    local cmds = {}
    local i = 1
    while i <= #lines do
        local cmd = lines[i]:match("^%- cmd:%s*(.*)$")
        if cmd ~= nil then
            while cmd:sub(-1) == "\\" and i < #lines do
                i = i + 1
                cmd = cmd:sub(1, -2) .. lines[i]
            end
            cmd = M.unescape_fish_cmd(cmd)
            if cmd ~= "" then
                cmds[#cmds + 1] = cmd
            end
        end
        i = i + 1
    end
    return cmds
end

function M.unique_fish_newest(lines, max_n)
    -- YAML-ish records must be parsed forward (continuation + when/paths).
    return M.unique_newest(M.reverse(M.parse_fish_commands(table.concat(lines, "\n") .. "\n")), max_n)
end

function M.unique_text(kind, text, max_n)
    local lines = split_lines(text)
    if kind == "zsh" then
        return M.unique_zsh_newest(lines, max_n)
    elseif kind == "fish" then
        return M.unique_fish_newest(lines, max_n)
    end
    return M.unique_bash_newest(lines, max_n)
end

-- ---------------------------------------------------------------------------
-- Exact delete (all copies). Returns new text, removed count.
-- ---------------------------------------------------------------------------

local function ends_with_nl(text)
    return text:sub(-1) == "\n"
end

function M.strip_bash_exact(text, cmd)
    cmd = cmd or ""
    local had_nl = ends_with_nl(text)
    local out = {}
    local removed = 0
    local pending_ts = nil
    for _, line in ipairs(split_lines(text)) do
        if line:match("^#%d+$") then
            if pending_ts then
                out[#out + 1] = pending_ts
            end
            pending_ts = line
        else
            if trim(line) == cmd then
                removed = removed + 1
                pending_ts = nil
            else
                if pending_ts then
                    out[#out + 1] = pending_ts
                    pending_ts = nil
                end
                out[#out + 1] = line
            end
        end
    end
    if pending_ts then
        out[#out + 1] = pending_ts
    end
    local body = table.concat(out, "\n")
    if had_nl and (body == "" or body:sub(-1) ~= "\n") then
        body = body .. "\n"
    end
    return body, removed
end

function M.strip_zsh_exact(text, cmd)
    cmd = cmd or ""
    local had_nl = ends_with_nl(text)
    local out = {}
    local removed = 0
    for _, line in ipairs(split_lines(text)) do
        local got = zsh_cmd_from_line(line)
        if trim(got) == cmd then
            removed = removed + 1
        else
            out[#out + 1] = line
        end
    end
    local body = table.concat(out, "\n")
    if had_nl and (body == "" or body:sub(-1) ~= "\n") then
        body = body .. "\n"
    end
    return body, removed
end

--- Remove fish YAML records whose unescaped cmd matches exactly.
function M.strip_fish_exact(text, cmd)
    cmd = cmd or ""
    local had_nl = ends_with_nl(text)
    local lines = split_lines(text)
    local out = {}
    local removed = 0
    local i = 1
    while i <= #lines do
        local raw = lines[i]:match("^%- cmd:%s*(.*)$")
        if raw == nil then
            out[#out + 1] = lines[i]
            i = i + 1
        else
            local assembled = raw
            local block = { lines[i] }
            local j = i
            while assembled:sub(-1) == "\\" and j < #lines do
                j = j + 1
                assembled = assembled:sub(1, -2) .. lines[j]
                block[#block + 1] = lines[j]
            end
            j = j + 1
            -- Swallow following indented metadata until the next record / EOF.
            while j <= #lines and not lines[j]:match("^%- cmd:") do
                -- A top-level key that isn't a cmd record shouldn't happen; keep
                -- swallowing indented / blank lines that belong to this item.
                if lines[j]:match("^%S") and not lines[j]:match("^%-") then
                    break
                end
                block[#block + 1] = lines[j]
                j = j + 1
            end
            if M.unescape_fish_cmd(assembled) == cmd then
                removed = removed + 1
            else
                for _, bl in ipairs(block) do
                    out[#out + 1] = bl
                end
            end
            i = j
        end
    end
    local body = table.concat(out, "\n")
    if had_nl and (body == "" or body:sub(-1) ~= "\n") then
        body = body .. "\n"
    end
    return body, removed
end

function M.strip_exact(kind, text, cmd)
    if kind == "zsh" then
        return M.strip_zsh_exact(text, cmd)
    elseif kind == "fish" then
        return M.strip_fish_exact(text, cmd)
    end
    return M.strip_bash_exact(text, cmd)
end

-- ---------------------------------------------------------------------------
-- Fuzzy matching (whitespace tokens AND; each token is a subsequence).
-- Tuned for tens of thousands of short command lines.
-- ---------------------------------------------------------------------------

local function lower_ascii(s)
    return (s or ""):lower()
end

--- Subsequence match; returns score (higher is better) or nil.
--- Consecutive runs and matches at start / after space / after [/_-.] score higher.
function M.subsequence_score(text, needle)
    if needle == "" then
        return 0
    end
    local t = lower_ascii(text)
    local n = lower_ascii(needle)
    local ti, ni = 1, 1
    local tlen, nlen = #t, #n
    local score = 0
    local consec = 0
    local prev = 0
    while ti <= tlen and ni <= nlen do
        if t:byte(ti) == n:byte(ni) then
            local bonus = 1
            if ti == 1 then
                bonus = bonus + 8
            else
                local pb = t:byte(ti - 1)
                -- space, tab, /, _, -, ., =, :
                if pb == 32 or pb == 9 or pb == 47 or pb == 95 or pb == 45 or pb == 46 or pb == 61 or pb == 58 then
                    bonus = bonus + 6
                end
            end
            if prev + 1 == ti then
                consec = consec + 1
                bonus = bonus + math.min(consec, 6)
            else
                consec = 0
            end
            score = score + bonus
            prev = ti
            ni = ni + 1
        end
        ti = ti + 1
    end
    if ni <= nlen then
        return nil
    end
    -- Prefer shorter commands (less leftover noise)
    score = score * 32 - math.min(#t, 400)
    return score
end

function M.tokens(query)
    local out = {}
    for tok in lower_ascii(query):gmatch("%S+") do
        out[#out + 1] = tok
    end
    return out
end

function M.query_score(text, query)
    local toks = M.tokens(query)
    if #toks == 0 then
        return 0
    end
    local total = 0
    for i = 1, #toks do
        local s = M.subsequence_score(text, toks[i])
        if not s then
            return nil
        end
        total = total + s
    end
    return total
end

--- Filter newest-first commands. Returns up to `limit` matches, best score first
--- (recency is a stable tie-break: earlier in `cmds` = newer).
function M.fuzzy_filter(cmds, query, limit)
    limit = limit or 200
    query = trim(query)
    if query == "" then
        local out = {}
        for i = 1, math.min(limit, #(cmds or {})) do
            out[i] = cmds[i]
        end
        return out
    end
    local scored = {}
    for i = 1, #(cmds or {}) do
        local s = M.query_score(cmds[i], query)
        if s then
            -- recency: smaller i is newer
            scored[#scored + 1] = { cmd = cmds[i], score = s, i = i }
        end
    end
    table.sort(scored, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        return a.i < b.i
    end)
    local out = {}
    for i = 1, math.min(limit, #scored) do
        out[i] = scored[i].cmd
    end
    return out
end

return M
