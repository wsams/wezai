local util = require("util")
local filesmod = require("files")
local session = require("session")

local M = {}

M.DEFAULT_SELECTION_INSTRUCTION =
    "Explain the selected text. If it looks like an error or problem, diagnose it "
        .. "and suggest how to fix it. Prefer a ready-to-run command when a fix is appropriate."

M.DEFAULT_FILE_INSTRUCTION =
    "Explain the attached file(s). If they look problematic, diagnose the issue "
        .. "and suggest how to fix it. Prefer a ready-to-run command when a fix is appropriate."

M.EDIT_SYSTEM_PROMPT =
    "You create or rewrite one or more files in one pass. "
        .. "If a target is empty / new, invent the full contents from the user's instruction. "
        .. "If a target already has content, apply the modification to the whole file. "
        .. "Only modify files listed as edit targets; treat read-only context as reference. "
        .. "Respond with JSON only (no markdown fences) with fields: "
        .. "message (brief summary of changes), "
        .. "files (array of objects: path (absolute path of an edit target), content (COMPLETE file contents as a string, not a diff)), "
        .. "command (null or empty string). "
        .. "For a single-file edit you may also set file (COMPLETE contents) instead of files. "
        .. "Do not omit any part of a rewritten file. Do not invent paths that were not listed as edit targets."

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
        or raw:match("^kube:") ~= nil
        or raw:match("^tf:") ~= nil
        or raw:match("^terraform:") ~= nil
        or raw:match("^docker:") ~= nil
        or raw == "docker"
        or raw == "weather"
        or raw:match("^weather:") ~= nil
        or raw:match("^dir:") ~= nil
end

