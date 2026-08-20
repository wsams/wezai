-- Tests for plugin/history_store.lua. Run: lua scripts/test_history.lua
package.path = "./plugin/?.lua;./plugin/?/init.lua;" .. package.path

local store = require("history_store")

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

-- bash timestamps + unique newest-first
local bash = table.concat({
    "#1000",
    "echo old",
    "#2000",
    "ls",
    "#3000",
    "echo old",
    "#4000",
    "git status",
    "#5000",
    "ls",
}, "\n") .. "\n"

local bash_newest = store.unique_text("bash", bash, 10)
eq(#bash_newest, 3, "bash unique count")
eq(bash_newest[1], "ls", "bash newest is last unique")
eq(bash_newest[2], "git status", "bash second")
eq(bash_newest[3], "echo old", "bash oldest unique")

local bash_cap = store.unique_text("bash", bash, 2)
eq(#bash_cap, 2, "bash cap")
eq(bash_cap[1], "ls", "bash cap newest")

-- zsh extended history
local zsh = table.concat({
    ": 1000:0;echo old",
    ": 2000:0;ls",
    ": 3000:0;echo old",
    ": 4000:0;git status",
}, "\n") .. "\n"
local zsh_newest = store.unique_text("zsh", zsh, 10)
eq(#zsh_newest, 3, "zsh unique count")
eq(zsh_newest[1], "git status", "zsh newest")
eq(zsh_newest[2], "echo old", "zsh unique echo")
eq(zsh_newest[3], "ls", "zsh ls")

-- fish yaml
local fish = [[
- cmd: echo old
  when: 1000
- cmd: git status
  when: 2000
  paths:
    - /tmp
- cmd: echo old
  when: 3000
- cmd: docker compose up
  when: 4000
]]
local fish_newest = store.unique_text("fish", fish, 10)
eq(#fish_newest, 3, "fish unique count")
eq(fish_newest[1], "docker compose up", "fish newest")
eq(fish_newest[2], "echo old", "fish echo unique")
eq(fish_newest[3], "git status", "fish git")

local fish_esc = "- cmd: echo hello\\nworld\n  when: 1\n"
local fish_un = store.parse_fish_commands(fish_esc)
eq(fish_un[1], "echo hello\nworld", "fish unescape newline")

-- bash strip keeps timestamps of kept lines, drops timestamps of deleted
local stripped, n = store.strip_bash_exact(bash, "echo old")
eq(n, 2, "bash strip count")
expect(not stripped:find("echo old", 1, true), "bash strip removed cmd")
expect(stripped:find("git status", 1, true) ~= nil, "bash strip kept git")
expect(stripped:find("#4000", 1, true) ~= nil, "bash strip kept ts of kept cmd")
expect(stripped:find("#1000", 1, true) == nil, "bash strip dropped ts of deleted")

local zstripped, zn = store.strip_zsh_exact(zsh, "echo old")
eq(zn, 2, "zsh strip count")
expect(not zstripped:find("echo old", 1, true), "zsh strip removed")
expect(zstripped:find("git status", 1, true) ~= nil, "zsh strip kept")

local fstripped, fn = store.strip_fish_exact(fish, "echo old")
eq(fn, 2, "fish strip count")
expect(not fstripped:find("echo old", 1, true), "fish strip removed")
expect(fstripped:find("docker compose up", 1, true) ~= nil, "fish strip kept docker")
expect(fstripped:find("git status", 1, true) ~= nil, "fish strip kept git")

-- fuzzy: token subsequence
local cmds = {
    "docker compose up -d",
    "git status",
    "ls -la /tmp",
    "docker ps",
    "systemctl restart docker",
}
local hits = store.fuzzy_filter(cmds, "dckr up", 10)
eq(hits[1], "docker compose up -d", "fuzzy docker compose first")

local hits2 = store.fuzzy_filter(cmds, "git st", 10)
eq(hits2[1], "git status", "fuzzy git status")

local hits3 = store.fuzzy_filter(cmds, "no-such-token-xyz", 10)
eq(#hits3, 0, "fuzzy no match")

-- tens of thousands: unique + fuzzy stay snappy
local big = {}
for i = 1, 30000 do
    -- lots of duplicates + unique tail
    if i % 3 == 0 then
        big[#big + 1] = "echo repeated"
    else
        big[#big + 1] = string.format("cmd-%05d arg", i)
    end
end
big[#big + 1] = "docker compose exec web bash"
local blob = table.concat(big, "\n") .. "\n"
local t0 = os.clock()
local uniq = store.unique_text("bash", blob, 20000)
local t1 = os.clock()
expect(#uniq >= 10000, "big unique has many entries got " .. tostring(#uniq))
eq(uniq[1], "docker compose exec web bash", "big unique newest")
expect(t1 - t0 < 1.5, "unique 30k lines < 1.5s got " .. tostring(t1 - t0))

local t2 = os.clock()
local found = store.fuzzy_filter(uniq, "dckr exec", 20)
local t3 = os.clock()
eq(found[1], "docker compose exec web bash", "fuzzy among 20k")
expect(t3 - t2 < 1.0, "fuzzy 20k < 1s got " .. tostring(t3 - t2))

-- Cross-check Lua rewrite vs history_edit.py
local function write_tmp(name, body)
    local path = os.tmpname() .. "-" .. name
    local f = io.open(path, "wb")
    f:write(body)
    f:close()
    return path
end

local function python_strip(kind, text, cmd)
    local hist = write_tmp("hist", text)
    local cmdf = write_tmp("cmd", cmd)
    local py = "python3 plugin/history_edit.py " .. kind .. " " .. hist .. " " .. cmdf
    local h = io.popen(py)
    local out = h:read("*a") or ""
    h:close()
    local f = io.open(hist, "rb")
    local new_text = f:read("*a") or ""
    f:close()
    os.remove(hist)
    os.remove(cmdf)
    return new_text, tonumber(store.trim(out)) or -1
end

local lua_b, ln = store.strip_bash_exact(bash, "echo old")
local py_b, pn = python_strip("bash", bash, "echo old")
eq(ln, pn, "lua/py bash count")
eq(lua_b, py_b, "lua/py bash body")

local lua_z, lzn = store.strip_zsh_exact(zsh, "echo old")
local py_z, pzn = python_strip("zsh", zsh, "echo old")
eq(lzn, pzn, "lua/py zsh count")
eq(lua_z, py_z, "lua/py zsh body")

local lua_f, lfn = store.strip_fish_exact(fish, "echo old")
local py_f, pfn = python_strip("fish", fish, "echo old")
eq(lfn, pfn, "lua/py fish count")
eq(lua_f, py_f, "lua/py fish body")

print(string.format("test_history: %d passed, %d failed", passed, failed))
if failed > 0 then
    os.exit(1)
end
