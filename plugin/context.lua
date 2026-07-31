local wezterm = require("wezterm")
local util = require("util")

local M = {}

M.DEFAULT_SELECTION_INSTRUCTION =
    "Explain the selected text. If it looks like an error or problem, diagnose it "
        .. "and suggest how to fix it. Prefer a ready-to-run command when a fix is appropriate."

M.DEFAULT_FILE_INSTRUCTION =
    "Explain the attached file(s). If they look problematic, diagnose the issue "
        .. "and suggest how to fix it. Prefer a ready-to-run command when a fix is appropriate."

M.EDIT_SYSTEM_PROMPT =
    "You edit a single file in one pass. Apply the user's modification to the edit target. "
        .. "Respond with JSON only (no markdown fences) with fields: "
        .. "message (brief summary of changes), "
        .. "file (the COMPLETE revised file contents as a string, not a diff), "
        .. "command (null or empty string). "
        .. "Do not omit any part of the file."

function M.redact(text)
    if not text or text == "" then
        return text
    end
    local s = text
    s = s:gsub("-----BEGIN[%w ]-PRIVATE KEY-----.------END[%w ]-PRIVATE KEY-----", "[REDACTED_PRIVATE_KEY]")
    s = s:gsub("AKIA[%w]+", "[REDACTED_AWS_KEY]")
    s = s:gsub("ghp_[%w]+", "[REDACTED_GITHUB_TOKEN]")
    s = s:gsub("gho_[%w]+", "[REDACTED_GITHUB_TOKEN]")
    s = s:gsub("github_pat_[%w_]+", "[REDACTED_GITHUB_TOKEN]")
    s = s:gsub("sk%-[%w%._%-]+", "[REDACTED_API_KEY]")
    s = s:gsub("[Aa]uthorization:%s*[Bb]earer%s+%S+", "Authorization: Bearer [REDACTED]")
    s = s:gsub("xox[baprs]%-[%w%-]+", "[REDACTED_SLACK_TOKEN]")
    s = s:gsub("eyJ[%w_%-]+%.eyJ[%w_%-]+%.[%w_%-]+", "[REDACTED_JWT]")
    return s
end

-- Trailing sentence punctuation commonly stuck to @refs: `@package.json?`
local TRAIL_PUNCT = "[%?%!%.,;:%]%}%)'\"…]+$"

local function is_reserved_ref(raw)
    return raw == "clipboard"
        or raw == "selection"
        or raw == "pick"
        or raw == "history"
        or raw:match("^history:") ~= nil
        or raw:match("^git:") ~= nil
        or raw:match("^dir:") ~= nil
end

--- Strip trailing punctuation from unquoted @paths (keeps reserved synthetics intact).
function M.sanitize_path_token(path, quoted)
    if not path or path == "" or quoted then
        return path
    end
    if is_reserved_ref(path) then
        return path
    end
    local cleaned = path:gsub(TRAIL_PUNCT, "")
    if cleaned == "" then
        return path
    end
    return cleaned
end

