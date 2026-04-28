--- git-hunk-undo.nvim
--- IntelliJ-style per-hunk git rollback for Neovim.
---
--- Reverts individual git hunks back to HEAD directly inside the buffer,
--- using gitsigns.nvim for buffer-aware hunk data. Because it is purely
--- git-state driven it works across buffer reloads and session restarts.
---
--- @module "git-hunk-undo"

local M = {}

-- ─── Internal helpers ─────────────────────────────────────────────────────────

--- @return table[]|nil
local function get_hunks(bufnr)
  local ok, gs = pcall(require, "gitsigns")
  if not ok then
    vim.notify("[git-hunk-undo] gitsigns.nvim is not loaded", vim.log.levels.ERROR)
    return nil
  end
  local hunks = gs.get_hunks(bufnr)
  return (hunks and #hunks > 0) and hunks or nil
end

--- Last buffer line (1-indexed) belonging to a hunk.
--- @param h table  gitsigns Hunk_Public
--- @return integer
local function hunk_end(h)
  return h.added.start + math.max(h.added.count - 1, 0)
end

--- Return the hunk the cursor is on.
--- Deletion hunks have no added lines; gitsigns places their gutter sign
--- at `added.start - 1`, so accept that line too.
--- @param hunks table[]
--- @param line  integer  1-indexed
--- @return table|nil
local function hunk_at_line(hunks, line)
  for _, h in ipairs(hunks) do
    if h.type == "delete" then
      local sign_line = math.max(h.added.start - 1, 1)
      if line == sign_line or line == h.added.start then
        return h
      end
    elseif line >= h.added.start and line <= hunk_end(h) then
      return h
    end
  end
end

--- Build the diff preview lines for a hunk.
--- @param h table
--- @return string[]
local function hunk_display_lines(h)
  local lines = { h.head }
  vim.list_extend(lines, h.lines)
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end
  return lines
end

--- Open a small floating window showing diff content.
--- @param lines   string[]
--- @param title   string
--- @param focused boolean  steal focus when true
--- @return integer win, integer buf
local function open_float(lines, title, focused)
  local width  = math.min(82, vim.o.columns - 4)
  local height = math.min(#lines, math.floor(vim.o.lines * 0.4))
  height = math.max(height, 1)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype   = "diff"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden  = "wipe"

  local win = vim.api.nvim_open_win(buf, focused, {
    relative  = "cursor",
    row = 1, col = 0,
    width     = width,
    height    = height,
    style     = "minimal",
    border    = "rounded",
    title     = " " .. title .. " ",
    title_pos = "center",
  })

  return win, buf
end

-- ─── Public API ───────────────────────────────────────────────────────────────

--- Revert the git hunk under the cursor back to HEAD.
--- Shows a confirmation float with the diff before applying.
function M.undo_hunk()
  local bufnr    = vim.api.nvim_get_current_buf()
  local orig_win = vim.api.nvim_get_current_win()

  local hunks = get_hunks(bufnr)
  if not hunks then
    vim.notify("No git changes in this buffer", vim.log.levels.INFO)
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local hunk = hunk_at_line(hunks, line)
  if not hunk then
    vim.notify("No git change under cursor", vim.log.levels.WARN)
    return
  end

  local display = hunk_display_lines(hunk)
  vim.list_extend(display, { "", "  <Enter>/<y> revert  ·  <Esc>/<q> cancel" })

  -- Pass an explicit range so reset_hunk is not affected by the focus shift
  local range = {
    hunk.added.start,
    math.max(hunk.added.start + hunk.added.count - 1, hunk.added.start),
  }

  local win, buf = open_float(
    display,
    string.format("Revert %s hunk?", hunk.type),
    true
  )

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local kopts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q",     close,                                kopts)
  vim.keymap.set("n", "<Esc>", close,                                kopts)
  vim.keymap.set("n", "y",  function()
    close()
    if vim.api.nvim_win_is_valid(orig_win) then
      vim.api.nvim_set_current_win(orig_win)
    end
    require("gitsigns").reset_hunk(range)
    vim.notify("Hunk reverted", vim.log.levels.INFO)
  end, kopts)
  vim.keymap.set("n", "<CR>", function()
    close()
    if vim.api.nvim_win_is_valid(orig_win) then
      vim.api.nvim_set_current_win(orig_win)
    end
    require("gitsigns").reset_hunk(range)
    vim.notify("Hunk reverted", vim.log.levels.INFO)
  end, kopts)
end

--- Show a non-focused diff preview of the hunk under the cursor.
--- Closes automatically when the cursor moves or the buffer is left.
function M.preview_hunk()
  local bufnr = vim.api.nvim_get_current_buf()

  local hunks = get_hunks(bufnr)
  if not hunks then
    vim.notify("No git changes in this buffer", vim.log.levels.INFO)
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local hunk = hunk_at_line(hunks, line)
  if not hunk then
    vim.notify("No git change under cursor", vim.log.levels.WARN)
    return
  end

  local win, buf = open_float(hunk_display_lines(hunk), "Hunk Preview", false)

  local function close_win()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "q",     close_win, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", close_win, { buffer = buf, silent = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave" }, {
    once     = true,
    callback = close_win,
  })
end

--- Jump to the next git hunk (delegates to gitsigns).
function M.next_hunk()
  require("gitsigns").next_hunk()
end

--- Jump to the previous git hunk (delegates to gitsigns).
function M.prev_hunk()
  require("gitsigns").prev_hunk()
end

-- ─── Setup ────────────────────────────────────────────────────────────────────

--- Configure git-hunk-undo.
---
--- @param opts table|nil
---   opts.keymaps  table|false
---     Keymap overrides. Set a key to `false` to disable that individual
---     binding. Set `keymaps = false` to disable all default keymaps.
---     Defaults:
---       undo_hunk    = "<leader>gU"
---       preview_hunk = "<leader>gP"
---       next_hunk    = "]H"
---       prev_hunk    = "[H"
function M.setup(opts)
  opts = opts or {}

  vim.api.nvim_create_user_command("GitUndoHunk",    M.undo_hunk,    { desc = "Revert git hunk under cursor" })
  vim.api.nvim_create_user_command("GitPreviewHunk", M.preview_hunk, { desc = "Preview git hunk under cursor" })
  vim.api.nvim_create_user_command("GitNextHunk",    M.next_hunk,    { desc = "Jump to next git hunk" })
  vim.api.nvim_create_user_command("GitPrevHunk",    M.prev_hunk,    { desc = "Jump to previous git hunk" })

  if opts.keymaps == false then return end

  local keys = vim.tbl_extend("force", {
    undo_hunk    = "<leader>gU",
    preview_hunk = "<leader>gP",
    next_hunk    = "]H",
    prev_hunk    = "[H",
  }, opts.keymaps or {})

  local function kmap(lhs, fn, desc)
    if lhs ~= false then
      vim.keymap.set("n", lhs, fn, { desc = desc, silent = true })
    end
  end
  kmap(keys.undo_hunk,    M.undo_hunk,    "Git: revert hunk under cursor")
  kmap(keys.preview_hunk, M.preview_hunk, "Git: preview hunk")
  kmap(keys.next_hunk,    M.next_hunk,    "Git: next hunk")
  kmap(keys.prev_hunk,    M.prev_hunk,    "Git: previous hunk")
end

return M
