local u = require("tests.utils")
local child_helper = require("tests.child_helper")
local child = child_helper.new_child_neovim("test_deepseek")

local T = MiniTest.new_set({
  hooks = {
    pre_once = function() end,
    pre_case = function()
      child.run_pre_case(false)
      child.lua("c = require('copilot.client')")
    end,
    post_once = child.stop,
  },
})

T["deepseek"] = MiniTest.new_set()

T["deepseek"]["configures correctly"] = function()
  child.lua([[
    require("copilot").setup({
      backend = "deepseek",
      deepseek = {
        api_key = "test-key",
      }
    })
  ]])

  local backend = child.lua("return require('copilot.config').backend")
  MiniTest.expect.equality(backend, "deepseek")

  local server_type = child.lua("return require('copilot.config').server.type")
  MiniTest.expect.equality(server_type, "deepseek")
end

T["deepseek"]["lsp provider starts"] = function()
  child.lua([[
    require("copilot").setup({
      backend = "deepseek",
      deepseek = {
        api_key = "test-key",
      }
    })
  ]])

  child.lua("require('copilot.client').ensure_client_started()")

  local client = child.lua([[
    local client = require('copilot.client').get()
    return client and client.name or nil
  ]])
  MiniTest.expect.equality(client, "copilot")

  local server_info = child.lua([[
    local client = require('copilot.client').get()
    return require('copilot.lsp').get_server_info(client)
  ]])
  u.expect_match(server_info, "DeepSeek FIM Backend")
end

T["deepseek"]["getCompletions works"] = function()
  child.lua([[
    require("copilot").setup({
      backend = "deepseek",
      deepseek = {
        api_key = "test-key",
      }
    })

    -- Mock vim.system to return a predefined response
    _G.system_calls = {}
    vim.system = function(cmd, opts, on_exit)
      table.insert(_G.system_calls, cmd)
      if on_exit then
        on_exit({
          code = 0,
          stdout = vim.json.encode({
            id = "test-id",
            choices = {
              { text = " hello world" }
            }
          }),
          stderr = ""
        })
      end
      return {
        wait = function() return { code = 0, stdout = "", stderr = "" } end,
        kill = function() end
      }
    end
  ]])

  child.lua("require('copilot.client').ensure_client_started()")

  -- Trigger a completion request
  child.lua([[
    local client = require('copilot.client').get()
    local api = require('copilot.api')
    api.get_completions(client, {
      doc = {
        uri = "file:///test.lua",
        position = { line = 0, character = 0 }
      }
    }, function(err, data)
      _G.completion_data = data
    end)
    vim.wait(100, function() return _G.completion_data ~= nil end)
  ]])

  local completion_text = child.lua("return _G.completion_data.completions[1].text")
  MiniTest.expect.equality(completion_text, " hello world")

  local calls = child.lua("return #_G.system_calls")
  MiniTest.expect.equality(calls, 1)
end

T["deepseek"]["includes related files context"] = function()
  child.lua([[
    require("copilot").setup({ backend = "deepseek" })
    
    -- Use vim.cmd to create a named buffer correctly
    vim.cmd("edit shared.lua")
    local other_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(other_buf, 0, -1, false, { "-- shared logic", "function test() end" })
    vim.api.nvim_set_option_value("filetype", "lua", { buf = other_buf })
    vim.cmd("edit main.lua")

    _G.last_payload = nil
    vim.system = function(cmd, opts, on_exit)
      local body_idx = 0
      for i, v in ipairs(cmd) do
        if v == "-d" then body_idx = i + 1 break end
      end
      if body_idx > 0 then
        _G.last_payload = vim.json.decode(cmd[body_idx])
      end
      on_exit({ code = 0, stdout = vim.json.encode({ id = "test", choices = {{ text = "" }} }), stderr = "" })
      return { wait = function() end, kill = function() end }
    end
  ]])

  child.lua("require('copilot.client').ensure_client_started()")
  child.lua([[
    local client = require('copilot.client').get()
    local main_buf = vim.api.nvim_get_current_buf()
    require('copilot.api').get_completions(client, {
      bufnr = main_buf,
      doc = { uri = "file:///main.lua", position = { line = 0, character = 0 } }
    }, function() end)
    vim.wait(100, function() return _G.last_payload ~= nil end)
  ]])
  
  local prompt = child.lua("return _G.last_payload and _G.last_payload.prompt or ''")
  u.expect_match(prompt, "shared.lua")
  u.expect_match(prompt, "shared logic")
end

T["deepseek"]["getPanelCompletions works"] = function()
  child.lua([[
    require("copilot").setup({
      backend = "deepseek",
      deepseek = {
        api_key = "test-key",
      }
    })

    _G.system_calls = {}
    _G.notifications = {}
    vim.system = function(cmd, opts, on_exit)
      table.insert(_G.system_calls, cmd)
      if on_exit then
        on_exit({
          code = 0,
          stdout = vim.json.encode({
            id = "test-id-panel",
            choices = {
              { text = " solution 1" },
              { text = " solution 2" }
            }
          }),
          stderr = ""
        })
      end
      return { wait = function() end, kill = function() end }
    end
  ]])

  child.lua("require('copilot.client').ensure_client_started()")

  child.lua([[
    local client = require('copilot.client').get()
    local api = require('copilot.api')

    -- Capture notifications
    client.handlers["PanelSolution"] = function(err, result) table.insert(_G.notifications, { name = "PanelSolution", data = result }) end
    client.handlers["PanelSolutionsDone"] = function(err, result) table.insert(_G.notifications, { name = "PanelSolutionsDone", data = result }) end

    coroutine.wrap(api.get_panel_completions)(client, {
      doc = { uri = "file:///test.lua", position = { line = 0, character = 0 } },
      panelId = "1:file:///test.lua"
    })
    vim.wait(500, function() return #_G.notifications >= 3 end)
  ]])

  local notifications_count = child.lua("return #_G.notifications")
  -- 2 solutions + 1 done
  MiniTest.expect.equality(notifications_count, 3)
end

return T