function M.parse_at_refs(line)
    local paths = {}
    local edit_paths = {}
    local synthetics = {}
    if not line or line == "" then
        return { paths = paths, edit_paths = edit_paths, synthetics = synthetics, rest = line or "" }
    end

    local function read_path_token(start_idx)
        local next_ch = line:sub(start_idx, start_idx)
        local path
        local i
        local quoted = false
        if next_ch == '"' or next_ch == "'" then
            quoted = true
            local quote = next_ch
            local close = line:find(quote, start_idx + 1, true)
            if close then
                path = line:sub(start_idx + 1, close - 1)
                i = close + 1
            else
                path = line:sub(start_idx + 1)
                i = #line + 1
            end
        else
            local j = start_idx
            while j <= #line do
                local c = line:sub(j, j)
                if c:match("%s") then
                    break
                end
                j = j + 1
            end
            path = line:sub(start_idx, j - 1)
            i = j
            path = M.sanitize_path_token(path, false)
        end
        return path, i, quoted
    end

    local function classify_ref(raw)
        if raw == "clipboard" or raw == "selection" or raw == "pick" then
            return "synthetic", raw
        end
        if raw == "history" or raw:match("^history:") then
            return "synthetic", raw
        end
        if raw:match("^git:") then
            return "synthetic", raw
        end
        if raw:match("^dir:") then
            return "synthetic", raw
        end
        return "path", raw
    end

    local rest_parts = {}
    local i = 1
    local len = #line

    while i <= len do
        local ch = line:sub(i, i)
        if ch == "@" then
            local next_ch = line:sub(i + 1, i + 1)
            if next_ch == "@" then
                local path
                path, i = read_path_token(i + 2)
                if path and path ~= "" then
                    path = path:gsub("^@+", "")
                end
                if path and path ~= "" then
                    table.insert(edit_paths, path)
                end
            else
                local path
                path, i = read_path_token(i + 1)
                if path and path ~= "" then
                    local kind, value = classify_ref(path)
                    if kind == "synthetic" then
                        table.insert(synthetics, value)
                    else
                        table.insert(paths, value)
                    end
                end
            end
        else
            local start = i
            while i <= len and line:sub(i, i) ~= "@" do
                i = i + 1
            end
            table.insert(rest_parts, line:sub(start, i - 1))
        end
    end

    local rest = table.concat(rest_parts, "")
    rest = rest:gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
    return { paths = paths, edit_paths = edit_paths, synthetics = synthetics, rest = rest }
end

local function selection_as_file_path(selection, cwd)
    if not selection or selection:find("[\r\n]") then
        return nil
    end
    local candidate = selection:match("^%s*(.-)%s*$")
    if not candidate or candidate == "" then
        return nil
    end
    candidate = M.sanitize_path_token(candidate:gsub("^[@]+", ""), false)
    local expanded = util.expand_path(candidate, cwd)
    if expanded and util.path_exists_as_file(expanded) then
        return expanded
    end
    return nil
end

local function build_files_section(files)
    local parts = {}
    for _, file in ipairs(files) do
        local label = file.label or "File"
        table.insert(parts, label .. ": " .. (file.path or "?") .. "\n```\n" .. file.content .. "\n```")
    end
    return table.concat(parts, "\n\n")
end

local function resolve_and_read_files(raw_paths, cwd, max_bytes, seen)
    seen = seen or {}
    local files = {}
    local errors = {}
    for _, raw in ipairs(raw_paths) do
        local abs = util.expand_path(raw, cwd)
        if not abs then
            table.insert(errors, "cannot resolve path (no pane cwd?): " .. tostring(raw))
        elseif not seen[abs] then
            seen[abs] = true
            if not util.path_exists_as_file(abs) then
                table.insert(errors, "file not found: " .. abs)
            else
                local ok, content_or_err = util.read_text_file(abs, max_bytes)
                if ok then
                    table.insert(files, { path = abs, content = content_or_err })
                else
                    table.insert(errors, content_or_err)
                end
            end
        end
    end
    return files, errors, seen
end

local function list_dir_shallow(dir_path, max_entries)
    max_entries = max_entries or 200
    local ok, stdout = util.run_cmd({
        "sh",
        "-c",
        'ls -la "' .. dir_path:gsub('"', '\\"') .. '" 2>/dev/null | head -n ' .. tostring(max_entries + 1),
    })
    if not ok then
        return nil, "cannot list directory: " .. dir_path
    end
    local lines = {}
    local n = 0
    for line in (stdout .. "\n"):gmatch("(.-)\n") do
        n = n + 1
        if n > max_entries then
            table.insert(lines, "... (truncated)")
            break
        end
        table.insert(lines, line)
    end
    return table.concat(lines, "\n"), nil
end

