local M = {}

M.setup = function(opts)
  opts = opts or {}

  local api = vim.api

  -- ── Namespaces ──────────────────────────────────────────────────────────────
  local ns_status   = api.nvim_create_namespace("dafny_status")
  local ns_calltree = api.nvim_create_namespace("dafny_calltree")
  local ns_counter  = api.nvim_create_namespace("dafny_counter")

  -- ── State ───────────────────────────────────────────────────────────────────
  local symbol_status  = {}  -- [bufnr] = { [line] = { name, status_str, hl } }
  local doc_symbols    = {}  -- [bufnr] = { [name] = symbol }
  local calltree_shown = {}  -- [bufnr] = bool
  local counter_timers = {}  -- [bufnr] = uv timer

  -- ── Section 1: Status config ─────────────────────────────────────────────────
  -- Dafny 4.x enum: Stale=0, Queued=1, Running=2, (3 unused), Error=4, Correct=5
  local STATUS_INT = {
    [0] = { text = "?", hl = "Comment" },
    [1] = { text = "◌", hl = "DiagnosticHint" },
    [2] = { text = "◌", hl = "DiagnosticWarn" },
    [4] = { text = "✘", hl = "DiagnosticError" },
    [5] = { text = "✔", hl = "DiagnosticOk" },
  }

  local STATUS_STR = {
    Stale   = STATUS_INT[0],
    Queued  = STATUS_INT[1],
    Running = STATUS_INT[2],
    Error   = STATUS_INT[4],
    Correct = STATUS_INT[5],
  }

  local function status_info(s)
    if type(s) == "number" then
      return STATUS_INT[s] or STATUS_INT[0]
    end
    return STATUS_STR[s] or STATUS_INT[0]
  end

  -- ── Section 2a: Counter example fetch & render ──────────────────────────────
  local function clear_counters(bufnr)
    api.nvim_buf_clear_namespace(bufnr, ns_counter, 0, -1)
  end

  local function render_counters(bufnr, items)
    api.nvim_buf_clear_namespace(bufnr, ns_counter, 0, -1)
    if not items or #items == 0 then return end

    local sym_map = doc_symbols[bufnr]
    if not sym_map then return end

    local by_method = {}
    for _, item in ipairs(items) do
      local pos_line   = item.position and item.position.line
      local assumption = item.assumption
      if pos_line and assumption and assumption ~= "" then
        for _, sym in pairs(sym_map) do
          if sym.range then
            local s = sym.range.start.line
            local e = sym.range["end"].line
            if pos_line >= s and pos_line <= e then
              if not by_method[s] then
                by_method[s] = { sym = sym, assumptions = {} }
              end
              local dup = false
              for _, a in ipairs(by_method[s].assumptions) do
                if a == assumption then dup = true; break end
              end
              if not dup then table.insert(by_method[s].assumptions, assumption) end
              break
            end
          end
        end
      end
    end

    for _, data in pairs(by_method) do
      local sym  = data.sym
      local ok, lines = pcall(
        api.nvim_buf_get_lines, bufnr,
        sym.range.start.line, sym.range["end"].line + 1, false
      )
      if ok and lines then
        for i, line in ipairs(lines) do
          if line:match("^%s*requires%s") or line:match("^%s*ensures%s") then
            local virt_lines = {}
            for _, assumption in ipairs(data.assumptions) do
              table.insert(virt_lines, {
                { "  │ ", "Comment" },
                { "✗ ",   "DiagnosticError" },
                { assumption, "DiagnosticWarn" },
              })
            end
            api.nvim_buf_set_extmark(bufnr, ns_counter, sym.range.start.line + i - 1, 0, {
              virt_lines = virt_lines,
            })
          end
        end
      end
    end
  end

  local function fetch_counter_examples(bufnr)
    local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "dafny" })
    if #clients == 0 then return end
    clients[1]:request("dafny/counterExample", {
      textDocument        = { uri = vim.uri_from_bufnr(bufnr) },
      counterExampleDepth = opts.counter_example_depth or 5,
    }, function(err, result)
      if err or not result then return end
      render_counters(bufnr, result)
    end, bufnr)
  end

  local function schedule_counter_fetch(bufnr)
    local t = counter_timers[bufnr]
    if t then t:stop(); t:close() end
    local timer = vim.uv.new_timer()
    counter_timers[bufnr] = timer
    timer:start(opts.counter_debounce_ms or 1000, 0, vim.schedule_wrap(function()
      timer:stop(); timer:close()
      counter_timers[bufnr] = nil
      fetch_counter_examples(bufnr)
    end))
  end

  -- ── Section 2b: symbolStatus handler ────────────────────────────────────────
  vim.lsp.handlers["dafny/textDocument/symbolStatus"] = function(_, result, ctx)
    if not result then return end

    local bufnr = ctx.bufnr
    if not bufnr or bufnr == 0 or not api.nvim_buf_is_valid(bufnr) then
      if result.uri then bufnr = vim.uri_to_bufnr(result.uri) end
    end
    if not bufnr or not api.nvim_buf_is_valid(bufnr) then return end

    symbol_status[bufnr] = {}
    local has_error = false

    for _, nv in ipairs(result.namedVerifiables or {}) do
      local range = nv.nameRange
      if range then
        local sl = range.start.line
        local ok, lines = pcall(api.nvim_buf_get_text, bufnr, sl, range.start.character, sl, range["end"].character, {})
        local name = (ok and lines and lines[1]) or "?"
        local info = status_info(nv.status)
        symbol_status[bufnr][sl] = { name = name, status_str = info.text, hl = info.hl }
        if nv.status == 4 then has_error = true end
      end
    end

    api.nvim_buf_clear_namespace(bufnr, ns_status, 0, -1)
    for line, entry in pairs(symbol_status[bufnr]) do
      api.nvim_buf_set_extmark(bufnr, ns_status, line, 0, {
        virt_text     = { { "  " .. entry.status_str, entry.hl } },
        virt_text_pos = "eol",
      })
    end

    if has_error then
      schedule_counter_fetch(bufnr)
    else
      local t = counter_timers[bufnr]
      if t then t:stop(); t:close(); counter_timers[bufnr] = nil end
      clear_counters(bufnr)
    end
  end

  -- ── Section 3: fetch_symbols ─────────────────────────────────────────────────
  local function fetch_symbols(bufnr, cb)
    local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
    vim.lsp.buf_request(bufnr, "textDocument/documentSymbol", params, function(err, result)
      if err or not result then cb(nil); return end
      local flat = {}
      local function flatten(symbols)
        for _, sym in ipairs(symbols) do
          flat[sym.name] = sym
          if sym.children then flatten(sym.children) end
        end
      end
      flatten(result)
      doc_symbols[bufnr] = flat
      cb(flat)
    end)
  end

  -- ── Section 4: Call tree algorithm ──────────────────────────────────────────
  local function find_calls_in_text(text, known_names)
    local found, seen = {}, {}
    for raw in text:gmatch("[A-Za-z_][A-Za-z0-9_']*%s*%(") do
      local name = raw:match("^([A-Za-z_][A-Za-z0-9_']*)")
      if name and known_names[name] and not seen[name] then
        seen[name] = true
        table.insert(found, name)
      end
    end
    return found
  end

  local function build_tree(bufnr, name, sym_map, visited, depth)
    depth = depth or 0
    local sym  = sym_map[name]
    local info = STATUS_INT[0]
    if sym and sym.range and symbol_status[bufnr] then
      local entry = symbol_status[bufnr][sym.range.start.line]
      if entry then info = { text = entry.status_str, hl = entry.hl } end
    end
    if depth >= 5 then
      return { name = name, status = info.text, hl = info.hl, children = {} }
    end
    if visited[name] then
      return { name = name, status = info.text, hl = info.hl, children = {}, cyclic = true }
    end
    visited[name] = true
    local children = {}
    if sym and sym.range then
      local r = sym.range
      local ok, lines = pcall(api.nvim_buf_get_lines, bufnr, r.start.line, r["end"].line + 1, false)
      if ok and lines then
        for _, callee in ipairs(find_calls_in_text(table.concat(lines, "\n"), sym_map)) do
          if callee ~= name then
            table.insert(children, build_tree(bufnr, callee, sym_map, visited, depth + 1))
          end
        end
      end
    end
    visited[name] = nil
    return { name = name, status = info.text, hl = info.hl, children = children }
  end

  -- ── Section 5: Call tree rendering ──────────────────────────────────────────
  local function render_calltree(bufnr, tree, anchor_line)
    api.nvim_buf_clear_namespace(bufnr, ns_calltree, 0, -1)
    local virt_lines = {}
    local function add_line(text, hl)
      table.insert(virt_lines, { { text, hl or "Normal" } })
    end
    local function render_node(node, prefix, is_last, is_root)
      if is_root then
        for i, child in ipairs(node.children) do
          render_node(child, "│ ", i == #node.children, false)
        end
      else
        local conn  = is_last and "└─ " or "├─ "
        local label = prefix .. conn .. "[" .. node.status .. "] " .. node.name
        if node.cyclic then label = label .. " (↺)" end
        add_line(label, node.hl)
        local child_prefix = prefix .. (is_last and "   " or "│  ")
        for i, child in ipairs(node.children) do
          render_node(child, child_prefix, i == #node.children, false)
        end
      end
    end
    render_node(tree, "", false, true)
    if #virt_lines > 0 then
      api.nvim_buf_set_extmark(bufnr, ns_calltree, anchor_line, 0, {
        virt_lines = virt_lines,
      })
    end
    calltree_shown[bufnr] = true
  end

  local function clear_calltree(bufnr)
    api.nvim_buf_clear_namespace(bufnr, ns_calltree, 0, -1)
    calltree_shown[bufnr] = false
  end

  -- ── Section 6: verify_symbol ─────────────────────────────────────────────────
  local function verify_symbol(bufnr, line, char)
    vim.lsp.buf_request(bufnr, "dafny/textDocument/verifySymbol", {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      position     = { line = line, character = char },
    }, function() end)
  end

  -- ── Section 7: Commands ──────────────────────────────────────────────────────
  vim.api.nvim_create_user_command("DafnyStatus", function()
    local bufnr   = api.nvim_get_current_buf()
    local c, e, r = 0, 0, 0
    for _, entry in pairs(symbol_status[bufnr] or {}) do
      if     entry.status_str == "✔" then c = c + 1
      elseif entry.status_str == "✘" then e = e + 1
      elseif entry.status_str == "◌" then r = r + 1
      end
    end
    vim.notify(("Dafny: ✔ %d  ✘ %d  ◌ %d"):format(c, e, r), vim.log.levels.INFO)
  end, {})

  vim.api.nvim_create_user_command("DafnyCallTree", function()
    local bufnr = api.nvim_get_current_buf()
    if calltree_shown[bufnr] then clear_calltree(bufnr); return end
    local cursor_line = api.nvim_win_get_cursor(0)[1] - 1
    fetch_symbols(bufnr, function(sym_map)
      if not sym_map then
        vim.notify("DafnyCallTree: could not fetch symbols", vim.log.levels.WARN)
        return
      end
      local target, anchor = nil, cursor_line
      for name, sym in pairs(sym_map) do
        if sym.range then
          local s, e = sym.range.start.line, sym.range["end"].line
          if cursor_line >= s and cursor_line <= e then
            target, anchor = name, s; break
          end
        end
      end
      if not target then
        vim.notify("DafnyCallTree: no symbol at cursor", vim.log.levels.WARN)
        return
      end
      render_calltree(bufnr, build_tree(bufnr, target, sym_map, {}, 0), anchor)
    end)
  end, {})

  vim.api.nvim_create_user_command("DafnyVerifyTree", function()
    local bufnr       = api.nvim_get_current_buf()
    local cursor_line = api.nvim_win_get_cursor(0)[1] - 1
    fetch_symbols(bufnr, function(sym_map)
      if not sym_map then
        vim.notify("DafnyVerifyTree: could not fetch symbols", vim.log.levels.WARN)
        return
      end
      local root = nil
      for name, sym in pairs(sym_map) do
        if sym.range then
          local s, e = sym.range.start.line, sym.range["end"].line
          if cursor_line >= s and cursor_line <= e then root = name; break end
        end
      end
      if not root then
        vim.notify("DafnyVerifyTree: no symbol at cursor", vim.log.levels.WARN)
        return
      end
      local to_verify, seen = {}, {}
      local function collect(name, depth)
        if depth > 5 or seen[name] then return end
        seen[name] = true
        table.insert(to_verify, name)
        local sym = sym_map[name]
        if sym and sym.range then
          local ok, lines = pcall(api.nvim_buf_get_lines, bufnr, sym.range.start.line, sym.range["end"].line + 1, false)
          if ok and lines then
            for _, callee in ipairs(find_calls_in_text(table.concat(lines, "\n"), sym_map)) do
              collect(callee, depth + 1)
            end
          end
        end
      end
      collect(root, 0)
      vim.notify(("DafnyVerifyTree: triggering verification for %d symbols"):format(#to_verify), vim.log.levels.INFO)
      for _, name in ipairs(to_verify) do
        local sym = sym_map[name]
        if sym and sym.range then
          verify_symbol(bufnr, sym.range.start.line, sym.range.start.character)
        end
      end
    end)
  end, {})

  -- ── Section 8: LspAttach ─────────────────────────────────────────────────────
  vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client or client.name ~= "dafny" then return end
      local bufnr = args.buf
      local opts_ = { buffer = bufnr, silent = true }
      vim.keymap.set("n", "<leader>ds", "<cmd>DafnyStatus<cr>",    opts_)
      vim.keymap.set("n", "<leader>dt", "<cmd>DafnyCallTree<cr>",  opts_)
      vim.keymap.set("n", "<leader>dv", "<cmd>DafnyVerifyTree<cr>", opts_)
      vim.defer_fn(function()
        if api.nvim_buf_is_valid(bufnr) then
          fetch_symbols(bufnr, function() end)
        end
      end, 500)
    end,
  })
end

return M
