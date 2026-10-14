# vbcdd-rewriter

Rewrite a visual selection with [`pi`](https://pi.dev). The `:Rewrite` command sends the selected text and the words after the command to the configured model, and replaces the selection in place with the reply.

> **Warning: Large Language Model-Generated Code**
>
> This code functions as of the time of writing, yet it has received little to no human review. It must not be regarded as reliable: bugs and stability issues are to be expected.

## Requirements

- Neovim 0.11 or later, for `vim.fn.getregionpos()`.
- `pi` on `PATH`, with a provider configured. `pi auth check` reports the state.

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

Visual mode fills in the `'<,'>` range; the instruction holds everything after `Rewrite`. The reply replaces the selection once `pi` answers, and the buffer stays untouched until then.

## Configuration

`setup()` merges its argument into the defaults. Call it at startup, before the first `:Rewrite`.

```lua
require("rewriter").setup({
  pi_cmd = vim.fn.exepath("pi"),
  timeout_ms = 120000,
  max_prompt_bytes = 100 * 1024,
})
```

| Option             | Default                | Meaning                                           |
| ------------------ | ---------------------- | ------------------------------------------------- |
| `pi_cmd`           | `vim.fn.exepath("pi")` | Executable that serves one rewrite.               |
| `timeout_ms`       | `120000`               | Time limit for one request, in milliseconds.      |
| `max_prompt_bytes` | `100 * 1024`           | Cap on the instruction plus the selected text.    |
| `system_prompt`    | the plugin's own       | Replaces the default system prompt `pi` receives. |

## Behavior

- One request runs per buffer. A second `:Rewrite` before the reply reports the request in flight.
- An edit during a request leaves the buffer alone and moves the reply to the `"` register.
- Charwise (`v`) and linewise (`V`) selections work. A blockwise selection (`<C-v>`) reports an error.
- A prompt over `max_prompt_bytes` reports the size and the limit.
- `pi` runs with `--no-session --no-tools --no-extensions --no-skills
--no-prompt-templates --no-context-files`, so one rewrite starts no session and touches no project files.

## Development

```sh
vale sync                                       # once, fetches the prose lints
nvim --headless -u NONE -l tests/run.lua        # unit tests, no network
REWRITER_E2E=1 nvim --headless -u NONE -l tests/e2e.lua   # one live rewrite
scripts/check                                   # formatters and prose lints
```

## License

Released into the public domain under the [Unlicense](LICENSE).