local function resolve_synthetics(synthetics, window, pane, cwd, config)
    local shell = require("shell")
    local history = require("history")
    local blocks = {}
    local errors = {}
    local labels = {}

    for _, syn in ipairs(synthetics) do
        if syn == "clipboard" then
            local clip = shell.read_clipboard()
            if not clip or clip == "" then
                table.insert(errors, "clipboard is empty or unreadable (need pbpaste/xclip/wl-paste)")
            else
                table.insert(blocks, { label = "Clipboard", path = "@clipboard", content = clip })
                table.insert(labels, "@clipboard")
            end
        elseif syn == "selection" then
            local sel = util.get_selection(window, pane)
            if not sel then
                table.insert(errors, "no terminal selection for @selection")
            else
                table.insert(blocks, { label = "Selection", path = "@selection", content = sel })
                table.insert(labels, "@selection")
            end
        elseif syn:match("^git:") then
            local gitmod = require("git")
            if not cwd then
                table.insert(errors, "@" .. syn .. " needs pane cwd")
            else
                local content, gerr = gitmod.collect_attach(cwd, syn, config)
                if gerr then
                    table.insert(errors, "@" .. syn .. " failed: " .. gerr)
                else
                    table.insert(blocks, {
                        label = "Git " .. (syn:match("^git:(.+)$") or syn),
                        path = "@" .. syn,
                        content = content,
                    })
                    table.insert(labels, "@" .. syn)
                end
            end
        elseif syn:match("^dir:") then
            local rel = syn:sub(5)
            if rel == "" then
                rel = "."
            end
            local abs = util.expand_path(rel, cwd)
            if not abs or not util.path_exists_as_dir(abs) then
                table.insert(errors, "@dir not found: " .. tostring(rel))
            else
                local listing, err = list_dir_shallow(abs, 200)
                if not listing then
                    table.insert(errors, err)
                else
                    table.insert(blocks, { label = "Directory listing", path = "@dir:" .. abs, content = listing })
                    table.insert(labels, "@dir:" .. rel)
                end
            end
        elseif syn == "history" or syn:match("^history:") then
            local filter, limit = history.parse_history_spec(syn)
            local content = history.attach_block(window, pane, config or {}, filter, limit)
            table.insert(blocks, {
                label = "History",
                path = "@" .. syn,
                content = M.redact(content),
            })
            table.insert(labels, "@" .. syn)
        else
            table.insert(errors, "unknown synthetic ref: @" .. syn)
        end
    end

    return blocks, errors, labels
end

