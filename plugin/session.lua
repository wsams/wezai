local util = require("util")

local M = {}

-- tab_id -> {
--   turns = { {role, text}, ... },
--   last_command, last_question,
--   last_edit = {path, backup?, content?},
--   events = { {kind, text, path?, instruction?, t}, ... }
-- }
local store = {}

local function bucket(window)
    local tid = util.tab_id(window)
    if not store[tid] then
        store[tid] = { turns = {}, events = {} }
    end
    if not store[tid].events then
        store[tid].events = {}
    end
    return store[tid]
end

function M.clear(window)
    store[util.tab_id(window)] = { turns = {}, events = {} }
end

function M.add_turn(window, role, text, max_turns)
    if not text or text == "" then
        return
    end
    local b = bucket(window)
    table.insert(b.turns, { role = role, text = text })
    max_turns = max_turns or 6
    local max_items = max_turns * 2
    while #b.turns > max_items do
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

--- Remember last @@ apply for undo. `backup` is a path on disk (or nil when
--- backups are disabled); `content` is the pre-edit text kept in memory.
function M.set_last_edit(window, path, backup, content)
    bucket(window).last_edit = { path = path, backup = backup, content = content }
end

function M.get_last_edit(window)
    return bucket(window).last_edit
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
