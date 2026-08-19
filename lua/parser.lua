-- parser.lua
-- JSON → LaTeX transpiler for the ttrpg publishing engine.
--
-- Reads a .json source file and writes a corresponding .tex cache file to
-- .ttrpg_cache/.  Each JSON key is mapped to a pair of \csname macros:
--
--   \csname db@<key>@exists\endcsname{}   ← existence sentinel (empty def)
--   \csname db@<key>\endcsname{<value>}   ← the actual value
--
-- Nested objects are flattened with "@" as the separator:
--   {"stats": {"hp": 10}}  →  \csname db@stats@hp\endcsname{10}
--
-- Arrays use 1-based numeric suffixes and a @count sentinel:
--   {"tags": ["fire","cold"]}
--     →  \csname db@tags@1\endcsname{fire}
--        \csname db@tags@2\endcsname{cold}
--        \csname db@tags@count\endcsname{2}
--
-- The cache file ends with a call to the user's formatting macro so that
-- LaTeX renders the entry as soon as the file is \input or \included.
--
-- Place this file in _library/lua/ alongside ttrpg-core.sty.
-- Loaded by: scanner.lua (which calls M.parse)

local utils = require("utils")
local lfs = require("lfs")

local M = {}

-- ── JSON loader ───────────────────────────────────────────────────────────────
-- dkjson ships with TeX Live; try the standard require path first, then fall
-- back to locating it via kpse so it works in edge-case TeX Live installs.

local json_decode
do
  local ok, mod = pcall(require, "dkjson")
  if ok and mod and type(mod.decode) == "function" then
    json_decode = mod.decode
  else
    -- Fallback for TeX Live installs without dkjson.lua in kpse path.
    local ok_lualibs = pcall(require, "lualibs")
    if ok_lualibs and utilities and utilities.json and type(utilities.json.tolua) == "function" then
      json_decode = function(src)
        local ok_decode, data, pos, err = pcall(utilities.json.tolua, src)
        if ok_decode then
          return data, pos, err
        end
        return nil, nil, data
      end
    else
      local p = kpse.find_file("dkjson.lua", "lua")
      if not p then
        error(
          "parser: no JSON decoder available (dkjson/lualibs). " ..
          "Install TeX Live lualibs or provide dkjson.lua."
        )
      end
      local json = dofile(p)
      if not json or type(json.decode) ~= "function" then
        error("parser: dkjson.lua loaded but does not expose decode()")
      end
      json_decode = json.decode
    end
  end
end

-- ── Recursive definition emitter ─────────────────────────────────────────────

-- emit_defs(tbl, prefix, lines)
--
-- Walks a decoded JSON table recursively, appending \def lines to `lines`.
--
-- Parameters:
--   tbl    – a Lua table (decoded from JSON)
--   prefix – the csname prefix accumulated so far (empty string at top level)
--   lines  – an array (table) of strings that will be joined into the output
--
-- The function distinguishes three value types:
--   • Scalar (string/number/boolean/null): emits two lines (exists + value).
--   • Array  (table whose first key is a positive integer): recurse with
--     numeric suffixes "@1", "@2", …; also emit a "@count" sentinel.
--   • Object (table with non-integer keys): recurse with the sanitized key
--     appended to the prefix; also emit an "@exists" sentinel for the
--     composite key itself so \ifhas{stats}{} works for nested objects.
local function csname_db(prefix, suffix)
  if prefix == "" then
    return "db@" .. suffix
  end
  return "db@" .. prefix .. "@" .. suffix
end

local function json_scalar_type(v)
  local t = type(v)
  if t == "string" or t == "number" or t == "boolean" then
    return t
  end
  if v == nil then
    return "null"
  end
  return t
end