function M.prepare_request(window, pane, line, selection, config)
    local cwd = util.get_pane_cwd(pane)
    local max_bytes = config.max_file_bytes or 100000
    local parsed = M.parse_at_refs(line or "")
    local seen = {}

    local synth_blocks, synth_errors, synth_labels = resolve_synthetics(parsed.synthetics, window, pane, cwd, config)
    if #synth_errors > 0 and #parsed.edit_paths == 0 and #parsed.paths == 0 and not selection and parsed.rest == "" then
        return nil, table.concat(synth_errors, "; ")
    end

    if #parsed.edit_paths > 1 then
        return nil, "only one @@ edit target is allowed (got " .. #parsed.edit_paths .. ")"
    end

    if #parsed.edit_paths == 1 then
        local instruction = parsed.rest
        if not instruction or instruction:match("^%s*$") then
            return nil, "edit instruction required after @@path (example: @@file.txt sort the lines)"
        end

        local edit_files, edit_errors, seen_after = resolve_and_read_files(parsed.edit_paths, cwd, max_bytes, seen)
        if #edit_errors > 0 then
            return nil, table.concat(edit_errors, "; ")
        end
        if #edit_files ~= 1 then
            return nil, "edit target could not be loaded"
        end
        local target = edit_files[1]
        seen = seen_after

        local context_files, ctx_errors
        context_files, ctx_errors, seen = resolve_and_read_files(parsed.paths, cwd, max_bytes, seen)
        if #ctx_errors > 0 then
            return nil, table.concat(ctx_errors, "; ")
        end
        if #synth_errors > 0 then
            return nil, table.concat(synth_errors, "; ")
        end

        local selected_file = selection_as_file_path(selection, cwd)
        if selected_file and not seen[selected_file] then
            local ok, content_or_err = util.read_text_file(selected_file, max_bytes)
            if not ok then
                return nil, content_or_err
            end
            table.insert(context_files, { path = selected_file, content = content_or_err })
        end

        local parts = {}
        table.insert(
            parts,
            "Edit target (rewrite this file completely in the JSON \"file\" field):\n"
                .. "File: "
                .. target.path
                .. "\n```\n"
                .. target.content
                .. "\n```"
        )
        if #context_files > 0 then
            for _, f in ipairs(context_files) do
                f.label = "Read-only context"
            end
            table.insert(parts, build_files_section(context_files))
        end
        if #synth_blocks > 0 then
            table.insert(parts, build_files_section(synth_blocks))
        end
        if selection and not selected_file then
            table.insert(parts, "Selected text:\n```\n" .. selection .. "\n```")
        end
        table.insert(parts, "Modification requested:\n" .. instruction)

        local all_files = { target }
        for _, f in ipairs(context_files) do
            table.insert(all_files, f)
        end
        for _, f in ipairs(synth_blocks) do
            table.insert(all_files, f)
        end

        return {
            mode = "edit",
            prompt = M.redact(table.concat(parts, "\n\n")),
            files = all_files,
            target_path = target.path,
            original_content = target.content,
            user_text = instruction,
            attach_labels = synth_labels,
        }, nil
    end

    -- Ask mode
    if #synth_errors > 0 then
        return nil, table.concat(synth_errors, "; ")
    end

    local file_paths = {}
    local function add_path(raw_or_abs, already_absolute)
        local abs = already_absolute and raw_or_abs or util.expand_path(raw_or_abs, cwd)
        if not abs then
            return "cannot resolve path (no pane cwd?): " .. tostring(raw_or_abs)
        end
        if seen[abs] then
            return nil
        end
        seen[abs] = true
        table.insert(file_paths, abs)
        return nil
    end

    local selected_file = selection_as_file_path(selection, cwd)
    local selection_text = nil
    if selected_file then
        local err = add_path(selected_file, true)
        if err then
            return nil, err
        end
    elseif selection then
        selection_text = selection
    end

    for _, raw in ipairs(parsed.paths) do
        local err = add_path(raw, false)
        if err then
            return nil, err
        end
    end

    local files = {}
    local errors = {}
    for _, abs in ipairs(file_paths) do
        if not util.path_exists_as_file(abs) then
            table.insert(errors, "file not found: " .. abs)
        else
            local ok, content_or_err = util.read_text_file(abs, max_bytes)
            if ok then
                table.insert(files, { path = abs, content = content_or_err })
            else
                table.insert(errors, content_or_err)
            end
        end
    end
    if #errors > 0 then
        return nil, table.concat(errors, "; ")
    end

    local question = parsed.rest
    local has_files = #files > 0 or #synth_blocks > 0
    local has_selection_text = selection_text ~= nil
    local has_question = question and not question:match("^%s*$")

    if not has_files and not has_selection_text and not has_question then
        return nil, nil
    end

    local parts = {}
    if #files > 0 then
        table.insert(parts, build_files_section(files))
    end
    if #synth_blocks > 0 then
        table.insert(parts, build_files_section(synth_blocks))
    end
    if has_selection_text then
        table.insert(parts, "Selected text:\n```\n" .. selection_text .. "\n```")
    end
    if has_question then
        table.insert(parts, question)
    elseif has_files then
        table.insert(parts, M.DEFAULT_FILE_INSTRUCTION)
    elseif has_selection_text then
        table.insert(parts, M.DEFAULT_SELECTION_INSTRUCTION)
    end

    local all = {}
    for _, f in ipairs(files) do
        table.insert(all, f)
    end
    for _, f in ipairs(synth_blocks) do
        table.insert(all, f)
    end

    return {
        mode = "ask",
        prompt = M.redact(table.concat(parts, "\n\n")),
        files = all,
        user_text = question,
        attach_labels = synth_labels,
    }, nil
end

function M.selection_as_file_path(selection, cwd)
    return selection_as_file_path(selection, cwd)
end

return M