local function path_like_char(c)
    return c and c ~= "" and c:match("[^%s#]") ~= nil
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
        if raw:match("^kube:") then
            return "synthetic", raw
        end
        if raw:match("^tf:") or raw:match("^terraform:") then
            -- Normalize @terraform:… → tf:… for collect_attach
            if raw:match("^terraform:") then
                return "synthetic", "tf:" .. (raw:match("^terraform:(.+)$") or "")
            end
            return "synthetic", raw
        end
        if raw:match("^docker:") then
            return "synthetic", raw
        end
        if raw == "docker" then
            return "synthetic", "docker:ps"
        end
        if raw == "weather" or raw:match("^weather:") then
            if raw == "weather" then
                return "synthetic", "weather:now"
            end
            return "synthetic", raw
        end
        if raw:match("^dir:") then
            return "synthetic", raw
        end
        return "path", raw
    end

    local function at_token_start(idx)
        if idx <= 1 then
            return true
        end
        local prev = line:sub(idx - 1, idx - 1)
        return prev:match("%s") ~= nil
    end

    local rest_parts = {}
    local i = 1
    local len = #line

    while i <= len do
        local ch = line:sub(i, i)
        if ch == "#" and at_token_start(i) then
            local next_ch = line:sub(i + 1, i + 1)
            if next_ch == "" or next_ch:match("%s") then
                -- Bare `#` is handled as a picker by files.parse_pick_line; keep as rest otherwise.
                table.insert(rest_parts, "#")
                i = i + 1
            elseif path_like_char(next_ch) then
                local path
                path, i = read_path_token(i + 1)
                if path and path ~= "" then
                    path = path:gsub("^[#@]+", "")
                end
                if path == "pick" then
                    table.insert(edit_paths, "pick")
                elseif path and path ~= "" then
                    table.insert(edit_paths, path)
                end
            else
                table.insert(rest_parts, "#")
                i = i + 1
            end
        elseif ch == "@" and at_token_start(i) then
            local next_ch = line:sub(i + 1, i + 1)
            if next_ch == "@" then
                -- Legacy @@path edit (alias of #path)
                local path
                path, i = read_path_token(i + 2)
                if path and path ~= "" then
                    path = path:gsub("^[@#]+", "")
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
            while i <= len do
                local c = line:sub(i, i)
                if (c == "@" or c == "#") and at_token_start(i) then
                    break
                end
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
    candidate = M.sanitize_path_token(candidate:gsub("^[@#]+", ""), false)
    local expanded = util.expand_path(candidate, cwd)
    if expanded and util.path_exists_as_file(expanded) then
        return expanded
    end
    return nil
end

local function build_files_section(file_list)
    local parts = {}
    for _, file in ipairs(file_list) do
        local label = file.label or "File"
        if file.truncated then
            label = label
                .. " (TRUNCATED — "
                .. tostring(file.size or "?")
                .. " bytes total; head+tail only)"
        end
        table.insert(parts, label .. ": " .. (file.path or "?") .. "\n```\n" .. file.content .. "\n```")
    end
    return table.concat(parts, "\n\n")
end

local function ctx_opts(config)
    local c = (config and config.context) or {}
    return {
        max_prompt_tokens = tonumber(c.max_prompt_tokens) or 24000,
        warn_tokens = tonumber(c.warn_tokens) or 6000,
        confirm_tokens = tonumber(c.confirm_tokens) or 12000,
        chars_per_token = tonumber(c.chars_per_token) or 4,
        max_dir_files = tonumber(c.max_dir_files) or 80,
        max_dir_bytes = tonumber(c.max_dir_bytes) or 800000,
        compact_chars = tonumber(c.compact_chars) or 4000,
    }
end

function M.estimate_tokens(text, config)
    local n = ctx_opts(config).chars_per_token
    if n < 1 then
        n = 4
    end
    if type(text) ~= "string" or text == "" then
        return 0
    end
    return math.max(0, math.floor(#text / n))
end

local function attach_read_opts(config, max_bytes)
    local f = (config and config.files) or {}
    return {
        max_bytes = max_bytes or (config and config.max_file_bytes) or 100000,
        large_file = f.large_file or "head_tail",
        head_bytes = f.head_bytes,
        tail_bytes = f.tail_bytes,
    }
end

local function display_name(abs, cwd)
    if cwd and abs:sub(1, #cwd + 1) == cwd .. "/" then
        return abs:sub(#cwd + 2)
    end
    return abs
end

local function push_unique(list, seen, rec)
    if not rec or not rec.path or seen[rec.path] then
        return
    end
    seen[rec.path] = true
    list[#list + 1] = rec
end

--- Expand a user path token into file records (walks directories).
local function resolve_path_token(raw, cwd, max_bytes, seen, config, mode, budget)
    local files = {}
    local errors = {}
    local omitted = {}
    local abs = util.expand_path(raw, cwd)
    if not abs then
        table.insert(errors, "cannot resolve path (no pane cwd?): " .. tostring(raw))
        return files, errors, omitted
    end
    -- Trailing slash means "this is a directory"
    local want_dir = tostring(raw):match("[/\\]$") ~= nil
    local is_dir = util.path_exists_as_dir(abs)
    local is_file = util.path_exists_as_file(abs)

    if is_dir then
        local walked = filesmod.walk_files(abs, config)
        if #walked == 0 then
            table.insert(errors, "directory has no attachable files: " .. abs)
            return files, errors, omitted
        end
        local dir_bytes = 0
        local max_bytes_dir = ctx_opts(config).max_dir_bytes
        local read_opts = attach_read_opts(config, max_bytes)
        if mode == "edit" then
            read_opts = { max_bytes = max_bytes, large_file = "error" }
        end
        for _, path in ipairs(walked) do
            if seen[path] then
                -- skip
            elseif budget and budget.tokens_left and budget.tokens_left <= 0 then
                omitted[#omitted + 1] = display_name(path, cwd)
            else
                local ok, content_or_err, meta
                if mode == "edit" then
                    ok, content_or_err = util.read_text_file(path, max_bytes)
                    meta = { truncated = false }
                else
                    ok, content_or_err, meta = util.read_text_file_smart(path, read_opts)
                end
                if ok then
                    local rec = {
                        path = path,
                        content = content_or_err,
                        truncated = meta and meta.truncated,
                        size = meta and meta.size or #content_or_err,
                        from_dir = abs,
                        raw = raw,
                    }
                    local tok = M.estimate_tokens(rec.content, config)
                    if budget then
                        if budget.tokens_left - tok < 0 and #files > 0 then
                            omitted[#omitted + 1] = display_name(path, cwd)
                        else
                            dir_bytes = dir_bytes + (rec.size or 0)
                            if dir_bytes > max_bytes_dir and #files > 0 then
                                omitted[#omitted + 1] = display_name(path, cwd)
                            else
                                seen[path] = true
                                files[#files + 1] = rec
                                if budget.tokens_left then
                                    budget.tokens_left = budget.tokens_left - tok
                                end
                            end
                        end
                    else
                        seen[path] = true
                        files[#files + 1] = rec
                    end
                else
                    -- Skip unreadable/binary/oversized in directory walks; record omit.
                    omitted[#omitted + 1] = display_name(path, cwd) .. " (" .. tostring(content_or_err) .. ")"
                end
            end
        end
        return files, errors, omitted
    end

    if want_dir and not is_dir then
        table.insert(errors, "not a directory: " .. abs)
        return files, errors, omitted
    end

    if not is_file then
        table.insert(errors, "file not found: " .. abs)
        return files, errors, omitted
    end
    if seen[abs] then
        return files, errors, omitted
    end

    if mode == "edit" then
        local ok, content_or_err = util.read_text_file(abs, max_bytes)
        if not ok then
            table.insert(
                errors,
                content_or_err
                    .. " (# edit needs the full file — raise max_file_bytes, or split the file)"
            )
            return files, errors, omitted
        end
        seen[abs] = true
        files[1] = { path = abs, content = content_or_err, truncated = false, size = #content_or_err, raw = raw }
        if budget and budget.tokens_left then
            budget.tokens_left = budget.tokens_left - M.estimate_tokens(content_or_err, config)
        end
        return files, errors, omitted
    end

    local read_opts = attach_read_opts(config, max_bytes)
    local ok, content_or_err, meta = util.read_text_file_smart(abs, read_opts)
    if not ok then
        table.insert(errors, content_or_err)
        return files, errors, omitted
    end
    seen[abs] = true
    files[1] = {
        path = abs,
        content = content_or_err,
        truncated = meta and meta.truncated,
        size = meta and meta.size,
        raw = raw,
    }
    if budget and budget.tokens_left then
        budget.tokens_left = budget.tokens_left - M.estimate_tokens(content_or_err, config)
    end
    return files, errors, omitted
end

local function resolve_and_read_files(raw_paths, cwd, max_bytes, seen, config, mode, budget)
    seen = seen or {}
    local files = {}
    local errors = {}
    local omitted = {}
    for _, raw in ipairs(raw_paths) do
        local got, errs, omit = resolve_path_token(raw, cwd, max_bytes, seen, config, mode or "attach", budget)
        for _, f in ipairs(got) do
            files[#files + 1] = f
        end
        for _, e in ipairs(errs) do
            errors[#errors + 1] = e
        end
        for _, o in ipairs(omit) do
            omitted[#omitted + 1] = o
        end
    end
    return files, errors, seen, omitted
end

--- Resolve # target: existing file, directory walk, or create-new if the parent directory exists.
local function resolve_edit_target(raw, cwd, max_bytes, config, seen, budget)
    local abs = util.expand_path(raw, cwd)
    if not abs then
        return nil, "cannot resolve path (no pane cwd?): " .. tostring(raw)
    end
    if util.path_exists_as_dir(abs) then
        local files, errors, omitted = resolve_path_token(raw, cwd, max_bytes, seen or {}, config, "edit", budget)
        if #errors > 0 and #files == 0 then
            return nil, table.concat(errors, "; ")
        end
        return { files = files, omitted = omitted, errors = errors, is_dir = true, dir = abs }, nil
    end
    if util.path_exists_as_file(abs) then
        local ok, content_or_err = util.read_text_file(abs, max_bytes)
        if not ok then
            return nil,
                content_or_err
                    .. " (# edit needs the full file — raise max_file_bytes, or split the file)"
        end
        if seen then
            seen[abs] = true
        end
        return {
            files = { { path = abs, content = content_or_err, is_new = false, raw = raw } },
            omitted = {},
            errors = {},
            is_dir = false,
        },
            nil
    end
    local parent = abs:match("^(.*)[/\\][^/\\]+$")
    if parent and parent ~= "" and not util.path_exists_as_dir(parent) then
        return nil, "cannot create file — parent directory missing: " .. parent
    end
    if seen then
        seen[abs] = true
    end
    return {
        files = { { path = abs, content = "", is_new = true, raw = raw } },
        omitted = {},
        errors = {},
        is_dir = false,
    },
        nil
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
        elseif syn:match("^kube:") then
            local kubemod = require("kube")
            local content, kerr = kubemod.collect_attach(syn, config)
            -- Lua: only nil/false are falsy — treat "" as success (no error).
            if kerr and kerr ~= "" then
                table.insert(errors, "@" .. syn .. " failed: " .. kerr)
            elseif content == nil then
                table.insert(errors, "@" .. syn .. " failed: empty attach")
            else
                table.insert(blocks, {
                    label = "Kube " .. (syn:match("^kube:(.+)$") or syn),
                    path = "@" .. syn,
                    content = content,
                })
                table.insert(labels, "@" .. syn)
            end
        elseif syn:match("^tf:") then
            local tok, tfmod = pcall(require, "tf")
            if not tok then
                table.insert(errors, "@" .. syn .. " failed: tf module not loaded (update wezai plugin)")
            elseif not cwd then
                table.insert(errors, "@" .. syn .. " needs pane cwd")
            else
                local content, terr = tfmod.collect_attach(syn, cwd, config)
                if terr and terr ~= "" then
                    table.insert(errors, "@" .. syn .. " failed: " .. terr)
                elseif content == nil then
                    table.insert(errors, "@" .. syn .. " failed: empty attach")
                else
                    table.insert(blocks, {
                        label = "Terraform " .. (syn:match("^tf:(.+)$") or syn),
                        path = "@" .. syn,
                        content = content,
                    })
                    table.insert(labels, "@" .. syn)
                end
            end
        elseif syn:match("^docker:") then
            local dok, dmod = pcall(require, "docker")
            if not dok then
                table.insert(errors, "@" .. syn .. " failed: docker module not loaded (update wezai plugin)")
            else
                local content, derr = dmod.collect_attach(syn, cwd, config)
                if derr and derr ~= "" then
                    table.insert(errors, "@" .. syn .. " failed: " .. derr)
                elseif content == nil then
                    table.insert(errors, "@" .. syn .. " failed: empty attach")
                else
                    table.insert(blocks, {
                        label = "Docker " .. (syn:match("^docker:(.+)$") or syn),
                        path = "@" .. syn,
                        content = content,
                    })
                    table.insert(labels, "@" .. syn)
                end
            end
        elseif syn == "weather" or syn:match("^weather:") then
            local wok, wmod = pcall(require, "weather")
            if not wok then
                table.insert(errors, "@" .. syn .. " failed: weather module not loaded (update wezai plugin)")
            else
                local content, werr = wmod.collect_attach(syn, config)
                if werr and werr ~= "" then
                    table.insert(errors, "@" .. syn .. " failed: " .. werr)
                elseif content == nil then
                    table.insert(errors, "@" .. syn .. " failed: empty attach")
                else
                    table.insert(blocks, {
                        label = "Weather " .. (syn:match("^weather:(.+)$") or "now"),
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

local function pin_resolved(window, recs, kind, cwd)
    for _, f in ipairs(recs or {}) do
        if f.path and not tostring(f.path):match("^@") then
            session.pin(window, {
                path = f.from_dir or f.path,
                kind = kind,
                raw = display_name(f.from_dir or f.path, cwd),
                is_dir = f.from_dir ~= nil,
            })
        end
    end
end

local function merge_session_pins(window, parsed, cwd)
    local pins = session.list_pins(window)
    local path_set = {}
    local edit_set = {}
    for _, p in ipairs(parsed.paths) do
        path_set[p] = true
    end
    for _, p in ipairs(parsed.edit_paths) do
        edit_set[p] = true
    end
    for _, pin in ipairs(pins) do
        local raw = pin.raw or pin.path
        if pin.kind == "edit" then
            if not edit_set[raw] and not edit_set[pin.path] then
                parsed.edit_paths[#parsed.edit_paths + 1] = pin.path
                edit_set[pin.path] = true
            end
        else
            if not path_set[raw] and not path_set[pin.path] then
                parsed.paths[#parsed.paths + 1] = pin.path
                path_set[pin.path] = true
            end
        end
    end
    return parsed
end

local function token_report(files, synth_blocks, extra_text, config)
    local n = 0
    for _, f in ipairs(files or {}) do
        n = n + M.estimate_tokens(f.content or "", config)
    end
    for _, f in ipairs(synth_blocks or {}) do
        n = n + M.estimate_tokens(f.content or "", config)
    end
    n = n + M.estimate_tokens(extra_text or "", config)
    return n
end

local function confirm_needed(tokens, config)
    local o = ctx_opts(config)
    if tokens >= o.confirm_tokens then
        return true,
            string.format(
                "Large context: ~%d tokens (warn %d / confirm %d / max %d). Send anyway?",
                tokens,
                o.warn_tokens,
                o.confirm_tokens,
                o.max_prompt_tokens
            )
    end
    return false, nil
end

function M.prepare_request(window, pane, line, selection, config)
    local cwd = util.get_pane_cwd(pane)
    local max_bytes = config.max_file_bytes or 100000
    local parsed = M.parse_at_refs(line or "")
    local new_attach = #parsed.paths > 0
    local new_edit = #parsed.edit_paths > 0
    local seen = {}
    local budget = { tokens_left = ctx_opts(config).max_prompt_tokens }
    local omitted_all = {}

    -- New refs on this line pin for the rest of the session (until Clear).
    parsed = merge_session_pins(window, parsed, cwd)

    local synth_blocks, synth_errors, synth_labels = resolve_synthetics(parsed.synthetics, window, pane, cwd, config)
    if #synth_errors > 0 and #parsed.edit_paths == 0 and #parsed.paths == 0 and not selection and parsed.rest == "" then
        return nil, table.concat(synth_errors, "; ")
    end

    -- Sticky selection / extra context from this tab (cleared by Compact).
    if selection and selection ~= "" then
        local selected_file = selection_as_file_path(selection, cwd)
        if not selected_file then
            session.add_ephemeral(window, "Selected text", selection)
        end
    end

    if #parsed.edit_paths > 0 or session.has_edit_pins(window) then
        local instruction = parsed.rest
        local has_instruction = instruction and not instruction:match("^%s*$")

        local targets = {}
        local target_errors = {}
        local is_new_any = false
        for _, raw in ipairs(parsed.edit_paths) do
            if raw ~= "pick" then
                local pack, target_err = resolve_edit_target(raw, cwd, max_bytes, config, seen, budget)
                if not pack then
                    table.insert(target_errors, target_err)
                else
                    for _, f in ipairs(pack.files or {}) do
                        f.is_new = f.is_new == true
                        if f.is_new then
                            is_new_any = true
                        end
                        targets[#targets + 1] = f
                    end
                    for _, o in ipairs(pack.omitted or {}) do
                        omitted_all[#omitted_all + 1] = o
                    end
                    local pin_path = pack.dir or ((pack.files[1] and pack.files[1].path) or nil)
                    if pin_path then
                        session.pin(window, {
                            path = pin_path,
                            kind = "edit",
                            raw = display_name(pin_path, cwd),
                            is_dir = pack.is_dir == true,
                        })
                    end
                end
            end
        end
        if #target_errors > 0 and #targets == 0 then
            return nil, table.concat(target_errors, "; ")
        end

        local context_files, ctx_errors, _, ctx_omit
        context_files, ctx_errors, seen, ctx_omit =
            resolve_and_read_files(parsed.paths, cwd, max_bytes, seen, config, "attach", budget)
        if #ctx_errors > 0 then
            return nil, table.concat(ctx_errors, "; ")
        end
        for _, o in ipairs(ctx_omit or {}) do
            omitted_all[#omitted_all + 1] = o
        end
        if #synth_errors > 0 then
            return nil, table.concat(synth_errors, "; ")
        end

        pin_resolved(window, context_files, "attach", cwd)

        local selected_file = selection_as_file_path(selection, cwd)
        if selected_file and not seen[selected_file] then
            local ok, content_or_err, meta = util.read_text_file_smart(selected_file, attach_read_opts(config, max_bytes))
            if not ok then
                return nil, content_or_err
            end
            table.insert(context_files, {
                path = selected_file,
                content = content_or_err,
                truncated = meta and meta.truncated,
                size = meta and meta.size,
            })
            seen[selected_file] = true
            session.pin(window, {
                path = selected_file,
                kind = "attach",
                raw = display_name(selected_file, cwd),
            })
        end

        -- Pin-only: #file or #dir with no instruction yet (this line introduced refs).
        if not has_instruction then
            if new_edit or new_attach then
                if #targets == 0 and #context_files == 0 and #synth_blocks == 0 then
                    return nil, nil
                end
                return {
                    mode = "pin",
                    files = (function()
                        local all = {}
                        for _, f in ipairs(targets) do
                            all[#all + 1] = f
                        end
                        for _, f in ipairs(context_files) do
                            all[#all + 1] = f
                        end
                        return all
                    end)(),
                    user_text = "",
                    attach_labels = synth_labels,
                    omitted = omitted_all,
                },
                    nil
            end
            -- Existing # pins + empty follow-up: remind, don't call the model.
            return {
                mode = "pin",
                files = (function()
                    local all = {}
                    for _, f in ipairs(targets) do
                        all[#all + 1] = f
                    end
                    for _, f in ipairs(context_files) do
                        all[#all + 1] = f
                    end
                    return all
                end)(),
                user_text = "",
                attach_labels = synth_labels,
                omitted = omitted_all,
            },
                nil
        end

        if #targets == 0 then
            return nil, "no # edit targets resolved"
        end

        local parts = {}
        for _, target in ipairs(targets) do
            if target.is_new then
                table.insert(
                    parts,
                    "Create target (file does not exist yet). Write the COMPLETE new file contents "
                        .. "in JSON files[].content (or file if this is the only target):\n"
                        .. "File: "
                        .. target.path
                        .. "\n```\n```"
                )
            else
                table.insert(
                    parts,
                    "Edit target (rewrite this file completely):\n"
                        .. "File: "
                        .. target.path
                        .. "\n```\n"
                        .. target.content
                        .. "\n```"
                )
            end
        end
        if #context_files > 0 then
            for _, f in ipairs(context_files) do
                f.label = "Read-only context"
            end
            table.insert(parts, build_files_section(context_files))
        end
        if #synth_blocks > 0 then
            table.insert(parts, build_files_section(synth_blocks))
        end
        for _, eph in ipairs(session.list_ephemeral(window)) do
            table.insert(parts, (eph.label or "Context") .. ":\n```\n" .. eph.content .. "\n```")
        end
        if #omitted_all > 0 then
            table.insert(
                parts,
                "Omitted from this turn (token/size budget): " .. table.concat(omitted_all, ", ")
            )
        end
        table.insert(parts, "Modification requested:\n" .. instruction)

        local all_files = {}
        for _, f in ipairs(targets) do
            table.insert(all_files, f)
        end
        for _, f in ipairs(context_files) do
            table.insert(all_files, f)
        end
        for _, f in ipairs(synth_blocks) do
            table.insert(all_files, f)
        end

        local prompt = M.redact(table.concat(parts, "\n\n"))
        local tokens = token_report(all_files, nil, instruction, config)
        local needs, confirm_msg = confirm_needed(tokens, config)

        return {
            mode = "edit",
            prompt = prompt,
            files = all_files,
            targets = targets,
            target_path = targets[1] and targets[1].path,
            original_content = targets[1] and targets[1].content,
            is_new = is_new_any,
            user_text = instruction,
            attach_labels = synth_labels,
            omitted = omitted_all,
            token_estimate = tokens,
            needs_confirm = needs,
            confirm_message = confirm_msg,
        },
            nil
    end

    -- Ask mode
    if #synth_errors > 0 then
        return nil, table.concat(synth_errors, "; ")
    end

    local selected_file = selection_as_file_path(selection, cwd)
    local selection_text = nil
    local path_list = {}
    for _, raw in ipairs(parsed.paths) do
        path_list[#path_list + 1] = raw
    end
    if selected_file then
        path_list[#path_list + 1] = selected_file
    elseif selection then
        selection_text = selection
    end

    local file_list, errors, _, omit
    file_list, errors, seen, omit = resolve_and_read_files(path_list, cwd, max_bytes, seen, config, "attach", budget)
    if #errors > 0 then
        return nil, table.concat(errors, "; ")
    end
    for _, o in ipairs(omit or {}) do
        omitted_all[#omitted_all + 1] = o
    end

    pin_resolved(window, file_list, "attach", cwd)
    if selected_file then
        session.pin(window, {
            path = selected_file,
            kind = "attach",
            raw = display_name(selected_file, cwd),
        })
    end

    local question = parsed.rest
    local eph = session.list_ephemeral(window)
    local has_files = #file_list > 0 or #synth_blocks > 0
    local has_selection_text = selection_text ~= nil or #eph > 0
    local has_question = question and not question:match("^%s*$")

    if not has_files and not has_selection_text and not has_question then
        return nil, nil
    end

    -- Pin-only attach (e.g. @src/) with no question: remember files, don't call the model.
    if has_files and not has_question and not has_selection_text then
        if new_attach or new_edit then
            return {
                mode = "pin",
                files = file_list,
                user_text = "",
                attach_labels = synth_labels,
                omitted = omitted_all,
            },
                nil
        end
        -- Existing @ pins + empty follow-up → explain attached files.
        question = M.DEFAULT_FILE_INSTRUCTION
        has_question = true
    end

    local parts = {}
    if #file_list > 0 then
        table.insert(parts, build_files_section(file_list))
    end
    if #synth_blocks > 0 then
        table.insert(parts, build_files_section(synth_blocks))
    end
    if selection_text then
        table.insert(parts, "Selected text:\n```\n" .. selection_text .. "\n```")
    end
    for _, e in ipairs(eph) do
        if not selection_text or e.label ~= "Selected text" then
            table.insert(parts, (e.label or "Context") .. ":\n```\n" .. e.content .. "\n```")
        end
    end
    if #omitted_all > 0 then
        table.insert(parts, "Omitted from this turn (token/size budget): " .. table.concat(omitted_all, ", "))
    end
    if has_question then
        table.insert(parts, question)
    elseif has_files then
        table.insert(parts, M.DEFAULT_FILE_INSTRUCTION)
    elseif has_selection_text then
        table.insert(parts, M.DEFAULT_SELECTION_INSTRUCTION)
    end

    local all = {}
    for _, f in ipairs(file_list) do
        table.insert(all, f)
    end
    for _, f in ipairs(synth_blocks) do
        table.insert(all, f)
    end

    local prompt = M.redact(table.concat(parts, "\n\n"))
    local tokens = token_report(all, nil, question, config)
    local needs, confirm_msg = confirm_needed(tokens, config)

    return {
        mode = "ask",
        prompt = prompt,
        files = all,
        user_text = question,
        attach_labels = synth_labels,
        omitted = omitted_all,
        token_estimate = tokens,
        needs_confirm = needs,
        confirm_message = confirm_msg,
    },
        nil
end

function M.selection_as_file_path(selection, cwd)
    return selection_as_file_path(selection, cwd)
end

return M
