local prompts = require('gen.prompts')
local M = {}

local curr_buffer = nil
local start_pos = nil
local end_pos = nil

local last_prompt = nil
local last_response = nil

local function trim_table(tbl)
    local function is_whitespace(str) return str:match("^%s*$") ~= nil end

    while #tbl > 0 and (tbl[1] == "" or is_whitespace(tbl[1])) do
        table.remove(tbl, 1)
    end

    while #tbl > 0 and (tbl[#tbl] == "" or is_whitespace(tbl[#tbl])) do
        table.remove(tbl, #tbl)
    end

    return tbl
end

-- This generates a context string of the currently visible text in the
-- specified win_id (or the current window if none is specified)
-- Format:
-- filename:start_line-end_line
-- {visible_lines}
local function get_context(win_id)
  if not win_id then
    win_id = 0
  end

  local out

  vim.api.nvim_win_call(win_id, function()
    local filename = vim.fn.expand('%')
    local first_visible = vim.fn.line('w0')
    local last_visible = vim.fn.line('w$')

    local visible_lines = vim.api.nvim_buf_get_lines(0, first_visible - 1, last_visible, false)
    local header = string.format("%s:%d-%d", filename, first_visible, last_visible)

    out = header .. "\n" .. table.concat(visible_lines, '\n')
  end)

  return out
end

-- get the current set of changes for the file visible in win_id
local function get_diff(win_id)
  local out

  vim.api.nvim_win_call(win_id, function()
    local filename = vim.fn.expand('%')
    out = vim.fn.system("git diff " .. vim.fn.shellescape(filename))
  end)

  return out
end


-- this gets the context for every file in the current set of visible tabs
local function get_full_context()
  local contexts = {}
  for _, win_id in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    table.insert(contexts, get_context(win_id))
  end
  return table.concat(contexts, '\n'), #contexts
end

local function get_window_options()

    local width = math.floor(vim.o.columns * 0.9) -- 90% of the current editor's width
    local height = math.floor(vim.o.lines * 0.9)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local cursor = vim.api.nvim_win_get_cursor(0)
    local new_win_width = vim.api.nvim_win_get_width(0)
    local win_height = vim.api.nvim_win_get_height(0)

    local middle_row = win_height / 2

    local new_win_height = math.floor(win_height / 2)
    local new_win_row
    if cursor[1] <= middle_row then
        new_win_row = 5
    else
        new_win_row = -5 - new_win_height
    end

    return {
        relative = 'cursor',
        width = new_win_width,
        height = new_win_height,
        row = new_win_row,
        col = 0,
        style = 'minimal',
        border = 'single'
    }
end

M.command = 'ollama run $model $prompt'
M.model = 'mistral:instruct'


local function substitute_variable(text, variable, value)
  value = value or ""
  -- prevent the replacement escape sequences from being processed
  local escaped = string.gsub(value, "%%", "%%%%")
  text = string.gsub(text, "%$" .. variable, escaped)
  return text
end


M.exec = function(options)
    local opts = vim.tbl_deep_extend('force', {
        model = M.model,
        command = M.command
    }, options)
    pcall(io.popen, 'ollama serve > /dev/null 2>&1 &')
    curr_buffer = vim.fn.bufnr('%')
    local mode = opts.mode or vim.fn.mode()
    if mode == 'v' or mode == 'V' then
        start_pos = vim.fn.getpos("'<")
        end_pos = vim.fn.getpos("'>")
        end_pos[3] = vim.fn.col("'>") -- in case of `V`, it would be maxcol instead
    else
        local cursor = vim.fn.getpos('.')
        start_pos = cursor
        end_pos = start_pos
    end

    local content = table.concat(vim.api.nvim_buf_get_text(curr_buffer,
                                                           start_pos[2] - 1,
                                                           start_pos[3] - 1,
                                                           end_pos[2] - 1,
                                                           end_pos[3] - 1, {}),
                                 '\n')

    local function substitute_placeholders(input)
        if not input then return end

        text = input:gsub("%$([%w_]+)", function(var)
          if var == "filetype" then
            return vim.bo.filetype
          end

          if var == "text" then
            return content
          end

          if var == "input" then
            local answer = vim.fn.input("Prompt: ")
            return answer
          end

          if var == "register" then
            local register = vim.fn.getreg('"')
            if not register or register:match("^%s*$") then
              error("Prompt uses $register but yank register is empty")
            end
            return register
          end

          if var == "context" then
            return get_full_context()
          end

          if var == "diff" then
            return get_diff()
          end
        end)

        return text
    end

    local prompt = opts.prompt

    if type(prompt) == "function" then
      prompt = prompt({
        content = content,
        filetype = vim.bo.filetype,
      })
    end

    prompt = substitute_placeholders(prompt)
    last_prompt = prompt
    prompt = vim.fn.shellescape(last_prompt)

    local extractor = substitute_placeholders(opts.extract)
    local cmd = opts.command
    cmd = substitute_variable(cmd, "prompt", prompt)
    cmd = string.gsub(cmd, "%$model", opts.model)
    if result_buffer then vim.cmd('bd' .. result_buffer) end
    local win_opts = get_window_options()
    result_buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(result_buffer, 'filetype', 'markdown')

    local float_win = vim.api.nvim_open_win(result_buffer, true, win_opts)

    local result_string = ''
    local lines = {}
    local job_id = vim.fn.jobstart(cmd, {
        on_stdout = function(_, data, _)
            result_string = result_string .. table.concat(data, '\n')
            last_response = result_string

            lines = vim.split(result_string, '\n', true)
            vim.api.nvim_buf_set_lines(result_buffer, 0, -1, false, lines)
            vim.api.nvim_win_call(float_win, function()
              vim.fn.feedkeys('$')
            end)
        end,
        on_exit = function(a, b)
            if b == 0 and opts.replace then
                if extractor then
                    local extracted = result_string:match(extractor)
                    if not extracted then
                        vim.cmd('bd ' .. result_buffer)
                        return
                    end
                    lines = vim.split(extracted, '\n', true)
                end
                lines = trim_table(lines)
                vim.api.nvim_buf_set_text(curr_buffer, start_pos[2] - 1,
                                          start_pos[3] - 1, end_pos[2] - 1,
                                          end_pos[3] - 1, lines)
                vim.cmd('bd ' .. result_buffer)
            end
        end
    })
    vim.keymap.set('n', '<esc>', function() vim.fn.jobstop(job_id) end,
                   {buffer = result_buffer})

    vim.api.nvim_buf_attach(result_buffer, false,
                            {on_detach = function() result_buffer = nil end})

end

M.prompts = prompts
function select_prompt(cb)
    local promptKeys = {}
    for key, _ in pairs(M.prompts) do table.insert(promptKeys, key) end
    table.sort(promptKeys)
    vim.ui.select(promptKeys, {
        prompt = 'Prompt:',
        format_item = function(item)
            return table.concat(vim.split(item, '_'), ' ')
        end
    }, function(item, idx) cb(item) end)
end

vim.api.nvim_create_user_command('Gen', function(arg)
    local mode
    if arg.range == 0 then
        mode = 'n'
    else
        mode = 'v'
    end
    if arg.args ~= '' then
        local prompt = M.prompts[arg.args]
        if not prompt then
            print("Invalid prompt '" .. arg.args .. "'")
            return
        end
        p = vim.tbl_deep_extend('force', {mode = mode}, prompt)
        return M.exec(p)
    end
    select_prompt(function(item)
        p = vim.tbl_deep_extend('force', {mode = mode}, M.prompts[item])
        M.exec(p)
    end)

end, {
  range = true,
  nargs = '?',
  complete = function(ArgLead, CmdLine, CursorPos)
    local promptKeys = {}
    for key, _ in pairs(M.prompts) do
      if key:lower():match("^"..ArgLead:lower()) then
        table.insert(promptKeys, key)
      end
    end
    table.sort(promptKeys)
    return promptKeys
  end
})

vim.api.nvim_create_user_command('GenLastPrompt', function(arg)
  local float_buf = vim.api.nvim_create_buf(false, true)
  local float_win = vim.api.nvim_open_win(float_buf, true, get_window_options())

  local prompt_lines = last_prompt and vim.split(last_prompt, '\n', true) or {"No last prompt available"}
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, prompt_lines)
end, {})

vim.api.nvim_create_user_command('GenLastResponse', function(arg)
  local float_buf = vim.api.nvim_create_buf(false, true)
  local float_win = vim.api.nvim_open_win(float_buf, true, get_window_options())

  local response_lines = last_response and vim.split(last_response, '\n', true) or {"No last response available"}
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, response_lines)
end, {})

return M