local function extract_object_key_order(src)
  local i = 1
  local n = #src
  local order = {}

  local function skip_ws()
    while i <= n do
      local c = src:sub(i, i)
      if c == " " or c == "\n" or c == "\r" or c == "\t" then
        i = i + 1
      else
        break
      end
    end
  end

  local function parse_string()
    if src:sub(i, i) ~= '"' then return nil, "expected string" end
    i = i + 1
    local out = {}
    while i <= n do
      local c = src:sub(i, i)
      if c == '"' then
        i = i + 1
        return table.concat(out), nil
      end
      if c == "\\" then
        local esc = src:sub(i + 1, i + 1)
        if esc == '"' or esc == "\\" or esc == "/" then
          out[#out + 1] = esc
          i = i + 2
        elseif esc == "b" then
          out[#out + 1] = "\b"
          i = i + 2
        elseif esc == "f" then
          out[#out + 1] = "\f"
          i = i + 2
        elseif esc == "n" then
          out[#out + 1] = "\n"
          i = i + 2
        elseif esc == "r" then
          out[#out + 1] = "\r"
          i = i + 2
        elseif esc == "t" then
          out[#out + 1] = "\t"
          i = i + 2
        elseif esc == "u" then
          local hex = src:sub(i + 2, i + 5)
          if #hex ~= 4 or not hex:match("^[0-9a-fA-F]+$") then
            return nil, "invalid unicode escape"
          end
          local codepoint = tonumber(hex, 16)
          if codepoint then
            out[#out + 1] = utf8.char(codepoint)
          end
          i = i + 6
        else
          return nil, "invalid escape"
        end
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
    return nil, "unterminated string"
  end

  local parse_value

  local function parse_array(path)
    if src:sub(i, i) ~= "[" then return "expected [" end
    i = i + 1
    skip_ws()
    local idx = 1
    if src:sub(i, i) == "]" then
      i = i + 1
      return nil
    end
    while i <= n do
      local item_path = path .. "@" .. idx
      local err = parse_value(item_path)
      if err then return err end
      idx = idx + 1
      skip_ws()
      local c = src:sub(i, i)
      if c == "," then
        i = i + 1
        skip_ws()
      elseif c == "]" then
        i = i + 1
        return nil
      else
        return "expected , or ]"
      end
    end
    return "unterminated array"
  end

  local function parse_object(path)
    if src:sub(i, i) ~= "{" then return "expected {" end
    i = i + 1
    skip_ws()
    local keys = {}
    order[path] = keys
    if src:sub(i, i) == "}" then
      i = i + 1
      return nil
    end
    while i <= n do
      local raw_key, key_err = parse_string()
      if key_err then return key_err end
      keys[#keys + 1] = raw_key
      local safe_key = utils.sanitize_key(raw_key)
      local child_path = (path == "") and safe_key or (path .. "@" .. safe_key)
      skip_ws()
      if src:sub(i, i) ~= ":" then return "expected :" end
      i = i + 1
      skip_ws()
      local err = parse_value(child_path)
      if err then return err end
      skip_ws()
      local c = src:sub(i, i)
      if c == "," then
        i = i + 1
        skip_ws()
      elseif c == "}" then
        i = i + 1
        return nil
      else
        return "expected , or }"
      end
    end
    return "unterminated object"
  end

  function parse_value(path)
    skip_ws()
    local c = src:sub(i, i)
    if c == "{" then
      return parse_object(path)
    elseif c == "[" then
      return parse_array(path)
    elseif c == '"' then
      local _, err = parse_string()
      return err
    elseif c == "-" or c:match("%d") then
      local s, e = src:find("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
      if not s then return "invalid number" end
      i = e + 1
      return nil
    elseif src:sub(i, i + 3) == "true" then
      i = i + 4
      return nil
    elseif src:sub(i, i + 4) == "false" then
      i = i + 5
      return nil
    elseif src:sub(i, i + 3) == "null" then
      i = i + 4
      return nil
    end
    return "invalid value"
  end

  local err = parse_value("")
  if err then
    return {}
  end
  return order
end

local function emit_defs(tbl, prefix, lines, order_map, exists_marker)
  if type(tbl) ~= "table" then return end

  -- Emit ordered key metadata for object tables so LaTeX templates can
  -- iterate key/value pairs (e.g. class_lists) and access display key names.
  local key_entries = {}
  local unsorted = {}
  for k, v in pairs(tbl) do
    if type(k) ~= "number" then
      unsorted[tostring(k)] = v
    end
  end

  local seen = {}
  local ordered_keys = order_map and order_map[prefix]
  if ordered_keys then
    for _, raw_k in ipairs(ordered_keys) do
      if unsorted[raw_k] ~= nil then
        key_entries[#key_entries + 1] = {
          raw = raw_k,
          safe = utils.sanitize_key(raw_k),
          value = unsorted[raw_k],
        }
        seen[raw_k] = true
      end
    end
  end

  for raw_k, v in pairs(unsorted) do
    if not seen[raw_k] then
      key_entries[#key_entries + 1] = {
        raw = raw_k,
        safe = utils.sanitize_key(raw_k),
        value = v,
      }
    end
  end

  lines[#lines + 1] =
    "\\expandafter\\def\\csname " .. csname_db(prefix, "keys@count") ..
    "\\endcsname{" .. #key_entries .. "}"
  for i, e in ipairs(key_entries) do
    lines[#lines + 1] =
      "\\expandafter\\def\\csname " .. csname_db(prefix, "keys@" .. i) ..
      "\\endcsname{" .. utils.escape_tex_value(e.raw) .. "}"
    lines[#lines + 1] =
      "\\expandafter\\def\\csname " .. csname_db(prefix, "keys@" .. i .. "@safe") ..
      "\\endcsname{" .. e.safe .. "}"
  end

  for _, entry in ipairs(key_entries) do
    local safe_k = entry.safe
    local v = entry.value
    local full_key = (prefix == "") and safe_k or (prefix .. "@" .. safe_k)

    if type(v) == "table" then
      -- Distinguish array (sequence) from object (hash map).
      -- A table is treated as an array when it has at least one entry at
      -- key [1].  Mixed tables (both integer and string keys) are unusual
      -- in TTRPG data; they are handled gracefully: integer keys are
      -- processed as array elements, non-integer keys are ignored at this
      -- level (they would require a separate pass and are uncommon enough
      -- not to warrant the complexity).
      if v[1] ~= nil then
        -- ── Array branch ──
        lines[#lines + 1] =
          "\\expandafter\\def\\csname db@" .. full_key .. "@type\\endcsname{array}"
        local count = 0
        for i, item in ipairs(v) do
          local elem_key = full_key .. "@" .. i
          if type(item) == "table" then
            -- Array of objects: recurse with numeric prefix
            emit_defs(item, elem_key, lines, order_map, exists_marker)
            -- Mark the slot as existing
            lines[#lines + 1] =
              "\\expandafter\\def\\csname db@" .. elem_key .. "@exists\\endcsname{" .. exists_marker .. "}"
          else
            -- Array of scalars
            local escaped = utils.escape_tex_value(item)
            local item_type = json_scalar_type(item)
            lines[#lines + 1] =
              "\\expandafter\\def\\csname db@" .. elem_key .. "@exists\\endcsname{" .. exists_marker .. "}"
            lines[#lines + 1] =
              "\\expandafter\\def\\csname db@" .. elem_key .. "\\endcsname{" .. escaped .. "}"
            lines[#lines + 1] =
              "\\expandafter\\def\\csname db@" .. elem_key .. "@type\\endcsname{" .. item_type .. "}"
          end
          count = i
        end
        -- Emit the count sentinel: \get{tags@count} → "3"
        lines[#lines + 1] =
          "\\expandafter\\def\\csname db@" .. full_key .. "@count\\endcsname{" .. count .. "}"
      else
        -- ── Object branch ──
        lines[#lines + 1] =
          "\\expandafter\\def\\csname db@" .. full_key .. "@type\\endcsname{object}"
        emit_defs(v, full_key, lines, order_map, exists_marker)
      end
      -- Mark the composite key itself as existing so \ifhas{stats}{} works
      lines[#lines + 1] =
        "\\expandafter\\def\\csname db@" .. full_key .. "@exists\\endcsname{" .. exists_marker .. "}"

    else
      -- ── Scalar branch ──
      -- JSON null becomes an empty string
      local scalar_type = json_scalar_type(v)
      local escaped = (v == nil) and "" or utils.escape_tex_value(v)
      lines[#lines + 1] =
        "\\expandafter\\def\\csname db@" .. full_key .. "@exists\\endcsname{" .. exists_marker .. "}"
      lines[#lines + 1] =
        "\\expandafter\\def\\csname db@" .. full_key .. "\\endcsname{" .. escaped .. "}"
      lines[#lines + 1] =
        "\\expandafter\\def\\csname db@" .. full_key .. "@type\\endcsname{" .. scalar_type .. "}"
    end
  end
end

-- ── Public entry point ────────────────────────────────────────────────────────

-- parse(json_path, cache_path, user_macro, file_stem) → boolean
--
-- Reads the JSON file at `json_path`, converts it to LaTeX definitions, and
-- writes the result to `cache_path`.
--
-- Parameters:
--   json_path   – path to the .json source (relative to cwd or absolute)
--   cache_path  – path to the .tex file to (over)write
--   user_macro  – name of the formatting macro WITHOUT backslash
--                 (e.g. "MonsterCard").  Called at the end of the cache file
--                 so LaTeX renders the entry on \input / \include.
--   file_stem   – short identifier stored in \currentfile inside the cache
--                 (typically the cache stem, e.g. "monsters--goblin")
--
-- Returns true on success, false on any error (message written to stderr).
function M.parse(json_path, cache_path, user_macro, file_stem)
  -- ── Read source ────────────────────────────────────────────────────────────
  utils.force_tex_input_record(json_path)

  local f, open_err = io.open(json_path, "r")
  if not f then
    io.stderr:write(
      "parser: cannot open '" .. json_path .. "': " .. tostring(open_err) .. "\n"
    )
    return false
  end
  local src = f:read("*a")
  f:close()

  -- ── Decode JSON ────────────────────────────────────────────────────────────
  local data, _, decode_err = json_decode(src)
  if not data then
    -- Common authoring convenience: allow a trailing comma before } or ].
    local cleaned = src:gsub(",(%s*[}%]])", "%1")
    if cleaned ~= src then
      data, _, decode_err = json_decode(cleaned)
    end
  end
  if not data then
    io.stderr:write(
      "parser: JSON decode error in '" .. json_path .. "': " ..
      tostring(decode_err) .. "\n"
    )
    return false
  end
  if type(data) ~= "table" then
    io.stderr:write(
      "parser: top-level JSON value in '" .. json_path ..
      "' must be an object or array, got " .. type(data) .. "\n"
    )
    return false
  end

  -- ── Build output lines ─────────────────────────────────────────────────────
  local lines = {}

  -- Header comment
  lines[#lines + 1] = "% Auto-generated by parser.lua — do not edit manually."
  lines[#lines + 1] = "% Source: " .. json_path
  lines[#lines + 1] = "\\directlua{require(\"utils\").force_tex_input_record(" .. string.format("%q", json_path) .. ")}"
  lines[#lines + 1] = ""

  -- \currentfile lets the formatting macro know which entry it is rendering,
  -- which is useful for debugging or conditional formatting.
  lines[#lines + 1] =
    "\\def\\currentfile{" .. utils.escape_tex_value(file_stem) .. "}"
  lines[#lines + 1] = ""

  -- Recursively emit all key → value definitions
  local order_map = extract_object_key_order(src)
  local exists_marker = utils.escape_tex_value(file_stem)
  emit_defs(data, "", lines, order_map, exists_marker)
  lines[#lines + 1] = ""

  -- Invoke the user's formatting macro.
  -- The macro should use \get{key} / \ifhas{key}{...} to read the defs above.
  lines[#lines + 1] = "\\" .. user_macro
  lines[#lines + 1] = ""

  -- ── Write cache file ───────────────────────────────────────────────────────
  local out, write_err = io.open(cache_path, "w")
  if not out then
    io.stderr:write(
      "parser: cannot write '" .. cache_path .. "': " ..
      tostring(write_err) .. "\n"
    )
    return false
  end
  out:write(table.concat(lines, "\n"))
  out:close()
  return true
end

local function dirtree(dir)
  if string.sub(dir, -1) == "/" then
    dir = string.sub(dir, 1, -2)
  end

  local function yieldtree(path)
    for entry in lfs.dir(path) do
      if not entry:match("^%.") then
        local full = path .. "/" .. entry
        if lfs.isdir(full) then
          yieldtree(full)
        else
          coroutine.yield(full)
        end
      end
    end
  end

  return coroutine.wrap(function() yieldtree(dir) end)
end

function M.emit_handout_inputs(handouts_dir, input_prefix)
  local relative_dir = handouts_dir or "./handouts"
  local prefix = input_prefix or relative_dir:gsub("^%./", "")
  local dir = relative_dir

  if not lfs.isdir(dir) then
    local cwd_dir = lfs.currentdir() .. "/" .. relative_dir:gsub("^%./", "")
    if lfs.isdir(cwd_dir) then
      dir = cwd_dir
    else
      texio.write_nl("parser: handout directory not found: " .. tostring(relative_dir))
      return
    end
  end

  for file in dirtree(dir) do
    local filename = file:gsub(".*/([^/]+)$", "%1")
    tex.sprint("\\input " .. prefix .. "/" .. filename .. " ")
  end
end

return M
