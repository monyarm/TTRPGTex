-- ogl.lua
-- Reads a CSV of copyright credits and emits a full OGL v1.0a chapter page.
-- Called by \generateOGL{csvpath} defined in ttrpg-core.sty.
--
-- CSV format (columns): title, year, publisher, authors
-- - An optional header row is skipped if the first field equals "title".
-- - Fields containing commas must be quoted with double quotes.
-- - Escaped quotes inside a quoted field are written as "".
-- - LaTeX macros in any field (e.g. \textbf{}, \&) are passed through as-is.
--
-- After all CSV entries, \oglentry{\fulltitle}{\pubyear}{\publisher}{\authors}
-- is appended automatically for the current work. Those four macros must be
-- defined in the document before \generateOGL is called.
--
-- Place this file in _library/lua/ alongside ttrpg-core.sty.

local M = {}
local utils = require("utils")

-- RFC-4180-compatible CSV parser. Returns a list of row arrays.
local function parse_csv(path)
  utils.force_tex_input_record(path)

  local f, err = io.open(path, "r")
  if not f then
    error("ogl: cannot open CSV '" .. path .. "': " .. tostring(err))
  end
  local content = f:read("*a")
  f:close()

  local rows = {}
  local i    = 1
  local n    = #content

  while i <= n do
    local row = {}

    -- Parse all fields in this row
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

      -- Check what follows the field
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

-- The fixed OGL v1.0a license text (sections 1–14).
-- Section 15 (COPYRIGHT NOTICE) header is included here; the actual
-- credit entries are generated from the CSV rows that follow.
local OGL_TEXT = [[
\par The following text is the property of Wizards of the Coast, Inc. and is Copyright 2000 Wizards of the Coast, Inc ("Wizards"). All Rights Reserved.\\
\par 1. Definitions: (a)"Contributors" means the copyright and/or trademark owners who have contributed Open Game Content; (b)"Derivative Material" means copyrighted material including derivative works and translations (including into other computer languages), potation, modification, correction, addition, extension, upgrade, improvement, compilation, abridgment or other form in which an existing work may be recast, transformed or adapted; (c) "Distribute" means to reproduce, license, rent, lease, sell, broadcast, publicly display, transmit or otherwise distribute; (d)"Open Game Content" means the game mechanic and includes the methods, procedures, processes and routines to the extent such content does not embody the Product Identity and is an enhancement over the prior art and any additional content clearly identified as Open Game Content by the Contributor, and means any work covered by this License, including translations and derivative works under copyright law, but specifically excludes Product Identity. (e) "Product Identity" means product and product line names, logos and identifying marks including trade dress; artifacts; creatures characters; stories, storylines, plots, thematic elements, dialogue, incidents, language, artwork, symbols, designs, depictions, likenesses, formats, poses, concepts, themes and graphic, photographic and other visual or audio representations; names and descriptions of characters, spells, enchantments, personalities, teams, personas, likenesses and special abilities; places, locations, environments, creatures, equipment, magical or supernatural abilities or effects, logos, symbols, or graphic designs; and any other trademark or registered trademark clearly identified as Product identity by the owner of the Product Identity, and which specifically excludes the Open Game Content; (f) "Trademark" means the logos, names, mark, sign, motto, designs that are used by a Contributor to identify itself or its products or the associated products contributed to the Open Game License by the Contributor (g) "Use", "Used" or "Using" means to use, Distribute, copy, edit, format, modify, translate and otherwise create Derivative Material of Open Game Content. (h) "You" or "Your" means the licensee in terms of this agreement.\\
\par 2. The License: This License applies to any Open Game Content that contains a notice indicating that the Open Game Content may only be Used under and in terms of this License. You must affix such a notice to any Open Game Content that you Use. No terms may be added to or subtracted from this License except as described by the License itself. No other terms or conditions may be applied to any Open Game Content distributed using this License.\\
\par 3. Offer and Acceptance: By Using the Open Game Content You indicate Your acceptance of the terms of this License.\\
\par 4. Grant and Consideration: In consideration for agreeing to use this License, the Contributors grant You a perpetual, worldwide, royalty-free, non-exclusive license with the exact terms of this License to Use, the Open Game Content.\\
\par 5. Representation of Authority to Contribute: If You are contributing original material as Open Game Content, You represent that Your Contributions are Your original creation and/or You have sufficient rights to grant the rights conveyed by this License.\\
\par 6. Notice of License Copyright: You must update the COPYRIGHT NOTICE portion of this License to include the exact text of the COPYRIGHT NOTICE of any Open Game Content You are copying, modifying or distributing, and You must add the title, the copyright date, and the copyright holder's name to the COPYRIGHT NOTICE of any original Open Game Content you Distribute.\\
\par 7. Use of Product Identity: You agree not to Use any Product Identity, including as an indication as to compatibility, except as expressly licensed in another, independent Agreement with the owner of each element of that Product Identity. You agree not to indicate compatibility or co-adaptability with any Trademark or Registered Trademark in conjunction with a work containing Open Game Content except as expressly licensed in another, independent Agreement with the owner of such Trademark or Registered Trademark. The use of any Product Identity in Open Game Content does not constitute a challenge to the ownership of that Product Identity. The owner of any Product Identity used in Open Game Content shall retain all rights, title and interest in and to that Product Identity.\\
\par 8. Identification: If you distribute Open Game Content You must clearly indicate which portions of the work that you are distributing are Open Game Content.\\
\par 9. Updating the License: Wizards or its designated Agents may publish updated versions of this License. You may use any authorized version of this License to copy, modify and distribute any Open Game Content originally distributed under any version of this License.\\
\par10. Copy of this License: You MUST include a copy of this License with every copy of the Open Game Content You Distribute.\\
\par 11. Use of Contributor Credits: You may not market or advertise the Open Game Content using the name of any Contributor unless You have written permission from the Contributor to do so.\\
\par 12. Inability to Comply: If it is impossible for You to comply with any of the terms of this License with respect to some or all of the Open Game Content due to statute, judicial order, or governmental regulation then You may not Use any Open Game Material so affected.\\
\par 13. Termination: This License will terminate automatically if You fail to comply with all terms herein and fail to cure such breach within 30 days of becoming aware of the breach. All sublicenses shall survive the termination of this License.\\
\par 14. Reformation: If any provision of this License is held to be unenforceable, such provision shall be reformed only to the extent necessary to make it enforceable.\\
\par 15. COPYRIGHT NOTICE\\]]

