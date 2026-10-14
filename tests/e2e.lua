#!/usr/bin/env nvim --headless -u NONE -l

-- End-to-end run against a real `pi`, kept out of the check because it needs
-- the network and a configured provider:
--
--   REWRITER_E2E=1 nvim --headless -u NONE -l tests/e2e.lua
--
-- Prints the buffer after the rewrite and exits non-zero when the rewrite
-- fails or leaves the selection untouched.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

if vim.env.REWRITER_E2E ~= "1" then
  print("e2e: skipped; set REWRITER_E2E=1 to run")
  os.exit(0)
end

dofile(root .. "/plugin/rewriter.lua")
require("rewriter").setup({})

local SOURCE = "The cat sat on the mat."

vim.cmd("enew!")
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { SOURCE })
vim.api.nvim_win_set_cursor(0, { 1, 0 })

local finished = false
local messages = {}
vim.notify = function(msg, level)
  messages[#messages + 1] = msg
  if level == vim.log.levels.ERROR then
    finished = true
  end
  if msg:match("done$") then
    finished = true
  end
end

vim.fn.feedkeys("V\27", "x")
vim.cmd("'<,'>Rewrite paraphrase this sentence")

if not vim.wait(180000, function()
  return finished
end, 200) then
  print("e2e: the rewrite did not finish")
  os.exit(1)
end

local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
print("e2e: " .. table.concat(messages, " | "))

if lines[1] == SOURCE then
  print("e2e: the selection was not replaced")
  os.exit(1)
end

print("e2e: " .. table.concat(lines, "\n"))
os.exit(0)
