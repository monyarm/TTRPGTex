-- scanner.lua
-- Directory scanner and manifest generator for the ttrpg publishing engine.
--
-- Orchestrates the full pipeline:
--   1. Recursively scan a data directory for .json files.
--   2. Compare each file's mtime against its .ttrpg_cache/<stem>.tex mtime.
--   3. Regenerate only stale (or missing) cache files via parser.
--   4. Write a database_manifest--<name>.tex that \inputs / \includes the
--      cache files in the right order, inserting structural headings where
--      needed (hybrid mode).
--
-- Three inclusion modes are supported:
--
--   "input"   — Every cache file is emitted as \input{...} in the manifest.
--               Simplest option; no support for \includeonly.
--
--   "include" — Every cache file is emitted as \include{...} in the manifest.
--               Each item gets its own .aux; supports per-item \includeonly.
--               NOTE: requires that the build output directory mirrors
--               .ttrpg_cache/ (see §Caveats in ttrpg-core.sty).
--
--   "hybrid"  — JSON files are grouped by their top-level sub-directory.
--               Each group produces a *chapter wrapper* file:
--                 .ttrpg_cache/_chap--<datastem>--<folderstem>.tex
--               The wrapper \chapter{}/\section{}/\subsection{} headings and
--               \input{}s the individual cache files inside.
--               The manifest \include{}s only the wrappers, so \includeonly
--               has per-chapter granularity.
--               LaTeX forbids nested \include, so items inside wrappers MUST
--               use \input — this is respected by design.
--
-- Returned value from M.generate(): path to the manifest .tex file.
-- ttrpg-core.sty calls tex.print("\\input{" .. manifest .. "}") with it.
--
-- Place this file in _library/lua/ alongside ttrpg-core.sty.

local lfs    = require("lfs")
local utils  = require("utils")
local parser = require("parser")

local M = {}

-- The directory (relative to the LaTeX working directory) where all generated
-- files are stored.  Intentionally hidden (dot-prefixed) to reduce clutter.
local TEX_CACHE_DIR = "ttrpg_cache"
local FS_CACHE_DIR  = TEX_CACHE_DIR
local group_by_chapter

local parser_source_mtime = nil
do
  local info = debug.getinfo(parser.parse, "S")
  if info and type(info.source) == "string" and info.source:sub(1, 1) == "@" then
    local parser_path = info.source:sub(2)
    local p_attr = lfs.attributes(parser_path)
    if p_attr then
      parser_source_mtime = p_attr.modification
    end
  end
end

-- ── Internal: file collection ─────────────────────────────────────────────────

