--- Builds the `pi` command line and runs it asynchronously.

local M = {}

--- One-shot header for a plain text transformation: no tools, no project
--- resources, and no session file.
M.flags = {
  "-p",
  "--no-session",
  "--no-tools",
  "--no-extensions",
  "--no-skills",
  "--no-prompt-templates",
  "--no-context-files",
}

--- Builds the prompt from an instruction and the selected text. The blank
--- line between them is the framing the system prompt describes.
--- @param cfg table
--- @param instruction string
--- @param selection string
--- @return string|nil prompt
--- @return string|nil err
function M.build_prompt(cfg, instruction, selection)
  assert(type(cfg) == "table", "cfg must be a table")
  assert(type(instruction) == "string", "instruction must be a string")
  assert(type(selection) == "string", "selection must be a string")

  if instruction == "" then
    return nil, "empty instruction: write what to do, as in :Rewrite paraphrase this"
  end

  local prompt = instruction .. "\n\n" .. selection
  if #prompt > cfg.max_prompt_bytes then
    return nil,
      string.format("prompt is %d bytes, over the %d byte limit: select less text", #prompt, cfg.max_prompt_bytes)
  end

  assert(prompt ~= "", "prompt must not be empty")
  return prompt
end

--- Builds the `pi` argument list. `--` keeps a prompt that starts with `-`
--- from reading as a flag.
--- @param cfg table
--- @param prompt string
--- @return string[]|nil argv
--- @return string|nil err
function M.build_argv(cfg, prompt)
  assert(type(cfg) == "table", "cfg must be a table")
  assert(type(prompt) == "string" and prompt ~= "", "prompt must be a non-empty string")

  if cfg.pi_cmd == nil or cfg.pi_cmd == "" then
    return nil, "pi not found on PATH: set pi_cmd in setup()"
  end

  local argv = { cfg.pi_cmd }
  vim.list_extend(argv, M.flags)
  argv[#argv + 1] = "--system-prompt"
  argv[#argv + 1] = cfg.system_prompt
  argv[#argv + 1] = "--"
  argv[#argv + 1] = prompt

  assert(argv[#argv] == prompt, "the prompt must be the last argument")
  return argv
end

--- Runs one rewrite. `ctx.spawn` defaults to `vim.system`, so a test injects
--- a fake and never starts a process.
--- @param cfg table
--- @param prompt string
--- @param ctx table
--- @param on_done fun(stdout: string|nil, err: string|nil)
function M.run(cfg, prompt, ctx, on_done)
  assert(type(cfg) == "table", "cfg must be a table")
  assert(type(ctx) == "table", "ctx must be a table")
  assert(type(on_done) == "function", "on_done must be a function")

  local argv, err = M.build_argv(cfg, prompt)
  if not argv then
    on_done(nil, err)
    return
  end

  local spawn = ctx.spawn or vim.system
  local done = false

  local function finish(stdout, failure)
    if done then
      return
    end
    done = true
    on_done(stdout, failure)
  end

  local ok, failed = pcall(spawn, argv, {
    text = true,
    stdin = "",
    timeout = cfg.timeout_ms,
  }, function(out)
    if out.code == 124 then
      return finish(nil, string.format("pi timed out after %d ms", cfg.timeout_ms))
    end
    if out.code ~= 0 then
      local stderr = vim.trim(out.stderr or "")
      return finish(nil, string.format("pi exited with code %d: %s", out.code, stderr))
    end
    finish(out.stdout, nil)
  end)

  if not ok then
    finish(nil, "cannot start pi: " .. tostring(failed))
  end
end

return M
