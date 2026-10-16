# vbcdd-rewriter

Rewrite a visual selection with the [OpenAI API](https://platform.openai.com/docs/api-reference/chat). The `:Rewrite` command sends the selected text and the words after the command to `POST /chat/completions`, and replaces the selection in place with the reply.

> **Warning: Large Language Model-Generated Code**
>
> This code functions as of the time of writing, yet it has received little to no human review. It must not be regarded as reliable: bugs and stability issues are to be expected.

## Requirements

- Neovim 0.11 or later, for `vim.fn.getregionpos()`.
- `curl` on `PATH`, built with TLS.
- An API key in `OPENAI_API_KEY`.

## Install

Append the directory to `runtimepath`:

```lua
vim.opt.runtimepath:append(vim.fn.expand("~/plugins/vbcdd-rewriter"))
```

## Usage

Select text with `v` for characters or `V` for whole lines, then run `:Rewrite` with the instruction:

```vim
:'<,'>Rewrite paraphrase this
```

Visual mode fills in the `'<,'>` range; the instruction holds everything after `Rewrite`. The reply replaces the selection once the API answers, and the buffer stays untouched until then.

## Configuration

`setup()` merges its argument into the defaults. Call it at startup, before the first `:Rewrite`.

```lua
require("rewriter").setup({
  api_key = vim.env.OPENAI_API_KEY,
  model = "gpt-4o-mini",
  base_url = "https://api.openai.com/v1",
  reasoning_effort = "low",
  extra_headers = { ["X-Title"] = "vbcdd-rewriter" },
  timeout_ms = 120000,
  max_prompt_bytes = 100 * 1024,
})
```

| Option             | Default                     | Meaning                                            |
| ------------------ | --------------------------- | -------------------------------------------------- |
| `curl_cmd`         | `vim.fn.exepath("curl")`    | Executable that serves one request.                |
| `api_key`          | `vim.env.OPENAI_API_KEY`    | Bearer token.                                      |
| `model`            | `gpt-4o-mini`               | Model that answers the request.                    |
| `base_url`         | `https://api.openai.com/v1` | API root; another host serves a compatible API.    |
| `reasoning_effort` | `""`                        | Thinking level, sent as `reasoning_effort`; empty omits the field. |
| `extra_headers`    | `{}`                        | Request headers, as `name = value`.                |
| `timeout_ms`       | `120000`                    | Time limit for one request, in milliseconds.       |
| `max_prompt_bytes` | `100 * 1024`                | Cap on the instruction plus the selected text.     |
| `system_prompt`    | the plugin's own            | Replaces the default system message.               |

## Behavior

- One request runs per buffer. A second `:Rewrite` before the reply reports the request in flight.
- An edit during a request leaves the buffer alone and moves the reply to the `"` register.
- Charwise (`v`) and linewise (`V`) selections work. A blockwise selection (`<C-v>`) reports an error.
- A prompt over `max_prompt_bytes` reports the size and the limit.
- The request travels on `curl`'s stdin through `--config -`, so the key stays off the process list.
- `curl` runs with `--silent --show-error`: the reply lands on stdout, and a transport failure on stderr.
- The request holds two messages: the system prompt, then the instruction and the selection. The plugin reads the reply from the first choice.
- `reasoning_effort` travels verbatim, so a model that lacks reasoning keeps its field only when the setting is non-empty. Values come from the API: `minimal`, `low`, `medium`, `high`.
- An extra header whose name holds whitespace or a colon, or whose value holds a control character, reports an error instead of reaching `curl`.

## Development

```sh
vale sync                                       # once, fetches the prose lints
nvim --headless -u NONE -l tests/run.lua        # unit tests, no network
REWRITER_E2E=1 nvim --headless -u NONE -l tests/e2e.lua   # one live rewrite
scripts/check                                   # formatters and prose lints
```

## License

Released into the public domain under the [Unlicense](LICENSE).