-- collect_json_files(root_dir, data_stem)
--
-- Recursively walks `root_dir` and returns a sorted list of entry tables,
-- one per .json file found:
--
--   entry = {
--     abs_path   = "/abs/path/to/goblin.json",
--     rel_path   = "humanoids/goblin.json",   -- relative to root_dir
--     dir_parts  = {"humanoids"},              -- folder path components
--                                             --   (excluding root_dir itself)
--     file_stem  = "goblin",
--     cache_stem = "monsters--humanoids--goblin",  -- globally unique
--     mtime      = 1748652000,
--   }
--
-- `data_stem` is the sanitised name of root_dir (e.g. "monsters") and is
-- prepended to cache_stem to avoid collisions across multiple
-- \generateDatabase calls within the same project.
local function collect_json_files(root_dir, data_stem)
  local entries = {}

  -- Recursive inner function.  `dir` is the absolute/relative fs path;
  -- `rel_prefix` is the path relative to root_dir accumulated so far;
  -- `dir_parts` is the list of folder name components since root_dir.
  local function scan(dir, rel_prefix, dir_parts)
    -- Track directory mtimes in .fls so adding/removing files invalidates latexmk.
    utils.force_tex_input_record(dir)

    local ok_iter, iter_or_err, dir_obj = pcall(lfs.dir, dir)
    if not ok_iter then
      io.stderr:write(
        "scanner: cannot read directory '" .. dir .. "': " ..
        tostring(iter_or_err) .. "\n"
      )
      return
    end

    -- Collect names first so we can sort for deterministic ordering
    local names = {}
    for name in iter_or_err, dir_obj do
      -- Skip dotfiles and the standard . / .. entries
      if not name:match("^%.") then
        names[#names + 1] = name
      end
    end
    table.sort(names)

    for _, name in ipairs(names) do
      local abs_path = utils.path_join(dir, name)
      local rel_path = (rel_prefix == "") and name
                        or utils.path_join(rel_prefix, name)
      local attr = lfs.attributes(abs_path)

      if attr then
        if attr.mode == "directory" then
          -- Descend; append this folder to dir_parts
          local new_parts = {}
          for _, p in ipairs(dir_parts) do
            new_parts[#new_parts + 1] = p
          end
          new_parts[#new_parts + 1] = name
          scan(abs_path, rel_path, new_parts)

        elseif attr.mode == "file" and name:match("%.json$") then
          local _, stem = utils.splitpath(name)

          -- Build a globally unique cache stem by prepending the data root
          local rel_stem = utils.get_cache_stem(rel_path)
          local cache_stem = (data_stem ~= "") and (data_stem .. "--" .. rel_stem)
                             or rel_stem

          entries[#entries + 1] = {
            abs_path   = abs_path,
            rel_path   = rel_path,
            dir_parts  = dir_parts,   -- folder components relative to root_dir
            file_stem  = stem,
            cache_stem = cache_stem,
            mtime      = attr.modification,
          }
        end
      end
    end
  end

  scan(root_dir, "", {})
  return entries
end

local function collect_tex_files(root_dir)
  local entries = {}

  local function scan(dir, rel_prefix, dir_parts)
    local ok_iter, iter_or_err, dir_obj = pcall(lfs.dir, dir)
    if not ok_iter then
      io.stderr:write(
        "scanner: cannot read directory '" .. dir .. "': " ..
        tostring(iter_or_err) .. "\n"
      )
      return
    end

    local names = {}
    for name in iter_or_err, dir_obj do
      if not name:match("^%.") then
        names[#names + 1] = name
      end
    end
    table.sort(names)

    for _, name in ipairs(names) do
      local abs_path = utils.path_join(dir, name)
      local rel_path = (rel_prefix == "") and name
                        or utils.path_join(rel_prefix, name)
      local attr = lfs.attributes(abs_path)

      if attr then
        if attr.mode == "directory" then
          local new_parts = {}
          for _, p in ipairs(dir_parts) do
            new_parts[#new_parts + 1] = p
          end
          new_parts[#new_parts + 1] = name
          scan(abs_path, rel_path, new_parts)

        elseif attr.mode == "file" and name:match("%.tex$") then
          if name ~= "_template.tex" then
            entries[#entries + 1] = {
              abs_path  = abs_path,
              rel_path  = rel_path,
              dir_parts = dir_parts,
              mtime     = attr.modification,
            }
          end
        end
      end
    end
  end

  scan(root_dir, "", {})
  return entries
end

-- ── Internal: freshness checks ────────────────────────────────────────────────

-- needs_regen(entry) → bool
-- True when the cache file does not exist or is older than the JSON source.
local function needs_regen(entry)
  local cache_path = utils.path_join(FS_CACHE_DIR, entry.cache_stem .. ".tex")
  local attr = lfs.attributes(cache_path)
  if not attr then return true end
  if parser_source_mtime and parser_source_mtime > attr.modification then
    return true
  end
  return entry.mtime > attr.modification
end

-- regen_item(entry, user_macro) → bool (true if the cache was (re)written)
local function regen_item(entry, user_macro)
  if not needs_regen(entry) then return false end
  local cache_path = utils.path_join(FS_CACHE_DIR, entry.cache_stem .. ".tex")
  local ok = parser.parse(entry.abs_path, cache_path, user_macro, entry.cache_stem)
  if ok then
    io.write("scanner: cached " .. cache_path .. "\n")
  end
  return ok
end

local function cache_exists(entry)
  local cache_path = utils.path_join(FS_CACHE_DIR, entry.cache_stem .. ".tex")
  return lfs.attributes(cache_path) ~= nil
end

-- ── Internal: manifest writers ────────────────────────────────────────────────

-- write_manifest_input(entries, mf) — emit \input for every entry
local function write_manifest_input(entries, mf)
  for _, e in ipairs(entries) do
    if cache_exists(e) then
      mf:write("\\input{" .. TEX_CACHE_DIR .. "/" .. e.cache_stem .. "}\n")
    else
      io.stderr:write("scanner: skipping missing cache for '" .. e.rel_path .. "'\n")
    end
  end
end

-- write_manifest_include(entries, mf) — emit \include for every entry
local function write_manifest_include(entries, mf)
  for _, e in ipairs(entries) do
    if cache_exists(e) then
      mf:write("\\include{" .. TEX_CACHE_DIR .. "/" .. e.cache_stem .. "}\n")
    else
      io.stderr:write("scanner: skipping missing cache for '" .. e.rel_path .. "'\n")
    end
  end
end

local function write_manifest_input_tex(entries, mf, data_path)
  for _, e in ipairs(entries) do
    mf:write("\\input{" .. utils.path_join(data_path, e.rel_path) .. "}\n")
  end
end

local function write_manifest_input_tex_grouped(entries, mf, data_path, chapter_callback)
  local order, groups = group_by_chapter(entries)

  if groups["_root"] then
    for _, e in ipairs(groups["_root"]) do
      mf:write("\\input{" .. utils.path_join(data_path, e.rel_path) .. "}\n")
    end
    mf:write("\n")
  end

  for _, chap in ipairs(order) do
    if chap ~= "_root" then
      local header = chapter_callback(chap, data_path)
      if type(header) == "string" and header ~= "" then
        mf:write(header)
        if not header:match("\n$") then
          mf:write("\n")
        end
      end

      -- Track last-emitted folder headings at each depth (2+).
      local last_parts = { [1] = chap }

      for _, e in ipairs(groups[chap]) do
        -- Emit folder headings from depth 2 onward when the folder changes.
        for depth = 2, #e.dir_parts do
          local part = e.dir_parts[depth]
          if part and part ~= last_parts[depth] then
            local heading_cmd = heading_command_for_depth(depth)
            mf:write("\\" .. heading_cmd .. "{" .. utils.clean_folder_name(part) .. "}\n")
            last_parts[depth] = part
            -- Reset deeper heading state when a parent folder changes.
            for deeper = depth + 1, #last_parts do
              last_parts[deeper] = nil
            end
          end
        end

        mf:write("\\input{" .. utils.path_join(data_path, e.rel_path) .. "}\n")
      end
      mf:write("\n")
    end
  end
end

local function write_manifest_include_tex(entries, mf, data_path)
  for _, e in ipairs(entries) do
    local stem_path = (e.rel_path:gsub("%.tex$", ""))
    local input_target = utils.path_join(data_path, stem_path)
    -- Direct TeX include mode emulates \include page breaks without creating
    -- per-file .aux paths that break under -output-directory builds.
    mf:write("\\clearpage\n")
    mf:write("\\input{" .. input_target .. "}\n")
    mf:write("\\clearpage\n")
  end
end

-- ── Internal: hybrid-mode chapter wrappers ────────────────────────────────────

-- chapter_wrapper_stem(data_stem, folder_name) → e.g. "_chap--monsters--humanoids"
-- Prefixed with "_chap--" so it sorts near the top of .ttrpg_cache/ listings
-- and never collides with item stems.
local function chapter_wrapper_stem(data_stem, folder_name)
  local safe = folder_name:gsub("[^%w%-_]", "_")
  if data_stem ~= "" then
    return "_chap--" .. data_stem .. "--" .. safe
  else
    return "_chap--" .. safe
  end
end

local HEADING_BY_DEPTH = {
  [1] = "chapter",
  [2] = "section",
  [3] = "subsection",
  [4] = "subsubsection",
  [5] = "paragraph",
  [6] = "subparagraph",
}

local function heading_command_for_depth(depth)
  return HEADING_BY_DEPTH[depth] or "subparagraph"
end

-- group_by_chapter(entries)
-- Splits entries into an ordered list of chapter names and a mapping
-- from chapter name → list of entries.
-- Entries with no subdirectory (dir_parts is empty) go to the "_root" group.
group_by_chapter = function(entries)
  local order  = {}
  local groups = {}

  for _, e in ipairs(entries) do
    local chap = e.dir_parts[1] or "_root"
    if not groups[chap] then
      order[#order + 1] = chap
      groups[chap] = {}
    end
    groups[chap][#groups[chap] + 1] = e
  end

  return order, groups
end

-- write_chapter_wrapper(data_stem, chapter_folder, entries)
-- Generates .ttrpg_cache/_chap--<data>--<folder>.tex containing:
--   \chapter{Clean Name}
--   Additional headings driven by directory depth:
--     depth 2 → \section, depth 3 → \subsection, ...
--   For each entry, heading context macros are set:
--     \ttrpgcurrentheadingcmd / \ttrpgnextheadingcmd
--   \input{.ttrpg_cache/<item_stem>}   ← \input, NOT \include
-- Returns the wrapper stem (for use in the manifest \include{}).
local function write_chapter_wrapper(data_stem, chapter_folder, entries, chapter_callback, chapter_wrapper_callback, data_path)
  local wstem = chapter_wrapper_stem(data_stem, chapter_folder)
  local wpath = utils.path_join(FS_CACHE_DIR, wstem .. ".tex")

  local f, err = io.open(wpath, "w")
  if not f then
    io.stderr:write(
      "scanner: cannot write chapter wrapper '" .. wpath ..
      "': " .. tostring(err) .. "\n"
    )
    return wstem
  end

  f:write("% Auto-generated chapter wrapper — do not edit manually.\n")
  f:write("% Chapter: " .. chapter_folder .. "\n\n")

  if chapter_wrapper_callback then
    local body = chapter_wrapper_callback(chapter_folder, data_path, entries, TEX_CACHE_DIR)
    if type(body) == "string" and body ~= "" then
      f:write(body)
      if not body:match("\n$") then
        f:write("\n")
      end
      f:close()
      io.write("scanner: chapter wrapper " .. wpath .. "\n")
      return wstem
    end
  end

  if chapter_callback then
    local header = chapter_callback(chapter_folder, data_path)
    if type(header) == "string" and header ~= "" then
      f:write(header)
      if not header:match("\n$") then
        f:write("\n")
      end
    else
      f:write("\\chapter{" .. utils.clean_folder_name(chapter_folder) .. "}\n")
    end
  else
    f:write("\\chapter{" .. utils.clean_folder_name(chapter_folder) .. "}\n")
  end

  -- Track last-emitted folder headings at each depth (2+).
  local last_parts = {}

  for _, e in ipairs(entries) do
    -- Emit folder headings from depth 2 onward when the folder changes.
    -- depth 1 is the chapter, already emitted above.
    for depth = 2, #e.dir_parts do
      local part = e.dir_parts[depth]
      if part and part ~= last_parts[depth] then
        local heading_cmd = heading_command_for_depth(depth)
        f:write("\\" .. heading_cmd .. "{" .. utils.clean_folder_name(part) .. "}\n")
        last_parts[depth] = part
        -- Reset deeper heading state when a parent folder changes.
        for deeper = depth + 1, #last_parts do
          last_parts[deeper] = nil
        end
      end
    end

  end

  for _, e in ipairs(entries) do
    f:write("\\input{" .. TEX_CACHE_DIR .. "/" .. e.cache_stem .. "}\n")
  end

  f:close()
  io.write("scanner: chapter wrapper " .. wpath .. "\n")
  return wstem
end

-- ── Public entry point ────────────────────────────────────────────────────────

-- get_unique_keys(dir_path, json_path) -> table
--
-- Scans all .json files in dir_path, navigates to json_path (dot-separated)
-- within each decoded object, and returns a sorted array of all unique keys
-- found at that location across all files.
function M.get_unique_keys(dir_path, json_path)
  local keys = {}
  local seen = {}

  -- Lightweight JSON decoder discovery (matches parser.lua logic)
  local json_decode
  local ok, mod = pcall(require, "dkjson")
  if ok and mod and type(mod.decode) == "function" then
    json_decode = mod.decode
  else
    local ok_lualibs = pcall(require, "lualibs")
    if ok_lualibs and utilities and utilities.json and type(utilities.json.tolua) == "function" then
      json_decode = utilities.json.tolua
    end
  end

  if not json_decode then
    io.stderr:write("scanner: no JSON decoder found for get_unique_keys\n")
    return keys
  end

  local function scan(dir)
    local ok_iter, iter_or_err, dir_obj = pcall(lfs.dir, dir)
    if not ok_iter then return end

    for name in iter_or_err, dir_obj do
      if not name:match("^%.") then
        local abs_path = utils.path_join(dir, name)
        local attr = lfs.attributes(abs_path)
        if attr then
          if attr.mode == "directory" then
            scan(abs_path)
          elseif attr.mode == "file" and name:match("%.json$") then
            utils.force_tex_input_record(abs_path)

            local f = io.open(abs_path, "r")
            if f then
              local src = f:read("*a")
              f:close()
              local data = json_decode(src)
              if data then
                local target = data
                for part in json_path:gmatch("[^%.]+") do
                  if type(target) == "table" then
                    target = target[part]
                  else
                    target = nil
                    break
                  end
                end
                if type(target) == "table" then
                  for k in pairs(target) do
                    if not seen[k] then
                      seen[k] = true
                      table.insert(keys, k)
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  scan(dir_path)
  table.sort(keys)
  return keys
end

-- generate(data_path, mode, user_macro) → manifest_path
--
-- Parameters:
--   data_path  – directory containing .json source files (relative to cwd).
--   mode       – "input" | "include" | "hybrid"  (default enforced by .sty)
--   user_macro – LaTeX macro name WITHOUT backslash; called in each cache file.
--
-- Returns the path to the manifest .tex file.  The caller (ttrpg-core.sty)
-- passes this to tex.print("\\input{...}") so LaTeX processes it inline.
function M.generate(data_path, mode, user_macro, opts)
  -- Strip trailing slashes and leading backslash from user_macro
  data_path  = data_path:gsub("/+$", "")
  user_macro = user_macro:gsub("^\\", "")

  -- Sanitize user_macro for use in filenames
  local safe_macro = user_macro:gsub("[^%w%-_]", "_"):gsub("_+", "_")
  local data_stem = utils.get_cache_stem(data_path)
  -- Append safe_macro to data_stem to ensure unique manifests/cache per macro
  local unique_data_stem = data_stem .. "--" .. safe_macro

  FS_CACHE_DIR = TEX_CACHE_DIR

  -- When lualatex is invoked with -output-directory (e.g. latexmk's $out_dir),
  -- writes are often restricted to that directory. Store generated cache files
  -- there while keeping TeX paths stable as .ttrpg_cache/<stem>.
  do
    local ok, outdir = pcall(function() return status.output_directory end)
    if ok and outdir and outdir ~= "" then
      FS_CACHE_DIR = utils.path_join(outdir, TEX_CACHE_DIR)
    end
  end

  utils.ensure_dir(FS_CACHE_DIR)

  local dir_attr = lfs.attributes(data_path)
  if not dir_attr or dir_attr.mode ~= "directory" then
    io.stderr:write(
      "scanner: data path '" .. data_path ..
      "' does not exist or is not a directory.\n"
    )
    -- Write an empty manifest so compilation continues
    local empty_stem    = "database_manifest--" .. unique_data_stem
    local empty_texpath = utils.path_join(TEX_CACHE_DIR, empty_stem .. ".tex")
    local empty_fspath  = utils.path_join(FS_CACHE_DIR, empty_stem .. ".tex")
    local empty_f = io.open(empty_fspath, "w")
    if empty_f then
      empty_f:write("% scanner: no data found at '" .. data_path .. "'\n")
      empty_f:close()
    end
    return empty_texpath
  end

  local chapter_callback = nil
  local chapter_wrapper_callback = nil
  if type(opts) == "table" and type(opts.chapter_callback) == "string" and opts.chapter_callback ~= "" then
    local fn = _G[opts.chapter_callback]
    if type(fn) == "function" then
      chapter_callback = fn
    else
      io.stderr:write(
        "scanner: chapter callback '" .. opts.chapter_callback .. "' is not a function\n"
      )
    end
  end

  if type(opts) == "table" and type(opts.chapter_wrapper_callback) == "string" and opts.chapter_wrapper_callback ~= "" then
    local fn = _G[opts.chapter_wrapper_callback]
    if type(fn) == "function" then
      chapter_wrapper_callback = fn
    else
      io.stderr:write(
        "scanner: chapter wrapper callback '" .. opts.chapter_wrapper_callback .. "' is not a function\n"
      )
    end
  end
  local direct_tex_mode = (user_macro:lower() == "latex")
  local entries
  if direct_tex_mode then
    entries = collect_tex_files(data_path)
  else
    -- Ensure the data root itself is a dependency; directory mtime changes
    -- capture file additions/deletions before individual JSON files are known.
    utils.force_tex_input_record(data_path)
    entries = collect_json_files(data_path, data_stem)
  end

  if #entries == 0 then
    local kind = direct_tex_mode and ".tex" or ".json"
    io.write("scanner: no " .. kind .. " files found under '" .. data_path .. "'\n")
  end

  -- One manifest per (data_path × mode) pair so multiple \generateDatabase
  -- calls in the same document do not clobber each other.
  local manifest_stem = "database_manifest--" .. unique_data_stem
  local manifest_texpath = utils.path_join(TEX_CACHE_DIR, manifest_stem .. ".tex")
  local manifest_fspath  = utils.path_join(FS_CACHE_DIR, manifest_stem .. ".tex")

  local mf, mf_err = io.open(manifest_fspath, "w")
  if not mf then
    error(
      "scanner: cannot write manifest '" .. manifest_fspath ..
      "': " .. tostring(mf_err)
    )
  end

  mf:write("% Auto-generated by scanner.lua — do not edit manually.\n")
  mf:write("% Mode: " .. mode .. "   Source: " .. data_path .. "\n")
  if direct_tex_mode then
    mf:write("% Source kind: tex (direct include/input mode)\n")
  end
  mf:write("\n")

  if direct_tex_mode then
    if mode == "include" then
      write_manifest_include_tex(entries, mf, data_path)
    elseif chapter_callback then
      write_manifest_input_tex_grouped(entries, mf, data_path, chapter_callback)
    else
      -- For direct TeX mode, both input and hybrid emit direct \input lines.
      write_manifest_input_tex(entries, mf, data_path)
    end

    mf:close()
    io.write("scanner: manifest -> " .. manifest_fspath .. "\n")
    return manifest_texpath
  end

  if mode == "input" then
    for _, e in ipairs(entries) do
      local rel_stem = utils.get_cache_stem(e.rel_path)
      e.cache_stem = unique_data_stem .. "--" .. rel_stem
      regen_item(e, user_macro)
    end
    write_manifest_input(entries, mf)

  elseif mode == "include" then
    for _, e in ipairs(entries) do
      local rel_stem = utils.get_cache_stem(e.rel_path)
      e.cache_stem = unique_data_stem .. "--" .. rel_stem
      regen_item(e, user_macro)
    end
    write_manifest_include(entries, mf)

  elseif mode == "hybrid" then
    local order, groups = group_by_chapter(entries)

    -- Root-level entries (files directly in data_path, no sub-directory):
    -- No chapter heading makes sense, so emit them as \input directly.
    if groups["_root"] then
      mf:write("% Root-level entries (no chapter grouping)\n")
      local root_entries = {}
      for _, e in ipairs(groups["_root"]) do
        local rel_stem = utils.get_cache_stem(e.rel_path)
        e.cache_stem = unique_data_stem .. "--" .. rel_stem
        regen_item(e, user_macro)
        if cache_exists(e) then
          root_entries[#root_entries + 1] = e
        else
          io.stderr:write("scanner: skipping missing cache for '" .. e.rel_path .. "'\n")
        end
      end
      write_manifest_input(root_entries, mf)
    end

    for _, chap in ipairs(order) do
      if chap ~= "_root" then
        local chap_entries = groups[chap]
        local valid_entries = {}
        local chapter_dirty = false

        for _, e in ipairs(chap_entries) do
          local rel_stem = utils.get_cache_stem(e.rel_path)
          e.cache_stem = unique_data_stem .. "--" .. rel_stem
          local regenerated = regen_item(e, user_macro)
          if regenerated then chapter_dirty = true end
          if cache_exists(e) then
            valid_entries[#valid_entries + 1] = e
          else
            io.stderr:write("scanner: skipping missing cache for '" .. e.rel_path .. "'\n")
          end
        end

        if #valid_entries == 0 then
          goto next_chapter
        end

        -- Regenerate the chapter wrapper if any item changed, the wrapper is missing,
        -- or a chapter callback is active (its emitted header can change independently).
        local wstem = chapter_wrapper_stem(unique_data_stem, chap)
        local wpath = utils.path_join(FS_CACHE_DIR, wstem .. ".tex")
        if chapter_dirty or chapter_callback or chapter_wrapper_callback or not lfs.attributes(wpath) then
          wstem = write_chapter_wrapper(unique_data_stem, chap, valid_entries, chapter_callback, chapter_wrapper_callback, data_path)
        end

        -- \input the wrapper. The multicols package explicitly does not support
        -- \include inside a multicols environment (documented); using \include
        -- causes an unbreakable ~983pt vbox that prevents column balancing.
        mf:write("\\input{" .. TEX_CACHE_DIR .. "/" .. wstem .. "}\n")
        ::next_chapter::
      end
    end

  else
    mf:close()
    error(
      "scanner: unknown mode '" .. mode ..
      "'.  Expected: input | include | hybrid"
    )
  end

  mf:close()
  io.write("scanner: manifest -> " .. manifest_fspath .. "\n")
  return manifest_texpath
end

return M
