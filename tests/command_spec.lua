-- Tests for the `:Rewrite` command: the selection reaches the API, the reply
-- lands in the buffer, and concurrent or stale requests are refused.

local rewriter = require("rewriter")

--- Answers a request with `content` in the first choice.
--- @param content string
--- @return string
local function reply(content)
  return vim.json.encode({ choices = { { message = { content = content } } } })
end

--- Points the plugin at a fake `curl`.
--- @param spawn function
local function configure(spawn)
  rewriter.setup({
    curl_cmd = "/bin/fake-curl",
    api_key = "sk-test",
    model = "gpt-test",
    base_url = "https://api.test/v1",
    reasoning_effort = "",
    extra_headers = {},
    file_context = false,
    system_prompt = "SYS",
  })
  rewriter.spawn = spawn
end

--- Builds a spawn that records the request and hands back the exit callback.
--- @param record table
local function hold(record)
  return function(argv, opts, on_exit)
    record.argv = argv
    record.opts = opts
    record.on_exit = on_exit
    return { pid = 1 }
  end
end

--- Reads the user message out of a recorded request.
--- @param record table
--- @return string
local function prompt(record)
  return vim.json.decode(helper.curl_body(record.opts.stdin)).messages[2].content
end

test(":Rewrite replaces the selection in place", function()
  local buf = helper.buffer({ "abcdefghij" })
  local record = {}
  configure(hold(record))
  helper.select(0, 2, "vlll")

  vim.cmd("'<,'>Rewrite paraphrase this")

  eq(prompt(record), "paraphrase this\n\ncdef", "prompt")
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "abcdefghij" }, "buffer while pending")

  record.on_exit({ code = 0, signal = 0, stdout = reply("XY"), stderr = "" })
  helper.drain()
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "abXYghij" }, "buffer after the reply")
end)

test(":Rewrite writes a multi-line reply as new lines", function()
  local buf = helper.buffer({ "aaa", "bbb" })
  local record = {}
  configure(hold(record))
  helper.select(0, 0, "Vj")

  vim.cmd("'<,'>Rewrite split this")

  record.on_exit({ code = 0, signal = 0, stdout = reply("x\ny\nz"), stderr = "" })
  helper.drain()
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "x", "y", "z" })
end)

test(":Rewrite refuses a second request while one runs", function()
  local buf = helper.buffer({ "abcdefghij" })
  local record = {}
  local spawns = 0
  configure(function(argv, opts, on_exit)
    spawns = spawns + 1
    return hold(record)(argv, opts, on_exit)
  end)
  helper.select(0, 2, "vlll")

  local notices = helper.notices(function()
    vim.cmd("'<,'>Rewrite one")
    vim.cmd("'<,'>Rewrite two")
  end)

  eq(spawns, 1, "spawns")
  ok(helper.any_match(notices, "already running"), "the refusal should reach the user")
  eq(prompt(record), "one\n\ncdef", "prompt")

  record.on_exit({ code = 0, signal = 0, stdout = reply("XY"), stderr = "" })
  helper.drain()
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "abXYghij" })
end)

test(":Rewrite refuses an empty instruction", function()
  helper.buffer({ "abcdefghij" })
  local record = {}
  local spawns = 0
  configure(function(argv, opts, on_exit)
    spawns = spawns + 1
    return hold(record)(argv, opts, on_exit)
  end)
  helper.select(0, 2, "vlll")

  local notices = helper.notices(function()
    vim.cmd("'<,'>Rewrite")
  end)

  eq(spawns, 0, "spawns")
  ok(helper.any_match(notices, "empty instruction"), "the refusal should reach the user")
end)

test(":Rewrite refuses without a selection", function()
  helper.buffer({ "abcdefghij" })
  local spawns = 0
  configure(function()
    spawns = spawns + 1
    return { pid = 1 }
  end)

  local notices = helper.notices(function()
    vim.cmd("Rewrite paraphrase this")
  end)

  eq(spawns, 0, "spawns")
  ok(helper.any_match(notices, "select"), "the refusal should reach the user")
end)

test(":Rewrite refuses without an API key", function()
  helper.buffer({ "abcdefghij" })
  local spawns = 0
  configure(function()
    spawns = spawns + 1
    return { pid = 1 }
  end)
  rewriter.setup({ api_key = "" })
  helper.select(0, 2, "vlll")

  local notices = helper.notices(function()
    vim.cmd("'<,'>Rewrite paraphrase this")
  end)

  eq(spawns, 0, "spawns")
  ok(helper.any_match(notices, "no API key"), "the refusal should reach the user")
end)

test(":Rewrite reports a failed run", function()
  helper.buffer({ "abcdefghij" })
  local record = {}
  configure(hold(record))
  helper.select(0, 2, "vlll")

  vim.cmd("'<,'>Rewrite one")
  local notices = helper.notices(function()
    record.on_exit({ code = 1, signal = 0, stdout = "", stderr = "boom\n" })
    helper.drain()
  end)

  ok(helper.any_match(notices, "code 1"), "the failure should reach the user")
  eq(helper.lines(), { "abcdefghij" }, "buffer")
end)

test(":Rewrite sends the configured headers and thinking level", function()
  helper.buffer({ "abcdefghij" })
  local record = {}
  configure(hold(record))
  rewriter.setup({ reasoning_effort = "low", extra_headers = { ["X-Title"] = "vbcdd" } })
  helper.select(0, 2, "vlll")

  vim.cmd("'<,'>Rewrite paraphrase this")

  ok(record.opts.stdin:find('header = "X%-Title: vbcdd"'), "the extra header should reach the request")
  eq(vim.json.decode(helper.curl_body(record.opts.stdin)).reasoning_effort, "low", "thinking level")

  record.on_exit({ code = 0, signal = 0, stdout = reply("XY"), stderr = "" })
  helper.drain()
end)

test(":Rewrite sends the whole buffer when file_context is on", function()
  helper.buffer({ "before", "abcdefghij", "after" })
  local record = {}
  configure(hold(record))
  rewriter.setup({ file_context = true })
  helper.select(1, 2, "vlll")

  vim.cmd("'<,'>Rewrite paraphrase this")

  local message = vim.json.decode(helper.curl_body(record.opts.stdin)).messages[2].content
  eq(message, '<file path="unnamed buffer">\nbefore\nabcdefghij\nafter\n</file>\n\nparaphrase this\n\ncdef')

  record.on_exit({ code = 0, signal = 0, stdout = reply("XY"), stderr = "" })
  helper.drain()
  eq(helper.lines(), { "before", "abXYghij", "after" }, "buffer")
end)

test(":Rewrite keeps the reply out of a buffer edited mid-request", function()
  local buf = helper.buffer({ "abcdefghij" })
  local record = {}
  configure(hold(record))
  helper.select(0, 2, "vlll")

  vim.cmd("'<,'>Rewrite paraphrase this")
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "inserted" })

  local notices = helper.notices(function()
    record.on_exit({ code = 0, signal = 0, stdout = reply("XY"), stderr = "" })
    helper.drain()
  end)

  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "inserted", "abcdefghij" }, "buffer")
  ok(helper.any_match(notices, "buffer changed"), "the guard should reach the user")
  eq(vim.fn.getreg('"'), "XY\n", "register")
  eq(vim.fn.getregtype('"'), "V", "register type")
end)
