--- Builds an OpenAI chat-completions request and sends it with `curl`.

local M = {}

--- `curl` reads the whole request from stdin through `--config -`, so the API
--- key never reaches the process list, and `--silent --show-error` keeps the
--- reply on stdout while a transport failure lands on stderr.
M.flags = { "--silent", "--show-error", "--config", "-" }

--- The chat-completions path, relative to `base_url`.
local CHAT_PATH = "/chat/completions"

--- How much of a stray response body an error message quotes.
local SNIPPET = 200

--- Keeps a response body short enough for one notification.
--- @param text string
--- @return string
local function snippet(text)
  assert(type(text) == "string", "text must be a string")

  local trimmed = vim.trim(text)
  if #trimmed <= SNIPPET then
    return trimmed
  end

  assert(SNIPPET > 0, "the snippet must hold something")
  return trimmed:sub(1, SNIPPET) .. "..."
end

--- Quotes a value for a `curl` config file, whose parser reads a backslash as
--- an escape inside double quotes.
--- @param value string
--- @return string
local function quote(value)
  assert(type(value) == "string", "value must be a string")

  local escaped = value:gsub("\\", "\\\\"):gsub('"', '\\"')
  local quoted = '"' .. escaped .. '"'
  assert(#quoted == #escaped + 2, "the delimiters must frame the value")
  return quoted
end

--- Reports the first setting a request cannot run without. Everything but
--- `timeout_ms`, `max_prompt_bytes`, and `extra_headers` holds a string, and
--- `file_context` holds a boolean.
--- @param cfg table
--- @return string|nil err
function M.validate(cfg)
  assert(type(cfg) == "table", "cfg must be a table")

  if cfg.curl_cmd == nil or cfg.curl_cmd == "" then
    return "curl not found on PATH: set curl_cmd in setup()"
  end
  if cfg.base_url == nil or cfg.base_url == "" then
    return "base_url is empty: set base_url in setup()"
  end
  if cfg.base_url:match("%s") then
    return "base_url holds whitespace: " .. cfg.base_url
  end
  if cfg.api_key == nil or cfg.api_key == "" then
    return "no API key: set OPENAI_API_KEY or api_key in setup()"
  end
  if cfg.api_key:match("%s") then
    return "api_key holds whitespace"
  end
  if cfg.model == nil or cfg.model == "" then
    return "model is empty: set model in setup()"
  end
  if cfg.system_prompt == nil or cfg.system_prompt == "" then
    return "system_prompt is empty: set system_prompt in setup()"
  end
  if cfg.reasoning_effort == nil or type(cfg.reasoning_effort) ~= "string" then
    return "reasoning_effort must be a string: set reasoning_effort in setup()"
  end
  if cfg.reasoning_effort:match("%s") then
    return "reasoning_effort holds whitespace: " .. cfg.reasoning_effort
  end
  if type(cfg.file_context) ~= "boolean" then
    return "file_context must be a boolean: set file_context in setup()"
  end
  if type(cfg.file_context) ~= "boolean" then
    return "file_context must be a boolean: set file_context in setup()"
  end

  local err = M.validate_headers(cfg.extra_headers)
  if err then
    return err
  end

  assert(cfg.timeout_ms > 0, "timeout_ms must be positive")
  assert(cfg.max_prompt_bytes > 0, "max_prompt_bytes must be positive")
  return nil
end

--- Reports the first extra header a request cannot send. A name holds no
--- whitespace and no colon, and a value holds no control character, so
--- neither can break out of its `curl` config line.
--- @param headers any
--- @return string|nil err
function M.validate_headers(headers)
  if type(headers) ~= "table" then
    return "extra_headers must be a table of name = value"
  end

  for name, value in pairs(headers) do
    if type(name) ~= "string" or name == "" then
      return "extra_headers holds a name that is not a string"
    end
    if name:match("[%s:]") then
      return "extra_headers holds a name with whitespace or a colon: " .. name
    end
    if type(value) ~= "string" then
      return "extra_headers holds a value that is not a string: " .. name
    end
    if value:match("%c") then
      return "extra_headers holds a value with a control character: " .. name
    end
  end

  return nil
end

--- Builds the endpoint. A configured base URL may carry a trailing slash, as
--- in `https://api.openai.com/v1/`.
--- @param cfg table
--- @return string url
function M.endpoint(cfg)
  assert(type(cfg) == "table", "cfg must be a table")
  assert(type(cfg.base_url) == "string" and cfg.base_url ~= "", "base_url must be set")

  local base = cfg.base_url:gsub("/+$", "")
  local url = base .. CHAT_PATH

  assert(url:sub(-#CHAT_PATH) == CHAT_PATH, "the endpoint must end with the chat-completions path")
  return url
end

--- The system-prompt sentence that describes a request carrying the file.
local FILE_FRAMING = table.concat({
  "The message may open with the whole file in <file> tags.",
  "Treat that part as context: never rewrite it, never repeat it.",
  "Rewrite the selection that follows the instruction.",
}, " ")

--- Builds the system message. A request that carries the file says so, so the
--- model knows which part to rewrite.
--- @param cfg table
--- @return string
function M.system_message(cfg)
  assert(type(cfg) == "table", "cfg must be a table")
  assert(type(cfg.system_prompt) == "string" and cfg.system_prompt ~= "", "system_prompt must be set")

  if not cfg.file_context then
    return cfg.system_prompt
  end

  assert(type(FILE_FRAMING) == "string" and FILE_FRAMING ~= "", "the framing must be set")
  return cfg.system_prompt .. " " .. FILE_FRAMING
end

--- Frames one file as context ahead of the prompt.
--- @param path string buffer name, empty for an unnamed buffer
--- @param text string whole file
--- @return string context
function M.build_context(path, text)
  assert(type(path) == "string", "path must be a string")
  assert(type(text) == "string", "text must be a string")

  local name = path ~= "" and path or "unnamed buffer"
  local context = string.format("<file path=%q>\n%s\n</file>\n\n", name, text)

  assert(#context > #text, "the tags must wrap the text")
  return context
end

--- Builds the prompt from an instruction and the selected text, behind the
--- optional file context. The blank line between the instruction and the
--- selection is the framing the system prompt describes.
--- @param cfg table
--- @param instruction string
--- @param selection string
--- @param context string|nil the file, already framed
--- @return string|nil prompt
--- @return string|nil err
function M.build_prompt(cfg, instruction, selection, context)
  assert(type(cfg) == "table", "cfg must be a table")
  assert(type(instruction) == "string", "instruction must be a string")
  assert(type(selection) == "string", "selection must be a string")
  assert(context == nil or type(context) == "string", "context must be a string")

  if instruction == "" then
    return nil, "empty instruction: write what to do, as in :Rewrite paraphrase this"
  end

  local prompt = (context or "") .. instruction .. "\n\n" .. selection
  if #prompt > cfg.max_prompt_bytes then
    return nil,
      string.format(
        "prompt is %d bytes, over the %d byte limit: select less text, or turn file_context off",
        #prompt,
        cfg.max_prompt_bytes
      )
  end

  assert(prompt ~= "", "prompt must not be empty")
  return prompt
end

--- Builds the request body: one system message framing the work, then one
--- user message holding the prompt.
--- @param cfg table
--- @param prompt string
--- @return string body JSON
function M.request_body(cfg, prompt)
  assert(type(cfg) == "table", "cfg must be a table")
  assert(type(prompt) == "string" and prompt ~= "", "prompt must be a non-empty string")
  assert(type(cfg.model) == "string" and cfg.model ~= "", "model must be set")
  assert(type(cfg.system_prompt) == "string", "system_prompt must be a string")
  assert(type(cfg.reasoning_effort) == "string", "reasoning_effort must be a string")

  local body = {
    model = cfg.model,
    messages = {
      { role = "system", content = M.system_message(cfg) },
      { role = "user", content = prompt },
    },
  }

  -- An empty setting leaves the field out: a model without reasoning rejects
  -- an unknown one.
  if cfg.reasoning_effort ~= "" then
    body.reasoning_effort = cfg.reasoning_effort
  end

  local json = vim.json.encode(body)

  assert(#json > 0, "the encoded body must not be empty")
  return json
end

--- Collects the extra header names in a fixed order, because a Lua table
--- iterates in no order a diff or a test can rely on.
--- @param headers table
--- @return string[] names
local function header_names(headers)
  assert(type(headers) == "table", "headers must be a table")

  local names = {}
  for name in pairs(headers) do
    assert(type(name) == "string", "a header name must be a string")
    names[#names + 1] = name
  end
  table.sort(names)

  if #names > 0 then
    assert(names[1] ~= "", "the first header name must not be empty")
  end
  return names
end

--- Builds the `curl` argument list. The request itself arrives on stdin.
--- @param cfg table
--- @return string[] argv
function M.build_argv(cfg)
  assert(type(cfg) == "table", "cfg must be a table")
  assert(type(cfg.curl_cmd) == "string" and cfg.curl_cmd ~= "", "curl_cmd must be set")

  local argv = { cfg.curl_cmd }
  vim.list_extend(argv, M.flags)

  assert(argv[#argv] == "-", "the config must be read from stdin")
  return argv
end

--- Builds the `curl` config. The body comes last, after the URL it posts to.
--- @param cfg table
--- @param body string JSON
--- @return string config
function M.build_config(cfg, body)
  assert(type(cfg) == "table", "cfg must be a table")
  assert(type(body) == "string" and body ~= "", "body must be a non-empty string")
  assert(type(cfg.api_key) == "string" and cfg.api_key ~= "", "api_key must be set")

  local lines = {
    "url = " .. quote(M.endpoint(cfg)),
    "request = " .. quote("POST"),
    "header = " .. quote("Content-Type: application/json"),
    "header = " .. quote("Authorization: Bearer " .. cfg.api_key),
  }
  for _, name in ipairs(header_names(cfg.extra_headers)) do
    lines[#lines + 1] = "header = " .. quote(name .. ": " .. cfg.extra_headers[name])
  end
  lines[#lines + 1] = "data = " .. quote(body)

  assert(lines[#lines] == "data = " .. quote(body), "the body must be the last entry")
  return table.concat(lines, "\n") .. "\n"
end

--- Reads the reply text out of a chat-completions response body. A transport
--- failure never reaches here; `curl` reports one through its exit code.
--- @param stdout string
--- @return string|nil reply
--- @return string|nil err
function M.parse_reply(stdout)
  assert(type(stdout) == "string", "stdout must be a string")

  if stdout == "" then
    return nil, "the API returned an empty body"
  end

  local ok, decoded = pcall(vim.json.decode, stdout)
  if not ok then
    return nil, "the API returned invalid JSON: " .. snippet(stdout)
  end

  if type(decoded) ~= "table" then
    return nil, "the API returned no JSON object: " .. snippet(stdout)
  end

  local failure = decoded.error
  if failure ~= nil and failure ~= vim.NIL then
    local reason = type(failure) == "table" and failure.message or vim.inspect(failure)
    return nil, "the API reported an error: " .. tostring(reason)
  end

  local choices = decoded.choices
  if type(choices) ~= "table" then
    return nil, "the response holds no choices"
  end

  local choice = choices[1]
  if type(choice) ~= "table" then
    return nil, "the response holds no choices"
  end

  local message = choice.message
  if type(message) ~= "table" then
    return nil, "the first choice holds no message"
  end

  local content = message.content
  if type(content) ~= "string" then
    return nil, "the first choice holds no text"
  end
  if content == "" then
    return nil, "the API returned an empty reply"
  end

  assert(content ~= "", "the reply must not be empty")
  return content
end

--- Runs one rewrite. `ctx.spawn` defaults to `vim.system`, so a test injects
--- a fake and never reaches the network.
--- @param cfg table
--- @param prompt string
--- @param ctx table
--- @param on_done fun(reply: string|nil, err: string|nil)
function M.run(cfg, prompt, ctx, on_done)
  assert(type(cfg) == "table", "cfg must be a table")
  assert(type(ctx) == "table", "ctx must be a table")
  assert(type(on_done) == "function", "on_done must be a function")

  local err = M.validate(cfg)
  if err then
    on_done(nil, err)
    return
  end

  local config = M.build_config(cfg, M.request_body(cfg, prompt))
  local spawn = ctx.spawn or vim.system
  local done = false

  local function finish(reply, failure)
    if done then
      return
    end
    done = true
    on_done(reply, failure)
  end

  local ok, failed = pcall(spawn, M.build_argv(cfg), {
    text = true,
    stdin = config,
    timeout = cfg.timeout_ms,
  }, function(out)
    if out.code == 124 then
      return finish(nil, string.format("the API timed out after %d ms", cfg.timeout_ms))
    end
    if out.code ~= 0 then
      local stderr = vim.trim(out.stderr or "")
      return finish(nil, string.format("curl exited with code %d: %s", out.code, stderr))
    end

    finish(M.parse_reply(out.stdout or ""))
  end)

  if not ok then
    finish(nil, "cannot start curl: " .. tostring(failed))
  end
end

return M
