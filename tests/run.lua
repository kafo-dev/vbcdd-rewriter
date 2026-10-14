#!/usr/bin/env nvim --headless -u NONE -l

-- Test driver: loads every `tests/*_spec.lua` and exits non-zero when a test
-- fails.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local tests = {}
local failures = 0
local passed = 0

--- Registers a test. Each spec file calls this at load time.
--- @param name string
--- @param fn function
function _G.test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

--- Fails the test when two values differ.
--- @param actual any
--- @param expected any
--- @param label string|nil
function _G.eq(actual, expected, label)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", label or "value", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

--- Fails the test when the value is falsy.
--- @param value any
--- @param label string
function _G.ok(value, label)
  if not value then
    error("expected truthy: " .. label, 2)
  end
end

--- Fails the test when the value is not nil.
--- @param value any
--- @param label string
function _G.is_nil(value, label)
  if value ~= nil then
    error(string.format("%s: expected nil, got %s", label, vim.inspect(value)), 2)
  end
end

-- The assertion helpers above and `tests/helper.lua` live on `_G`, because a
-- spec file runs as its own chunk through `dofile`.
_G.helper = dofile(root .. "/tests/helper.lua")

-- Stdout stays readable: `helper.notices` collects the messages one test
-- cares about, and every other message is dropped.
vim.notify = function() end

dofile(root .. "/plugin/rewriter.lua")

local specs = vim.fn.glob(root .. "/tests/*_spec.lua", false, true)
table.sort(specs)

for _, spec in ipairs(specs) do
  dofile(spec)
end

for _, case in ipairs(tests) do
  local ok, err = pcall(case.fn)
  if ok then
    passed = passed + 1
  else
    failures = failures + 1
    io.stderr:write(string.format("FAIL %s: %s\n", case.name, tostring(err)))
  end
end

print(string.format("%d passed, %d failed, %d total", passed, failures, #tests))
os.exit(failures == 0 and 0 or 1)
