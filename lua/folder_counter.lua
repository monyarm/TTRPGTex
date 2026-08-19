-- folder_counter.lua
-- Recursive file counting helpers for arbitrary folder lists.

local lfs = require("lfs")
local utils = require("utils")

local M = {}

local function normalize_folders(folders)
  if type(folders) == "string" then
    local list = {}
    for part in folders:gmatch("[^,]+") do
      part = part:gsub("^%s+", ""):gsub("%s+$", "")
      if part ~= "" then
        list[#list + 1] = part
      end
    end
    return list
  end
  return folders or {}
end

local function matches_format(filename, format)
  if format == nil or format == "" or format == "all" then
    return filename:match("%.tex$") ~= nil or filename:match("%.json$") ~= nil
  end
  local normalized = tostring(format):lower()
  if normalized == "tex" then
    return filename:match("%.tex$") ~= nil
  elseif normalized == "json" then
    return filename:match("%.json$") ~= nil
  end
  return filename:match("%.[^%.]+$") == "." .. normalized
end

local function count_in_dir(directory, format)
  local count = 0
  local ok_iter, iter_or_err, dir_obj = pcall(lfs.dir, directory)
  if not ok_iter then
    return 0
  end

  for name in iter_or_err, dir_obj do
    if not name:match("^%.") then
      local path = utils.path_join(directory, name)
      local attr = lfs.attributes(path)
      if attr then
        if attr.mode == "directory" then
          count = count + count_in_dir(path, format)
        elseif attr.mode == "file" and matches_format(name, format) then
          count = count + 1
        end
      end
    end
  end

  return count
end

function M.count(folders, format)
  local total = 0
  for _, folder in ipairs(normalize_folders(folders)) do
    if folder and folder ~= "" then
      total = total + count_in_dir(folder, format)
    end
  end
  return total
end

function M.count_tex(folders)
  return M.count(folders, "tex")
end

function M.count_json(folders)
  return M.count(folders, "json")
end

return M