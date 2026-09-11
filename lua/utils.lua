-- utils.lua
-- Shared helpers: key sanitisation, TeX escaping, path utilities, cache stems,
-- mkdir, CSV parsing.
--
-- Required by: parser.lua, scanner.lua, randomtable.lua
-- Loaded by:   ttrpg-core.sty

local lfs = require("lfs")

local M = {}

-- Force TeX to record a file as an input dependency.
-- This cycles the path through TeX's native input streams so latexmk can see it in .fls.
function M.force_tex_input_record(path)
  if type(tex) ~= "table" or type(tex.sprint) ~= "function" then
    return
  end

  local filename = tostring(path)
  local mode = lfs.attributes(filename, "mode")
  if mode == "directory" then
    filename = M.path_join(filename, ".")
  end
  tex.sprint("\\openin0=\\detokenize{" .. filename .. "}\\relax\\closein0\\relax")
end

-- ── Key sanitisation ──────────────────────────────────────────────────────────

-- sanitize_key(str) → a string safe for use as a LaTeX \csname fragment.
--
-- Rules applied (in order):
--   1. Lowercase the whole string.
--   2. Replace spaces, hyphens, dots, forward-slashes with underscores.
--   3. Strip characters that are illegal or confusing in a \csname:
--      # $ % & { } ^ ~ \ @ " | < > ! ? ; , ( ) [ ]
--   4. Collapse consecutive underscores to one; strip leading/trailing ones.
--   5. Prefix "k_" if the result starts with a digit (csnames cannot start
--      with a digit in normal use, though technically \csname allows it;
--      the prefix keeps keys predictable).
--   6. Replace the empty string with "k_empty" as a sentinel.
--
-- Example: "Hit Points (Max)" → "hit_points_max"
--          "3rd-level"        → "k_3rd_level"
function M.sanitize_key(str)
  str = tostring(str):lower()
  -- Whitespace, hyphen, dot, slash → underscore
  str = str:gsub("[%s%-%.%/]", "_")
  -- Strip apostrophes before the broader removal pass so keys like
  -- Raven's Omen and Raven’s Omen normalize consistently.
  str = str:gsub("['’]", "")
  -- Strip characters illegal in csnames
  str = str:gsub('[#%$%%&{}%^~\\@"|<!>?;,%(%)%[%]]', "")
  -- Collapse runs; strip leading/trailing underscores
  str = str:gsub("_+", "_")
  str = str:gsub("^_+", "")
  str = str:gsub("_+$", "")
  -- Numeric-leading guard
  if str:match("^%d") then
    str = "k_" .. str
  end
  if str == "" then str = "k_empty" end
  return str
end

-- ── Value escaping ────────────────────────────────────────────────────────────

