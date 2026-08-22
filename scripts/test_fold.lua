-- Tests for plugin/fold.lua. Run: lua scripts/test_fold.lua
package.path = "./plugin/?.lua;./plugin/?/init.lua;" .. package.path

local fold = require("fold")

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

-- short question is unchanged
local short, meta = fold.fold_text("how do I list listening ports?")
eq(short, "how do I list listening ports?", "short body")
expect(meta.folded == false, "short not folded")
eq(meta.lines, 1, "short line count")
eq(meta.shown_lines, 1, "short shown")

-- empty
local empty, empty_meta = fold.fold_text("")
eq(empty, "", "empty body")
expect(empty_meta.folded == false, "empty not folded")
eq(empty_meta.lines, 0, "empty lines")

-- many lines: keep first max_lines, note the rest
local lines = {}
for i = 1, 12 do
    lines[i] = "line " .. tostring(i)
end
local long = table.concat(lines, "\n")
local folded, fmeta = fold.fold_text(long, { max_lines = 4, max_chars = 10000, max_line_chars = 200 })
expect(fmeta.folded == true, "12 lines folded")
eq(fmeta.lines, 12, "12 line count")
eq(fmeta.shown_lines, 4, "kept 4 lines")
expect(folded:find("line 1", 1, true) ~= nil, "keeps first line")
expect(folded:find("line 4", 1, true) ~= nil, "keeps fourth line")
expect(folded:find("line 5", 1, true) == nil, "hides fifth line")
expect(folded:find("… folded 8 more lines", 1, true) ~= nil, "fold note has hidden count")
expect(folded:find("(" .. tostring(#long) .. " chars)", 1, true) ~= nil, "fold note has char count")

-- one extra line uses singular
local five = "a\nb\nc\nd\ne"
local one_more = fold.fold_text(five, { max_lines = 4, max_chars = 10000, max_line_chars = 200 })
expect(one_more:find("… folded 1 more line (", 1, true) ~= nil, "singular more line")

-- long single line
local blob = string.rep("x", 80)
local clipped, cmeta = fold.fold_text(blob, { max_lines = 8, max_chars = 10000, max_line_chars = 20 })
expect(cmeta.folded == true, "long line folded")
eq(cmeta.shown_lines, 1, "long line still one shown")
expect(clipped:find("… folded (", 1, true) ~= nil, "long line fold note")
expect(clipped:find(string.rep("x", 20) .. "…", 1, true) == 1, "long line clipped")

-- char budget mid-text
local para = "hello world this is a longer question"
local by_chars, chmeta = fold.fold_text(para, { max_lines = 8, max_chars = 11, max_line_chars = 200 })
expect(chmeta.folded == true, "char budget folded")
expect(by_chars:find("^hello world…") ~= nil, "char budget prefix")

-- disable all limits
local unlimited = fold.fold_text(long, { max_lines = 0, max_chars = 0, max_line_chars = 0 })
eq(unlimited, long, "zero limits keep full text")

-- CR LF normalized
local crlf, crmeta = fold.fold_text("one\r\ntwo\r\nthree", { max_lines = 10, max_chars = 1000, max_line_chars = 200 })
eq(crlf, "one\ntwo\nthree", "crlf normalized")
expect(crmeta.folded == false, "crlf not folded")
eq(crmeta.lines, 3, "crlf line count")

if failed > 0 then
    io.stderr:write(string.format("%d failed, %d passed\n", failed, passed))
    os.exit(1)
end
print(string.format("ok — %d passed", passed))
