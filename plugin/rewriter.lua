if vim.g.loaded_rewriter then
  return
end
vim.g.loaded_rewriter = 1

vim.api.nvim_create_user_command("Rewrite", function(args)
  require("rewriter").rewrite(args)
end, {
  range = true,
  nargs = "*",
  desc = "Rewrite the visual selection with the OpenAI API, as in :'<,'>Rewrite paraphrase this",
})