-- escape_tex_value(v) → a string safe to use as the body of \def\foo{...}
--
-- Design intent: values in TTRPG data files are treated as *LaTeX fragments*,
-- so constructs like \textbf{...} and \\ are preserved.  Only characters that
-- would unconditionally break a \def body are escaped:
--
--   #  → \#   (would be interpreted as macro argument #N)
--   %  → \%   (would start a TeX comment, swallowing the rest of the line)
--   &  → \&   (table/alignment special; almost never intentional in a \def)
--
-- Characters left intact: \ { } $ _ ^ ~
-- (Users who want literal percent/ampersand in values should write \% / \& in
-- their JSON; users who want LaTeX math should write $...$ freely.)
function M.escape_tex_value(v)
  if type(v) == "number" or type(v) == "boolean" then
    return tostring(v)
  end
  local s = tostring(v)
  -- Protect already-escaped specials so user-authored TeX like \%, \#, \&
  -- survives round-tripping through the generator unchanged.
  local protected = {}
  s = s:gsub("\\([#%%&])", function(ch)
    local token = "__TTRPG_ESC_" .. tostring(#protected + 1) .. "__"
    protected[token] = "\\" .. ch
    return token
  end)

  -- Escape only bare # % & that would otherwise break a \def body.
  s = s:gsub("#",  "\\#")
  s = s:gsub("%%", "\\%%")
  s = s:gsub("&",  "\\&")

  for token, replacement in pairs(protected) do
    s = s:gsub(token, function()
      return replacement
    end)
  end
  return s
end

-- ── Human-readable folder names ───────────────────────────────────────────────

-- clean_folder_name(str) → title-cased string suitable for \chapter{} etc.
--
-- "my-cool_folder"  → "My Cool Folder"
-- "undead_minions"  → "Undead Minions"
function M.clean_folder_name(str)
  -- Replace separators with spaces
  str = str:gsub("[%-_]", " ")
  -- Title-case: capitalise the first character of every word
  str = str:gsub("(%a)([%w']*)", function(first, rest)
    return first:upper() .. rest
  end)
  return str
end

-- ── Path helpers ──────────────────────────────────────────────────────────────

-- path_join(...) → segments joined with "/" with no double-slashes.
--
-- path_join("foo", "bar", "baz") → "foo/bar/baz"
-- path_join("./root", "sub/")    → "./root/sub/"   (trailing slash preserved)
function M.path_join(...)
  local parts = { ... }
  -- Filter out nil/empty segments
  local filtered = {}
  for _, p in ipairs(parts) do
    if p and p ~= "" then
      filtered[#filtered + 1] = p
    end
  end
  local result = table.concat(filtered, "/")
  -- Collapse any accidental double (or more) slashes, but preserve a leading //
  result = result:gsub("([^:])//+", "%1/")
  return result
end

-- splitpath(filepath) → dir, stem, ext
--
-- splitpath("foo/bar/baz.json") → "foo/bar",  "baz",  ".json"
-- splitpath("goblin.json")      → ".",         "goblin", ".json"
-- splitpath("README")           → ".",         "README", ""
function M.splitpath(filepath)
  local dir  = filepath:match("^(.*)/[^/]*$") or "."
  local base = filepath:match("[^/]+$") or filepath
  local stem = base:match("^(.+)%.[^%.]+$") or base
  local ext  = base:match("(%.[^%.]+)$") or ""
  return dir, stem, ext
end

-- ── Cache stem generation ─────────────────────────────────────────────────────

-- get_cache_stem(rel_path) → a flat, filesystem-safe identifier string.
--
-- Designed for constructing `.ttrpg_cache/<stem>.tex` filenames.
-- Path separators become "--" (double-dash) to avoid directory collisions.
--
-- get_cache_stem("monsters/humanoids/goblin.json") → "monsters--humanoids--goblin"
-- get_cache_stem("./spells/fireball.json")         → "spells--fireball"
-- get_cache_stem("item.json")                      → "item"
function M.get_cache_stem(rel_path)
  -- Strip leading "./"
  rel_path = rel_path:gsub("^%.%/", "")
  -- Strip file extension
  rel_path = rel_path:gsub("%.[^%./]+$", "")
  -- Replace path separators with "--"
  rel_path = rel_path:gsub("/", "--")
  -- Replace any remaining characters illegal in filenames
  rel_path = rel_path:gsub("[^%w%-_]", "_")
  -- Collapse runs of "--" or "__"
  rel_path = rel_path:gsub("%-%-+", "--")
  rel_path = rel_path:gsub("_+",    "_")
  if rel_path == "" then rel_path = "k_unnamed" end
  return rel_path
end

-- ── CSV parsing ────────────────────────────────────────────────────────────────

-- parse_csv(path) → a list of row arrays (RFC-4180-compatible).
--
-- Fields containing commas or newlines must be quoted with double quotes;
-- escaped quotes inside a quoted field are written as "". Blank lines are
-- skipped. LaTeX macros in any field are passed through as-is.
function M.parse_csv(path)
  M.force_tex_input_record(path)

  local f, err = io.open(path, "r")
  if not f then
    error("parse_csv: cannot open CSV '" .. path .. "': " .. tostring(err))
  end
  local content = f:read("*a")
  f:close()

  local rows = {}
  local i    = 1
  local n    = #content

  while i <= n do
    local row = {}

    while true do
      if i > n then break end

      if content:sub(i, i) == '"' then
        -- Quoted field: read until closing unescaped "
        i = i + 1
        local chars = {}
        while i <= n do
          local c = content:sub(i, i)
          if c == '"' then
            if content:sub(i + 1, i + 1) == '"' then
              chars[#chars + 1] = '"'  -- "" → literal "
              i = i + 2
            else
              i = i + 1  -- skip closing quote
              break
            end
          else
            chars[#chars + 1] = c
            i = i + 1
          end
        end
        row[#row + 1] = table.concat(chars)
      else
        -- Unquoted field: read until comma or line ending
        local start = i
        while i <= n do
          local c = content:sub(i, i)
          if c == ',' or c == '\n' or c == '\r' then break end
          i = i + 1
        end
        row[#row + 1] = content:sub(start, i - 1)
      end

      if i > n then break end
      local sep = content:sub(i, i)
      if sep == ',' then
        i = i + 1  -- comma: next field in same row
      elseif sep == '\r' then
        i = i + 1
        if content:sub(i, i) == '\n' then i = i + 1 end
        break  -- end of row
      elseif sep == '\n' then
        i = i + 1
        break  -- end of row
      else
        break
      end
    end

    -- Skip blank rows
    if #row > 0 and not (#row == 1 and row[1] == "") then
      rows[#rows + 1] = row
    end
  end

  return rows
end

-- ── Directory management ──────────────────────────────────────────────────────

-- ensure_dir(path) → creates `path` and all missing parent directories.
--
-- Silent no-op if the directory already exists.
-- Raises an error (via Lua error()) if creation is impossible.
function M.ensure_dir(path)
  -- Nothing to do if already a directory
  if lfs.attributes(path, "mode") == "directory" then return end
  -- Recursively ensure the parent exists first
  local parent = path:match("^(.*)/[^/]+$")
  if parent and parent ~= "" and parent ~= "." then
    M.ensure_dir(parent)
  end
  local ok, err = lfs.mkdir(path)
  -- A parallel process may have created it between our check and mkdir; that
  -- is fine.  Any other failure is fatal.
  if not ok and lfs.attributes(path, "mode") ~= "directory" then
    error("utils: cannot create directory '" .. path .. "': " .. tostring(err))
  end
end

return M
