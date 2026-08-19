local util = require("util")

local M = {}

-- tab_id -> {
--   turns = { {role, text}, ... },
--   last_command, last_question,
--   last_edit = {path, backup?, content?, items?},
--   events = { {kind, text, path?, instruction?, t}, ... },
--   pins = { {path, kind="attach"|"edit", raw?, is_dir?}, ... },
--   ephemeral = { {label, content}, ... },  -- selection / extra; compacted away
--   draft = string,
-- }
local store = {}

local SAFETY_MAX_TURNS = 200

local function bucket(window)
    local tid = util.tab_id(window)
    if not store[tid] then
        store[tid] = { turns = {}, events = {}, pins = {}, ephemeral = {}, draft = "" }
    end
    local b = store[tid]
    if not b.events then
        b.events = {}
    end
    if not b.pins then
        b.pins = {}
    end
    if not b.ephemeral then
        b.ephemeral = {}
    end
    if b.draft == nil then
        b.draft = ""
    end
    return b
end

local function empty_state()
    return { turns = {}, events = {}, pins = {}, ephemeral = {}, draft = "" }
end

function M.clear(window)
    store[util.tab_id(window)] = empty_state()
end

function M.mark_large_ok(window)
    bucket(window).large_ok = true
end

function M.large_ok(window)
    return bucket(window).large_ok == true
end

