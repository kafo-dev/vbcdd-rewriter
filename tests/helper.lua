-- Helpers shared by the specs.

local H = {}

--- Opens a scratch buffer holding `lines` and returns its number.
--- @param lines string[]
--- @return integer
function H.buffer(lines)
  vim.cmd("enew!")

  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

--- Puts the cursor on a 0-based `row` and `col`, then runs the visual-mode
--- keys `keys` and leaves visual mode, the way a `:'<,'>` command finds its
--- marks.
--- @param row integer
--- @param col integer
--- @param keys string
function H.select(row, col, keys)
  vim.api.nvim_win_set_cursor(0, { row + 1, col })
  vim.fn.feedkeys(keys .. "\27", "x")
end

--- Runs the callbacks `vim.schedule` queued, the way the main loop does.
function H.drain()
  vim.wait(20, function()
    return false
  end)
end

--- Buffers the lines of the current buffer.
--- @return string[]
function H.lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

--- Collects the messages `vim.notify` receives while `fn` runs.
--- @param fn function
--- @return table[]
function H.notices(fn)
  local saved = vim.notify
  local collected = {}
  vim.notify = function(msg, level)
    collected[#collected + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(fn)
  vim.notify = saved
  if not ok then
    error(err, 0)
  end
  return collected
end

--- Reports whether any collected message matches `pattern`.
--- @param collected table[]
--- @param pattern string
--- @return boolean
function H.any_match(collected, pattern)
  for _, notice in ipairs(collected) do
    if notice.msg:match(pattern) then
      return true
    end
  end
  return false
end

return H
