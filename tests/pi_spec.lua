-- Tests for `rewriter.pi`: prompt framing, the argument list, and the three
-- process outcomes.

local pi = require("rewriter.pi")

local CFG = {
  pi_cmd = "/bin/fake-pi",
  timeout_ms = 5000,
  max_prompt_bytes = 40,
  system_prompt = "SYS",
}

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

test("build_argv carries the one-shot flags and ends with the prompt", function()
  local argv = pi.build_argv(CFG, "hello")

  eq(argv[1], "/bin/fake-pi", "argv[1]")
  eq(argv[#argv], "hello", "last argument")
  eq(argv[#argv - 1], "--", "separator")

  local present = {}
  for _, arg in ipairs(argv) do
    present[arg] = true
  end
  for _, flag in ipairs(pi.flags) do
    ok(present[flag], "missing flag " .. flag)
  end

  local at = 0
  for i, arg in ipairs(argv) do
    if arg == "--system-prompt" then
      at = i
    end
  end
  ok(at > 0, "--system-prompt is missing")
  eq(argv[at + 1], "SYS", "system prompt")
end)

test("build_argv reports an unset pi_cmd", function()
  local argv, err = pi.build_argv({ pi_cmd = "", system_prompt = "SYS" }, "hello")
  is_nil(argv, "argv")
  ok(err:match("pi not found"), "error should name the missing executable: " .. tostring(err))
end)

test("build_prompt frames the instruction above the selection", function()
  local prompt = pi.build_prompt(CFG, "paraphrase this", "cdef")
  eq(prompt, "paraphrase this\n\ncdef")
end)

test("build_prompt rejects an empty instruction", function()
  local prompt, err = pi.build_prompt(CFG, "", "cdef")
  is_nil(prompt, "prompt")
  ok(err:match("empty instruction"), "error should name the empty instruction: " .. tostring(err))
end)

test("build_prompt rejects a prompt over the byte cap", function()
  local prompt, err = pi.build_prompt(CFG, string.rep("x", 39), "cdef")
  is_nil(prompt, "prompt")
  ok(err:match("over the 40 byte limit"), "error should name the limit: " .. tostring(err))
end)

test("run passes the reply on a zero exit", function()
  local record = {}
  local stdout, err

  pi.run(
    CFG,
    "hello",
    { spawn = fake_spawn({ code = 0, signal = 0, stdout = "reply\n", stderr = "" }, record) },
    function(out, failure)
      stdout, err = out, failure
    end
  )

  eq(stdout, "reply\n", "stdout")
  is_nil(err, "err")
  eq(record.opts.text, true, "text")
  eq(record.opts.stdin, "", "stdin")
  eq(record.opts.timeout, 5000, "timeout")
  eq(record.argv[1], "/bin/fake-pi", "command")
end)

test("run reports a non-zero exit with stderr", function()
  local record = {}
  local stdout, err

  pi.run(CFG, "hello", {
    spawn = fake_spawn({ code = 3, signal = 0, stdout = "", stderr = "boom\n" }, record),
  }, function(out, failure)
    stdout, err = out, failure
  end)

  is_nil(stdout, "stdout")
  ok(err:match("code 3"), "error should name the exit code: " .. tostring(err))
  ok(err:match("boom"), "error should carry stderr: " .. tostring(err))
end)

test("run reports a timeout as code 124", function()
  local record = {}
  local stdout, err

  pi.run(CFG, "hello", {
    spawn = fake_spawn({ code = 124, signal = 15, stdout = "", stderr = "" }, record),
  }, function(out, failure)
    stdout, err = out, failure
  end)

  is_nil(stdout, "stdout")
  ok(err:match("timed out"), "error should name the timeout: " .. tostring(err))
end)

test("run reports a spawn failure", function()
  local stdout, err
  local record = {}

  pi.run(CFG, "hello", {
    spawn = function(argv, opts, on_exit)
      record.argv = argv
      error("ENOENT")
    end,
  }, function(out, failure)
    stdout, err = out, failure
  end)

  is_nil(stdout, "stdout")
  ok(err:match("cannot start pi"), "error should name the failed start: " .. tostring(err))
end)

test("run calls on_done once when the spawn fails after exiting", function()
  local calls = 0

  pi.run(CFG, "hello", {
    spawn = function(argv, opts, on_exit)
      on_exit({ code = 0, signal = 0, stdout = "reply\n", stderr = "" })
      error("ENOENT")
    end,
  }, function()
    calls = calls + 1
  end)

  eq(calls, 1, "on_done calls")
end)
