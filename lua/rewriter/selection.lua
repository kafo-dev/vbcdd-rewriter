--- Reads the visual selection and writes replacement lines back.

local M = {}

--- Blockwise selections carry one string per line and a width per column.
local BLOCKWISE = 22

--- Reads marks `'<` and `'>`, the bounds a `:'<,'>` command leaves behind.
--- The marks stay buffer-local, so a missing mark reads as line 0.
--- @return integer[]|nil startpos
--- @return integer[]|nil endpos
--- @return string|nil err
local function marks()
  local start = vim.fn.getpos("'<")
  local stop = vim.fn.getpos("'>")

  if start[2] == 0 or stop[2] == 0 then
    return nil, nil, "no selection: select text with v or V, then run the command"
  end

  assert(start[2] >= 1, "start line must be within the buffer")
  assert(stop[2] >= start[2], "the end mark must not precede the start mark")
  return start, stop
end

--- Captures the selection. Column 1 is the first byte; `end_col` counts as an
--- exclusive 0-based bound, the form `nvim_buf_set_text` expects.
--- @return table|nil region
--- @return string|nil err
function M.capture()
  local buf = vim.api.nvim_get_current_buf()
  local mode = vim.fn.visualmode()

  if mode == "" then
    return nil, "no selection: select text with v or V, then run the command"
  end
  if mode:byte(1) == BLOCKWISE then
    return nil, "a blockwise selection (:h blockwise-visual) is not supported"
  end

  local start, stop, err = marks()
  if not start then
    return nil, err
  end

  local bounds = vim.fn.getregionpos(start, stop, {
    type = mode,
    bounds = true,
    eol = false,
  })[1]
  local lines = vim.fn.getregion(start, stop, { type = mode })

  assert(#lines >= 1, "a selection carries at least one line")
  assert(#bounds == 2, "bounds carries a start and an end position")

  return {
    buf = buf,
    mode = mode,
    start_row = bounds[1][2] - 1,
    start_col = bounds[1][3] - 1,
    end_row = bounds[2][2] - 1,
    end_col = bounds[2][3],
    text = table.concat(lines, "\n"),
  }
end

--- Replaces the captured region with `lines`.
--- @param region table
--- @param lines string[]
function M.replace(region, lines)
  assert(region.buf ~= nil, "region must name a buffer")
  assert(type(lines) == "table" and #lines >= 1, "lines must be a non-empty list")
  assert(vim.api.nvim_buf_is_valid(region.buf), "the buffer must still exist")

  if region.mode == "V" then
    vim.api.nvim_buf_set_lines(region.buf, region.start_row, region.end_row + 1, false, lines)
    return
  end

  vim.api.nvim_buf_set_text(region.buf, region.start_row, region.start_col, region.end_row, region.end_col, lines)
end

return M
