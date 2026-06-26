local logger = require("copilot.logger")
local util = require("copilot.util")
local config = require("copilot.config")

local M = {
  initialization_failed = false,
}

local function get_api_key()
  return config.deepseek.api_key or os.getenv("DEEPSEEK_API_KEY")
end

---@param dispatchers vim.lsp.rpc.Dispatchers
---@return vim.lsp.rpc.PublicClient
function M.start(dispatchers)
  local closing = false
  local message_id = 0

  local function next_id()
    message_id = message_id + 1
    return message_id
  end

  local function deepseek_request(payload, callback)
    local api_key = get_api_key()
    if not api_key then
      callback("DeepSeek API key not found", nil)
      return
    end

    local body = vim.json.encode(payload)
    vim.system({
      "curl",
      "-s",
      "-X", "POST",
      config.deepseek.endpoint,
      "-H", "Content-Type: application/json",
      "-H", "Authorization: Bearer " .. api_key,
      "-d", body,
    }, {
      text = true,
    }, function(out)
      if out.code ~= 0 then
        callback("DeepSeek API request failed: " .. (out.stderr or "unknown error"), nil)
        return
      end

      local ok, result = pcall(vim.json.decode, out.stdout)
      if not ok then
        callback("Failed to decode DeepSeek API response: " .. result, nil)
        return
      end

      if result.error then
        callback("DeepSeek API error: " .. (result.error.message or "unknown error"), nil)
        return
      end

      callback(nil, result)
    end)
  end

  local function handle_get_completions(params, callback)
    local bufnr = params.bufnr or vim.uri_to_bufnr(params.doc.uri)
    local prefix, suffix = util.get_fim_context(bufnr, params.doc.position)
    local extra_context = util.get_related_files_context(bufnr, 1024)

    local payload = {
      model = config.deepseek.model,
      prompt = extra_context .. "\n" .. prefix,
      suffix = suffix,
      max_tokens = 1024, -- TODO: configurable
      temperature = 0,
      n = 1,
    }

    deepseek_request(payload, function(err, result)
      if err then
        callback(err, nil)
        return
      end

      local completions = {}
      for i, choice in ipairs(result.choices) do
        table.insert(completions, {
          text = choice.text,
          displayText = choice.text,
          uuid = "deepseek-" .. (result.id or next_id()) .. "-" .. i,
          range = {
            start = params.doc.position,
            ["end"] = params.doc.position,
          },
        })
      end

      vim.schedule(function()
        callback(nil, { completions = completions })
      end)
    end)
  end

  local function handle_get_panel_completions(params, callback)
    local bufnr = params.bufnr or vim.uri_to_bufnr(params.doc.uri)
    local prefix, suffix = util.get_fim_context(bufnr, params.doc.position)
    local extra_context = util.get_related_files_context(bufnr, 1024)

    local solutionCountTarget = 10 -- TODO: configurable
    local payload = {
      model = config.deepseek.model,
      prompt = extra_context .. "\n" .. prefix,
      suffix = suffix,
      max_tokens = 1024,
      temperature = 0.7,
      n = solutionCountTarget,
    }

    vim.schedule(function()
      callback(nil, { solutionCountTarget = solutionCountTarget })
    end)

    deepseek_request(payload, function(err, result)
      vim.schedule(function()
        if err then
          dispatchers.notification("PanelSolutionsDone", {
            panelId = params.panelId,
            status = "Error",
            message = err,
          })
          return
        end

        for i, choice in ipairs(result.choices) do
          dispatchers.notification("PanelSolution", {
            panelId = params.panelId,
            solutionId = "deepseek-panel-" .. (result.id or next_id()) .. "-" .. i,
            displayText = choice.text,
            completionText = choice.text,
            range = {
              start = params.doc.position,
              ["end"] = params.doc.position,
            },
            score = 0,
          })
        end

        dispatchers.notification("PanelSolutionsDone", {
          panelId = params.panelId,
          status = "OK",
        })
      end)
    end)
  end

  return {
    request = function(method, params, callback)
      local request_bufnr = params.bufnr
      if method == "initialize" then
        vim.schedule(function()
          callback(nil, {
            capabilities = {
              textDocumentSync = 1,
            },
            serverInfo = {
              name = "DeepSeek FIM",
              version = "1.0.0",
            }
          })
        end)
        return true, next_id()
      elseif method == "initialized" then
        return true, next_id()
      elseif method == "checkStatus" then
        vim.schedule(function()
          callback(nil, { status = get_api_key() and "OK" or "NotAuthorized", user = get_api_key() and "DeepSeek User" or nil })
        end)
        return true, next_id()
      elseif method == "getCompletions" or method == "getCompletionsCycling" then
        params.bufnr = request_bufnr
        handle_get_completions(params, callback)
        return true, next_id()
      elseif method == "getPanelCompletions" then
        params.bufnr = request_bufnr
        handle_get_panel_completions(params, callback)
        return true, next_id()
      elseif method == "signInInitiate" or method == "signInConfirm" then
        vim.schedule(function()
          callback("DeepSeek backend does not support GitHub sign-in", nil)
        end)
        return true, next_id()
      elseif method == "getVersion" then
        vim.schedule(function()
          callback(nil, { version = "deepseek-v1" })
        end)
        return true, next_id()
      elseif method == "copilot/models" then
        vim.schedule(function()
          callback(nil, {
            {
              id = config.deepseek.model,
              modelName = config.deepseek.model,
              scopes = { "completion" },
              default = true,
            }
          })
        end)
        return true, next_id()
      elseif method == "shutdown" then
        vim.schedule(function()
          callback(nil, nil)
        end)
        return true, next_id()
      elseif method == "exit" then
        return true, next_id()
      end

      vim.schedule(function()
        callback("Method not implemented: " .. method, nil)
      end)
      return true, next_id()
    end,
    notify = function(method, params)
      -- Handle notifications if needed
      return true
    end,
    is_closing = function()
      return closing
    end,
    terminate = function()
      closing = true
    end,
  }
end

function M.setup()
  return true
end

function M.init()
  return true
end

function M.get_server_info()
  return "DeepSeek FIM Backend (" .. config.deepseek.model .. ")"
end

function M.get_execute_command()
  return M.start
end

return M