--- Compact conversation + sticky selection text. File pins (@ / #) are kept.
function M.compact(window, config)
    local b = bucket(window)
    local old_turns = #b.turns
    local old_eph = #(b.ephemeral or {})
    local keep_n = 4
    if config and tonumber(config.chat_keep_turns) then
        keep_n = math.max(2, tonumber(config.chat_keep_turns) * 2)
    end

    local recap_chars = (config and config.context and config.context.compact_chars) or 4000
    local older = {}
    local kept = {}
    if #b.turns > keep_n then
        for i = 1, #b.turns - keep_n do
            older[#older + 1] = b.turns[i]
        end
        for i = #b.turns - keep_n + 1, #b.turns do
            kept[#kept + 1] = b.turns[i]
        end
    else
        kept = b.turns
    end

    local recap = nil
    if #older > 0 then
        local parts = {}
        local used = 0
        for _, t in ipairs(older) do
            local chunk = (t.role or "?"):upper() .. ": " .. (t.text or "")
            if used + #chunk > recap_chars then
                local remain = recap_chars - used
                if remain > 80 then
                    parts[#parts + 1] = chunk:sub(1, remain) .. "…"
                end
                break
            end
            parts[#parts + 1] = chunk
            used = used + #chunk + 1
        end
        recap = {
            role = "system",
            text = "Earlier conversation (compacted; file attachments kept separately):\n"
                .. table.concat(parts, "\n"),
        }
    end

    local new_turns = {}
    if recap then
        new_turns[1] = recap
    end
    for _, t in ipairs(kept) do
        new_turns[#new_turns + 1] = t
    end
    b.turns = new_turns
    b.ephemeral = {}

    return {
        turns_before = old_turns,
        turns_after = #b.turns,
        ephemeral_cleared = old_eph,
        pins_kept = #(b.pins or {}),
    }
end

function M.add_turn(window, role, text, max_turns)
    if not text or text == "" then
        return
    end
    local b = bucket(window)
    table.insert(b.turns, { role = role, text = text })
    -- High safety cap only — explicit Compact is how users shrink history.
    local cap = SAFETY_MAX_TURNS
    if max_turns and tonumber(max_turns) and tonumber(max_turns) > 0 then
        -- Treat chat_max_turns as a soft ceiling of exchanges, not a silent 6-turn trim.
        local requested = tonumber(max_turns) * 2
        if requested > cap then
            cap = requested
        end
        if requested >= 20 then
            cap = requested
        else
            -- Small configured values used to auto-drop; keep a generous floor so
            -- follow-up CTRL+I turns stay in session until Compact/Clear.
            cap = math.max(cap, 80)
        end
    end
    while #b.turns > cap do
        table.remove(b.turns, 1)
    end
end

function M.history_block(window)
    local b = bucket(window)
    if #b.turns == 0 then
        return ""
    end
    local parts = { "Recent conversation:" }
    for _, t in ipairs(b.turns) do
        table.insert(parts, t.role:upper() .. ": " .. t.text)
    end
    return table.concat(parts, "\n")
end

function M.set_last_command(window, cmd)
    bucket(window).last_command = cmd
end

function M.get_last_command(window)
    return bucket(window).last_command
end

function M.set_last_question(window, q)
    bucket(window).last_question = q
end

function M.get_last_question(window)
    return bucket(window).last_question
end

--- Remember last apply for undo. `backup` is a path on disk (or nil when
--- backups are disabled); `content` is the pre-edit text kept in memory.
function M.set_last_edit(window, path, backup, content)
    local items = { { path = path, backup = backup, content = content } }
    bucket(window).last_edit = {
        path = path,
        backup = backup,
        content = content,
        items = items,
    }
end

function M.set_last_edit_batch(window, items)
    items = items or {}
    local last = items[#items]
    bucket(window).last_edit = {
        path = last and last.path,
        backup = last and last.backup,
        content = last and last.content,
        items = items,
    }
end

function M.get_last_edit(window)
    return bucket(window).last_edit
end

function M.set_draft(window, text)
    bucket(window).draft = text or ""
end

function M.get_draft(window)
    return bucket(window).draft or ""
end

function M.clear_draft(window)
    bucket(window).draft = ""
end

local function pin_key(kind, path)
    return tostring(kind or "attach") .. "\0" .. tostring(path or "")
end

--- Pin a file or directory for the rest of the session (until Clear).
--- kind: "attach" (@) or "edit" (#)
function M.pin(window, rec)
    if not rec or not rec.path or rec.path == "" then
        return
    end
    local b = bucket(window)
    local key = pin_key(rec.kind or "attach", rec.path)
    for i, p in ipairs(b.pins) do
        if pin_key(p.kind, p.path) == key then
            b.pins[i] = rec
            return
        end
    end
    b.pins[#b.pins + 1] = rec
end

function M.list_pins(window)
    return bucket(window).pins or {}
end

function M.has_edit_pins(window)
    for _, p in ipairs(bucket(window).pins or {}) do
        if p.kind == "edit" then
            return true
        end
    end
    return false
end

function M.pins_summary(window)
    local pins = bucket(window).pins or {}
    if #pins == 0 then
        return ""
    end
    local parts = {}
    for _, p in ipairs(pins) do
        local sig = (p.kind == "edit") and "#" or "@"
        local name = p.raw or p.path or "?"
        parts[#parts + 1] = sig .. name
    end
    return table.concat(parts, "  ")
end

function M.add_ephemeral(window, label, content)
    if not content or content == "" then
        return
    end
    local b = bucket(window)
    -- Replace same label so repeated selections don't pile up.
    for i, e in ipairs(b.ephemeral) do
        if e.label == label then
            b.ephemeral[i] = { label = label, content = content }
            return
        end
    end
    b.ephemeral[#b.ephemeral + 1] = { label = label, content = content }
end

function M.list_ephemeral(window)
    return bucket(window).ephemeral or {}
end

-- kind: "ai-cmd" | "ask" | "edit"
function M.push_history_event(window, event, max_events)
    if not event or not event.kind or not event.text or event.text == "" then
        return
    end
    local b = bucket(window)
    max_events = max_events or 50
    table.insert(b.events, {
        kind = event.kind,
        text = event.text,
        path = event.path,
        instruction = event.instruction,
        t = os.time(),
    })
    while #b.events > max_events do
        table.remove(b.events, 1)
    end
end

function M.list_history_events(window, limit)
    local b = bucket(window)
    local events = b.events or {}
    limit = limit or #events
    local out = {}
    local start = math.max(1, #events - limit + 1)
    for i = start, #events do
        table.insert(out, events[i])
    end
    return out
end

return M
