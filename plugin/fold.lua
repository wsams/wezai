-- Pure helpers to fold long Ask/Edit text for the AI output pane.
-- No wezterm / subprocess. Used by ui.lua and scripts/test_fold.lua.

local M = {}

local DEFAULT_MAX_LINES = 8
local DEFAULT_MAX_CHARS = 600
local DEFAULT_MAX_LINE_CHARS = 160

local function to_int(v, fallback)
    if v == nil then
        return fallback
    end
    local n = tonumber(v)
    if not n then
        return fallback
    end
    return math.floor(n)
end

local function split_lines(text)
    text = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if text == "" then
        return {}
    end
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    -- Drop the empty match created by the extra "\n" we appended.
    if #lines > 0 and lines[#lines] == "" then
        table.remove(lines)
    end
    return lines
end

local function clip_line(line, max_line_chars)
    if max_line_chars and max_line_chars > 0 and #line > max_line_chars then
        return line:sub(1, max_line_chars) .. "…", true
    end
    return line, false
end

--- Fold long text for the write-only AI pane (no interactive expand).
--- opts: max_lines, max_chars, max_line_chars. Values <= 0 disable that limit.
--- Returns display_text, meta { folded, lines, chars, shown_lines }
function M.fold_text(text, opts)
    opts = opts or {}
    if type(text) ~= "string" then
        text = text == nil and "" or tostring(text)
    end
    local max_lines = to_int(opts.max_lines, DEFAULT_MAX_LINES)
    local max_chars = to_int(opts.max_chars, DEFAULT_MAX_CHARS)
    local max_line_chars = to_int(opts.max_line_chars, DEFAULT_MAX_LINE_CHARS)

    local lines = split_lines(text)
    local total_lines = #lines
    local total_chars = #text
    if total_lines == 0 then
        return "", { folded = false, lines = 0, chars = 0, shown_lines = 0 }
    end

    local shown = {}
    local shown_chars = 0
    local folded = false

    for _, line in ipairs(lines) do
        if max_lines > 0 and #shown >= max_lines then
            folded = true
            break
        end
        local piece, line_cut = clip_line(line, max_line_chars)
        local room = (max_chars > 0) and (max_chars - shown_chars) or nil
        if room and room <= 0 then
            folded = true
            break
        end
        if room and #piece > room then
            piece = piece:sub(1, room) .. "…"
            line_cut = true
        end
        shown[#shown + 1] = piece
        shown_chars = shown_chars + #piece
        if line_cut then
            folded = true
            if max_chars > 0 and shown_chars >= max_chars then
                break
            end
        end
    end

    if #shown < total_lines then
        folded = true
    end

    local out = table.concat(shown, "\n")
    if folded then
        local hidden = math.max(0, total_lines - #shown)
        if hidden > 0 then
            out = out
                .. string.format(
                    "\n… folded %d more line%s (%d chars)",
                    hidden,
                    hidden == 1 and "" or "s",
                    total_chars
                )
        else
            out = out .. string.format("\n… folded (%d chars)", total_chars)
        end
    end

    return out, {
        folded = folded,
        lines = total_lines,
        chars = total_chars,
        shown_lines = #shown,
    }
end

M.DEFAULT_MAX_LINES = DEFAULT_MAX_LINES
M.DEFAULT_MAX_CHARS = DEFAULT_MAX_CHARS
M.DEFAULT_MAX_LINE_CHARS = DEFAULT_MAX_LINE_CHARS

return M
