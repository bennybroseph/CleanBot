-- ============================================================
-- spec/framework.lua  —  Tiny busted-style test harness.
--
-- Provides a deliberately small subset of busted's API (describe / it / assert.*) so
-- specs read like busted specs and can migrate to real busted later with no changes.
-- No external dependencies — runs under a bare Lua 5.1 / LuaJIT interpreter.
-- ============================================================

local results   = { passed = 0, failed = 0, failures = {} }
local nameStack = {}

--- Groups related tests; nesting is allowed and reflected in failure names.
function describe(name, fn)
    nameStack[#nameStack + 1] = name
    fn()
    nameStack[#nameStack] = nil
end

local function fullName(name)
    local parts = {}
    for _, n in ipairs(nameStack) do parts[#parts + 1] = n end
    parts[#parts + 1] = name
    return table.concat(parts, " › ")
end

--- Runs one test case, recording pass/fail (a thrown error = fail).
function it(name, fn)
    local ok, err = pcall(fn)
    if ok then
        results.passed = results.passed + 1
        io.write(".")
    else
        results.failed = results.failed + 1
        results.failures[#results.failures + 1] = { name = fullName(name), err = tostring(err) }
        io.write("F")
    end
end

local function deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
    for k in pairs(b)     do if a[k] == nil          then return false end end
    return true
end

local function fail(msg) error(msg, 3) end

-- busted-like assert table. Kept callable so the builtin `assert(v, msg)` still works.
local builtin = assert
local A = setmetatable({}, { __call = function(_, v, msg) return builtin(v, msg) end })
A.are = {}
function A.are.equal(expected, actual, msg)
    if expected ~= actual then
        fail((msg or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
    end
end
function A.are.same(expected, actual, msg)
    if not deepEqual(expected, actual) then fail(msg or "tables are not deeply equal") end
end
A.equals = A.are.equal
A.same   = A.are.same
function A.is_nil(v, msg)     if v ~= nil   then fail((msg or "expected nil, got ") .. tostring(v)) end end
function A.is_not_nil(v, msg) if v == nil   then fail(msg or "expected a non-nil value") end end
function A.is_true(v, msg)    if v ~= true  then fail((msg or "expected true, got ") .. tostring(v)) end end
function A.is_false(v, msg)   if v ~= false then fail((msg or "expected false, got ") .. tostring(v)) end end
_G.assert = A

--- Prints the summary and exits non-zero if anything failed (for CI).
function _RUN_FINISH()
    io.write("\n")
    for _, f in ipairs(results.failures) do
        io.write("\nFAIL: " .. f.name .. "\n      " .. f.err .. "\n")
    end
    io.write(string.format("\n%d passed, %d failed\n", results.passed, results.failed))
    os.exit(results.failed > 0 and 1 or 0)
end