-- Generate the full OGL chapter from a CSV credits file.
-- Requires \fulltitle, \pubyear, \publisher, and \authors to be defined.
function M.generate(csv_path)
  local rows = parse_csv(csv_path)

  -- Skip optional header row
  local start_row = 1
  if rows[1] and rows[1][1] and rows[1][1]:lower() == "title" then
    start_row = 2
  end

  -- Define \oglentry and check that the four required macros exist.
  -- All of this needs \makeatletter because of \@oglatmp / \@ifundefined.
  tex.print("\\makeatletter")

  -- \oglentry{title}{year}{publisher}{authors}
  -- Mirrors the LaTeX macro from the original OGL.tex.
  -- Author/Authors distinction uses xstring's \IfSubStr (loaded by ttrpg-core.sty).
  tex.print("\\providecommand{\\oglentry}[4]{%")
  tex.print("  \\def\\@oglatmp{#4}%")
  tex.print("  \\def\\@oglempty{}%")
  tex.print("  \\textbf{#1} \\copyright\\ #2, #3%")
  tex.print("  \\ifx\\@oglatmp\\@oglempty\\else")
  tex.print("    \\IfSubStr{#4}{,}{ ; Authors: #4}{ ; Author: #4}%")
  tex.print("  \\fi\\\\%")
  tex.print("}")

  -- Error out if any of the four document-identity macros are missing.
  for _, macro in ipairs({"fulltitle", "pubyear", "publisher", "authors"}) do
    tex.print(
      "\\@ifundefined{" .. macro .. "}" ..
      "{\\PackageError{ttrpg-ogl}" ..
      "{\\noexpand\\" .. macro .. " is not defined}" ..
      "{Define \\" .. macro .. " before \\noexpand\\generateOGL}}{}"
    )
  end

  tex.print("\\makeatother")

  -- Chapter heading and the two intro sections
  tex.print("\\newpage")
  tex.print("\\chapter{OGL License}")
  tex.print("")
  tex.print("\\section*{Product Identity}")
  tex.print("The following items are hereby identified as Product Identity, as defined in the Open Game License version 1.0a, Section 1(e): All trademarks, registered trademarks, proper names (characters, deities, etc.), dialogue, plots, storylines, locations, characters, artwork, and trade dress.")
  tex.print("")
  tex.print("\\section*{Open Game Content}")
  tex.print("Except for material designated as Product Identity (see above) or material specifically identified in the \\textbf{Creative Commons Attribution} section of this document, the game mechanics of this game product are Open Game Content, as defined in the Open Game License version 1.0a, Section 1(d).")
  tex.print("")
  tex.print("\\begin{multicols}{2}")
  tex.print("{\\small")

  -- Emit the fixed license text (sections 1–15 header) line by line
  for line in OGL_TEXT:gmatch("([^\n]*)\n?") do
    tex.print(line)
  end

  -- Credit entries from the CSV
  for i = start_row, #rows do
    local row       = rows[i]
    local title     = row[1] or ""
    local year      = row[2] or ""
    local publisher = row[3] or ""
    local authors   = row[4] or ""
    tex.print("\\oglentry{" .. title .. "}{" .. year .. "}{" .. publisher .. "}{" .. authors .. "}")
  end

  -- Append the current work's entry last
  tex.print("\\oglentry{\\fulltitle}{\\pubyear}{\\publisher}{\\authors}")

  tex.print("}")
  tex.print("\\end{multicols}")
end

return M
