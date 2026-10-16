-- Tests for `rewriter.openai`: prompt framing, the request, and the reply
-- parsing.

local openai = require("rewriter.openai")

local CFG = {
  curl_cmd = "/bin/fake-curl",
  api_key = "sk-test",
  model = "gpt-test",
  base_url = "https://api.test/v1",
  timeout_ms = 5000,
  max_prompt_bytes = 40,
  system_prompt = "SYS",
}

--- Copies `CFG` with one field emptied.
--- @param field string
--- @return table
local function without(field)
  local cfg = vim.deepcopy(CFG)
  cfg[field] = ""
  return cfg
end

--- Builds a `vim.system` stand-in that reports `out` and records its call.
--- @param out table
--- @param record table
local function fake_spawn(out, record)
  return function(argv, opts, on_exit)
    record.argv = argv
    record.opts = opts
    on_exit(out)
    return { pid = 1 }
  end
end

--- Builds a chat-completions body holding `content`.
--- @param content string
--- @return string
local function body(content)
  return vim.json.encode({ choices = { { message = { content = content } } } })
end

test("validate accepts a complete configuration", function()
  is_nil(openai.validate(CFG), "err")
end)

test("validate reports every missing setting", function()
  eq(openai.validate(without("curl_cmd")), "curl not found on PATH: set curl_cmd in setup()")
  eq(openai.validate(without("base_url")), "base_url is empty: set base_url in setup()")
  eq(openai.validate(without("api_key")), "no API key: set OPENAI_API_KEY or api_key in setup()")
  eq(openai.validate(without("model")), "model is empty: set model in setup()")
  eq(openai.validate(without("system_prompt")), "system_prompt is empty: set system_prompt in setup()")
end)

test("validate reports a base_url carrying whitespace", function()
  local cfg = vim.deepcopy(CFG)
  cfg.base_url = 'https://api.test/v1\nheader = "Evil: yes"'

  ok(openai.validate(cfg):match("whitespace"), "the refusal should name the whitespace")
end)

test("endpoint appends the chat-completions path", function()
  eq(openai.endpoint(CFG), "https://api.test/v1/chat/completions")
end)

test("endpoint drops a trailing slash", function()
  local cfg = vim.deepcopy(CFG)
  cfg.base_url = "https://api.test/v1/"

  eq(openai.endpoint(cfg), "https://api.test/v1/chat/completions")
end)

test("build_prompt frames the instruction above the selection", function()
  eq(openai.build_prompt(CFG, "paraphrase this", "cdef"), "paraphrase this\n\ncdef")
end)

test("build_prompt rejects an empty instruction", function()
  local prompt, err = openai.build_prompt(CFG, "", "cdef")
  is_nil(prompt, "prompt")
  ok(err:match("empty instruction"), "error should name the empty instruction: " .. tostring(err))
end)

test("build_prompt rejects a prompt over the byte cap", function()
  local prompt, err = openai.build_prompt(CFG, string.rep("x", 39), "cdef")
  is_nil(prompt, "prompt")
  ok(err:match("over the 40 byte limit"), "error should name the limit: " .. tostring(err))
end)

test("request_body carries the model and both messages", function()
  local decoded = vim.json.decode(openai.request_body(CFG, "hello"))

  eq(decoded.model, "gpt-test", "model")
  eq(decoded.messages[1], { role = "system", content = "SYS" }, "system message")
  eq(decoded.messages[2], { role = "user", content = "hello" }, "user message")
end)

