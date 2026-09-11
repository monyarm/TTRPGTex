-- randomtable.lua
-- Reads a CSV and emits a tabularx table for a TTRPG random-roll table,
-- with a "dN" die column auto-generated and prepended.
--
-- Called by \RandomTable{csvpath} defined in ttrpg-core.sty.
--
-- CSV format: first row = column headers for the data columns (everything
-- except the die column, which is not present as regular data — see
-- "dice" below). Each remaining row is one roll result. Fields containing
-- commas must be quoted with double quotes.
--
-- By default each row consumes exactly one die value, numbered 1..N where
-- N is the number of data rows.
--
-- Optional "dice" column: if a header named "dice" (case-insensitive) is
-- present, its value for a row is how many consecutive die values that
-- row covers, instead of the default 1. E.g. four normal rows (1,2,3,4)
-- followed by a row with dice=5 covers 5-9, and the header becomes "d9"
-- (the running total, not the row count). A blank/missing "dice" value
-- for a row defaults to 1. The "dice" column itself is never displayed —
-- it only controls numbering.
--
-- Column layout: the die column is centered; the first displayed data
-- column stretches to fill the remaining table width (tabularx "X"); any
-- further columns are centered. This matches the common "d10 | Name | Qty
-- | Value"-shaped random tables used throughout these books.
--
-- Place this file in _library/lua/ alongside ttrpg-core.sty.

local M = {}
local utils = require("utils")

function M.generate(csv_path)
  local resolved = csv_path
  if kpse and kpse.find_file then
    resolved = kpse.find_file(csv_path) or csv_path
  end

  local rows = utils.parse_csv(resolved)
  if #rows == 0 then
    error("randomtable: CSV '" .. csv_path .. "' is empty")
  end

  local header = rows[1]

  -- Find an optional "dice" column (case-insensitive); it is excluded
  -- from the displayed columns and instead controls die numbering.
  local dice_col = nil
  for i, h in ipairs(header) do
    if tostring(h):lower() == "dice" then
      dice_col = i
      break
    end
  end

  local display_cols = {}
  for i = 1, #header do
    if i ~= dice_col then
      display_cols[#display_cols + 1] = i
    end
  end

  -- First pass: compute each row's die label (single number or "a-b")
  -- and the running total, before the header (which needs the total) is
  -- printed.
  local labels = {}
  local next_die = 1
  for i = 2, #rows do
    local row   = rows[i]
    local width = 1
    if dice_col then
      local raw = row[dice_col]
      local num = raw and tonumber(raw)
      if num and num >= 1 then
        width = math.floor(num)
      end
    end
    local start_die = next_die
    local end_die   = next_die + width - 1
    labels[#labels + 1] = (width == 1)
      and tostring(start_die)
      or (tostring(start_die) .. "-" .. tostring(end_die))
    next_die = end_die + 1
  end
  local n = next_die - 1 -- total die count

  local spec = {"c"}
  for i = 1, #display_cols do
    spec[#spec + 1] = (i == 1) and "X" or "c"
  end
  local colspec = "|" .. table.concat(spec, "|") .. "|"

  tex.print("\\begin{tabularx}{\\linewidth}{" .. colspec .. "}")
  tex.print("\\hline")

  local headerline = {"\\textbf{d" .. n .. "}"}
  for _, c in ipairs(display_cols) do
    headerline[#headerline + 1] = "\\textbf{" .. (header[c] or "") .. "}"
  end
  tex.print(table.concat(headerline, " & ") .. " \\\\")
  tex.print("\\hline")

  for i = 2, #rows do
    local row  = rows[i]
    local line = {labels[i - 1]}
    for _, c in ipairs(display_cols) do
      line[#line + 1] = row[c] or ""
    end
    tex.print(table.concat(line, " & ") .. " \\\\")
  end

  tex.print("\\hline")
  tex.print("\\end{tabularx}")
end

return M
