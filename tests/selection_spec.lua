-- Tests for `rewriter.selection`: the columns a selection covers and the text
-- written back into them.

local selection = require("rewriter.selection")

test("capture reads a charwise selection mid-line", function()
  helper.buffer({ "abcdefghij" })
  helper.select(0, 2, "vlll")

  local region = selection.capture()
  eq(region.mode, "v", "mode")
  eq(region.text, "cdef", "text")
  eq(region.start_row, 0, "start_row")
  eq(region.start_col, 2, "start_col")
  eq(region.end_row, 0, "end_row")
  eq(region.end_col, 6, "end_col")
end)

test("replace writes a charwise selection in place", function()
  local buf = helper.buffer({ "abcdefghij" })
  helper.select(0, 2, "vlll")

  selection.replace(selection.capture(), { "XY" })
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "abXYghij" })
end)

test("replace writes a multi-line charwise selection in place", function()
  local buf = helper.buffer({ "abcdefghij", "klmnopqrst", "uvwxyz" })
  helper.select(0, 2, "vjj")

  local region = selection.capture()
  eq(region.text, "cdefghij\nklmnopqrst\nuvw", "text")
  eq(region.start_row, 0, "start_row")
  eq(region.start_col, 2, "start_col")
  eq(region.end_row, 2, "end_row")
  eq(region.end_col, 3, "end_col")
  selection.replace(region, { "Z" })
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "abZxyz" })
end)

test("replace writes a linewise selection in place", function()
  local buf = helper.buffer({ "aaa", "bbb", "ccc" })
  helper.select(0, 0, "Vj")

  local region = selection.capture()
  eq(region.mode, "V", "mode")
  eq(region.text, "aaa\nbbb", "text")
  eq(region.start_row, 0, "start_row")
  eq(region.end_row, 1, "end_row")
  selection.replace(region, { "x", "y" })
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "x", "y", "ccc" })
end)

test("capture honors 'selection=exclusive'", function()
  local saved = vim.o.selection
  vim.o.selection = "exclusive"

  local buf = helper.buffer({ "abcdefghij" })
  helper.select(0, 2, "vlll")

  local region = selection.capture()
  eq(region.text, "cde", "text")
  selection.replace(region, { "XY" })
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "abXYfghij" })

  vim.o.selection = saved
end)

test("capture rejects a blockwise selection", function()
  helper.buffer({ "abcd", "abcd" })
  helper.select(0, 1, "\22jl")

  local region, err = selection.capture()
  is_nil(region, "region")
  ok(err:match("blockwise"), "error should name the block: " .. tostring(err))
end)

test("capture reports a missing selection", function()
  helper.buffer({ "abcdefghij" })

  local region, err = selection.capture()
  is_nil(region, "region")
  ok(err:match("no selection"), "error should say how to select: " .. tostring(err))
end)