test("build_argv reads the request from stdin", function()
  local argv = openai.build_argv(CFG)

  eq(argv[1], "/bin/fake-curl", "argv[1]")
  eq(argv[#argv], "-", "last argument")

  local present = {}
  for _, arg in ipairs(argv) do
    present[arg] = true
  end
  for _, flag in ipairs(openai.flags) do
    ok(present[flag], "missing flag " .. flag)
  end
end)

test("build_config posts the body to the endpoint with the key", function()
  local request = openai.request_body(CFG, "hello")
  local config = openai.build_config(CFG, request)

  ok(config:match('url = "https://api%.test/v1/chat/completions"'), "the endpoint should be named")
  ok(config:match('request = "POST"'), "the method should be POST")
  ok(config:match("Authorization: Bearer sk%-test"), "the key should travel in the header")
  eq(vim.json.decode(helper.curl_body(config)), vim.json.decode(request), "body")
  eq(helper.curl_body(config), request, "body")
end)

test("build_config escapes quotes and backslashes", function()
  local cfg = vim.deepcopy(CFG)
  cfg.api_key = 'sk-"quoted"\\'
  local request = '{"text":"a \\"quote\\" and a \\\\ backslash"}'
  local config = openai.build_config(cfg, request)

  eq(helper.curl_body(config), request, "body")
  -- A plain find, so every backslash stays literal.
  local header = 'Authorization: Bearer sk-\\"quoted\\"\\\\"'
  ok(config:find(header, 1, true), "the key should survive the quoting")
end)

test("parse_reply reads the first choice", function()
  eq(openai.parse_reply(body("hello")), "hello")
end)

test("parse_reply reports an API error", function()
  local reply, err = openai.parse_reply(vim.json.encode({ error = { message = "bad key" } }))
  is_nil(reply, "reply")
  ok(err:match("bad key"), "error should carry the message: " .. tostring(err))
end)

test("parse_reply ignores a null error", function()
  eq(openai.parse_reply('{"error":null,"choices":[{"message":{"content":"hello"}}]}'), "hello")
end)

test("parse_reply reports a body it cannot read", function()
  local reply, err = openai.parse_reply("not json")
  is_nil(reply, "reply")
  ok(err:match("invalid JSON"), "error should name the body: " .. tostring(err))

  reply, err = openai.parse_reply("")
  is_nil(reply, "reply")
  ok(err:match("empty body"), "error should name the empty body: " .. tostring(err))
end)

test("parse_reply keeps a long unreadable body short", function()
  local reply, err = openai.parse_reply("<html>" .. string.rep("x", 1000))

  is_nil(reply, "reply")
  ok(#err < 300, "error should truncate the body: " .. #err .. " bytes")
  ok(err:match("%.%.%.$"), "error should mark the truncation: " .. tostring(err))
end)

test("parse_reply reports a body without a choice", function()
  local reply, err = openai.parse_reply("{}")
  is_nil(reply, "reply")
  ok(err:match("no choices"), "error should name the missing choice: " .. tostring(err))

  reply, err = openai.parse_reply('{"choices":[{"message":{"content":""}}]}')
  is_nil(reply, "reply")
  ok(err:match("empty reply"), "error should name the empty reply: " .. tostring(err))

  reply, err = openai.parse_reply('{"choices":[{"message":{"content":null}}]}')
  is_nil(reply, "reply")
  ok(err:match("no text"), "error should name the missing text: " .. tostring(err))
end)

test("run passes the reply on a zero exit", function()
  local record = {}
  local reply, err

  openai.run(
    CFG,
    "hello",
    { spawn = fake_spawn({ code = 0, signal = 0, stdout = body("done"), stderr = "" }, record) },
    function(out, failure)
      reply, err = out, failure
    end
  )

  eq(reply, "done", "reply")
  is_nil(err, "err")
  eq(record.opts.text, true, "text")
  eq(record.opts.timeout, 5000, "timeout")
  eq(record.argv[1], "/bin/fake-curl", "command")
  eq(vim.json.decode(helper.curl_body(record.opts.stdin)).messages[2].content, "hello", "prompt on stdin")
end)

test("run reports a non-zero exit with stderr", function()
  local record = {}
  local reply, err

  openai.run(CFG, "hello", {
    spawn = fake_spawn({ code = 3, signal = 0, stdout = "", stderr = "boom\n" }, record),
  }, function(out, failure)
    reply, err = out, failure
  end)

  is_nil(reply, "reply")
  ok(err:match("code 3"), "error should name the exit code: " .. tostring(err))
  ok(err:match("boom"), "error should carry stderr: " .. tostring(err))
end)

test("run reports a timeout as code 124", function()
  local record = {}
  local reply, err

  openai.run(CFG, "hello", {
    spawn = fake_spawn({ code = 124, signal = 15, stdout = "", stderr = "" }, record),
  }, function(out, failure)
    reply, err = out, failure
  end)

  is_nil(reply, "reply")
  ok(err:match("timed out"), "error should name the timeout: " .. tostring(err))
end)

test("run reports an unreadable body", function()
  local record = {}
  local reply, err

  openai.run(CFG, "hello", {
    spawn = fake_spawn({ code = 0, signal = 0, stdout = "<html>", stderr = "" }, record),
  }, function(out, failure)
    reply, err = out, failure
  end)

  is_nil(reply, "reply")
  ok(err:match("invalid JSON"), "error should name the body: " .. tostring(err))
end)

test("run reports a missing setting before it spawns", function()
  local spawns = 0
  local reply, err

  openai.run(without("api_key"), "hello", {
    spawn = function()
      spawns = spawns + 1
      return { pid = 1 }
    end,
  }, function(out, failure)
    reply, err = out, failure
  end)

  eq(spawns, 0, "spawns")
  is_nil(reply, "reply")
  ok(err:match("no API key"), "error should name the key: " .. tostring(err))
end)

test("run reports a spawn failure", function()
  local reply, err

  openai.run(CFG, "hello", {
    spawn = function()
      error("ENOENT")
    end,
  }, function(out, failure)
    reply, err = out, failure
  end)

  is_nil(reply, "reply")
  ok(err:match("cannot start curl"), "error should name the failed start: " .. tostring(err))
end)

test("run calls on_done once when the spawn fails after exiting", function()
  local calls = 0

  openai.run(CFG, "hello", {
    spawn = function(argv, opts, on_exit)
      on_exit({ code = 0, signal = 0, stdout = body("done"), stderr = "" })
      error("ENOENT")
    end,
  }, function()
    calls = calls + 1
  end)

  eq(calls, 1, "on_done calls")
end)
