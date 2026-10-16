--- `:Rewrite` — sends the visual selection to the OpenAI API and writes the
--- reply back in place.

local openai = require("rewriter.openai")
local selection = require("rewriter.selection")

local M = {}

M.config = {
  --- The `curl` executable. `exepath` picks up `curl` on `PATH`.
  curl_cmd = vim.fn.exepath("curl"),
  --- The key comes from the environment, so it stays out of the repository.
  api_key = vim.env.OPENAI_API_KEY or "",
  model = "gpt-4o-mini",
  --- Point this at another host to reach an OpenAI-compatible API.
  base_url = "https://api.openai.com/v1",
  --- The thinking level, sent as the API's `reasoning_effort`. Empty leaves
  --- the field out for a model without reasoning.
  reasoning_effort = "",
  --- Extra request headers, as `name = value`.
  extra_headers = {},
  --- Send the whole buffer ahead of the selection, so the model reads the
  --- text in place.
  file_context = false,
  timeout_ms = 120000,
  --- Cap on one request: the context, the instruction, and the selection.
  max_prompt_bytes = 100 * 1024,
  system_prompt = table.concat({
    "Rewrite text on request from a text editor.",
    "The message holds an instruction, a blank line, then the text to rewrite.",
    "Answer with the rewritten text only: no preamble, no commentary, no code fences, no quotes.",
    "Keep the text's language, and keep its Markdown and indentation, unless the instruction says otherwise.",
  }, " "),
}

--- `vim.system`, replaced by a fake in tests.
M.spawn = vim.system

--- Buffers with a request in flight. One request per buffer bounds the
--- process count.
local in_flight = {}

--- @param opts table|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

--- Reports a message through `vim.notify`.
--- @param msg string
--- @param level integer
local function notify(msg, level)
  vim.notify("rewrite: " .. msg, level)
end

--- Strips one trailing newline and splits the reply into lines.
--- @param stdout string
--- @return string[]
local function to_lines(stdout)
  assert(type(stdout) == "string", "stdout must be a string")

  local text = stdout
  if text:sub(-1) == "\n" then
    text = text:sub(1, -2)
  end

  local lines = vim.split(text, "\n", { plain = true })
  assert(#lines >= 1, "splitting text yields at least one line")
  return lines
end

--- Applies a finished reply. `vim.system` reports from a libuv callback, a
--- fast event context, so `vim.schedule` moves this onto the main loop, where
--- the buffer and register calls are allowed.
--- @param buf integer
--- @param region table
--- @param tick integer
--- @param stdout string|nil
--- @param failure string|nil
local function apply(buf, region, tick, stdout, failure)
  if not stdout then
    notify(failure, vim.log.levels.ERROR)
    return
  end

  local lines = to_lines(stdout)

  if not vim.api.nvim_buf_is_valid(buf) then
    notify('the buffer is gone; the reply is in register "', vim.log.levels.WARN)
    vim.fn.setreg('"', lines, "V")
    return
  end

  if vim.api.nvim_buf_get_changedtick(buf) ~= tick then
    vim.fn.setreg('"', lines, "V")
    notify('the buffer changed; the reply is in register "', vim.log.levels.WARN)
    return
  end

  selection.replace(region, lines)
  notify("done", vim.log.levels.INFO)
end

--- Reads the whole buffer as one string, the file the selection sits in.
--- @param buf integer
--- @return string
local function buffer_text(buf)
  assert(vim.api.nvim_buf_is_valid(buf), "the buffer must still exist")

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(#lines >= 1, "a buffer holds at least one line")

  return table.concat(lines, "\n")
end

--- The `:Rewrite` callback. Everything after the command names the work to do.
--- @param args table from `nvim_create_user_command`
function M.rewrite(args)
  assert(type(args) == "table", "args must be a table")

  local instruction = vim.trim(args.args or "")
  local buf = vim.api.nvim_get_current_buf()

  if in_flight[buf] then
    notify("a request is already running for this buffer", vim.log.levels.WARN)
    return
  end

  local region, err = selection.capture()
  if not region then
    notify(err, vim.log.levels.ERROR)
    return
  end

  local context = ""
  if M.config.file_context then
    context = openai.build_context(vim.api.nvim_buf_get_name(buf), buffer_text(buf))
  end

  local prompt
  prompt, err = openai.build_prompt(M.config, instruction, region.text, context)
  if not prompt then
    notify(err, vim.log.levels.ERROR)
    return
  end

  err = openai.validate(M.config)
  if err then
    notify(err, vim.log.levels.ERROR)
    return
  end

  -- A reply that lands after an edit would write into shifted positions.
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  in_flight[buf] = true
  notify("rewriting the selection...", vim.log.levels.INFO)

  openai.run(M.config, prompt, { spawn = M.spawn }, function(stdout, failure)
    in_flight[buf] = nil
    vim.schedule(function()
      apply(buf, region, tick, stdout, failure)
    end)
  end)
end

return M
