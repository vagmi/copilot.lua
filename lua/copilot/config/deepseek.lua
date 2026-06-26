---@class (exact) DeepSeekConfig
---@field api_key string|nil DeepSeek API key
---@field endpoint string DeepSeek API endpoint
---@field model string DeepSeek model

local deepseek = {
  ---@type DeepSeekConfig
  default = {
    api_key = nil,
    endpoint = "https://api.deepseek.com/beta/completions",
    model = "deepseek-v4-flash",
  },
}

function deepseek.validate(config)
  vim.validate("api_key", config.api_key, { "string", "nil" })
  vim.validate("endpoint", config.endpoint, "string")
  vim.validate("model", config.model, "string")
end

return deepseek
