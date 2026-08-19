local M = {}

local PF1E_XP_BY_CR = {
  ["1/8"] = 50,
  ["1/6"] = 65,
  ["1/4"] = 100,
  ["1/3"] = 135,
  ["1/2"] = 200,
  ["1"] = 400,
  ["2"] = 600,
  ["3"] = 800,
  ["4"] = 1200,
  ["5"] = 1600,
  ["6"] = 2400,
  ["7"] = 3200,
  ["8"] = 4800,
  ["9"] = 6400,
  ["10"] = 9600,
  ["11"] = 12800,
  ["12"] = 19200,
  ["13"] = 25600,
  ["14"] = 38400,
  ["15"] = 51200,
  ["16"] = 76800,
  ["17"] = 102400,
  ["18"] = 153600,
  ["19"] = 204800,
  ["20"] = 307200,
  ["21"] = 409600,
  ["22"] = 614400,
  ["23"] = 819200,
  ["24"] = 1228800,
  ["25"] = 1638400,
  ["26"] = 2457600,
  ["27"] = 3276800,
  ["28"] = 4915200,
  ["29"] = 6553600,
  ["30"] = 9830400,
}

local function format_int_with_commas(n)
  local value = math.floor(tonumber(n) or 0)
  if value < 1000 then
    return tostring(value)
  end

  local function pad3(num)
    if num < 10 then
      return "00" .. tostring(num)
    elseif num < 100 then
      return "0" .. tostring(num)
    end
    return tostring(num)
  end

  local head = math.floor(value / 1000)
  local tail = value - (head * 1000)
  return format_int_with_commas(head) .. "," .. pad3(tail)
end

local function normalize_system(system)
  local s = tostring(system or "")
  s = s:lower()
  s = s:gsub(" ", "")
  s = s:gsub(string.char(9), "")
  s = s:gsub(string.char(10), "")
  s = s:gsub(string.char(13), "")
  if s == "" or s == "pf1" or s == "pf1e" or s == "pathfinder" or s == "pathfinder1e" then
    return "pf1e"
  end
  return s
end

local function normalize_cr(cr)
  local c = tostring(cr or "")
  c = c:lower()
  c = c:gsub("^cr", "")
  c = c:gsub(" ", "")
  c = c:gsub(string.char(9), "")
  c = c:gsub(string.char(10), "")
  c = c:gsub(string.char(13), "")

  local n = tonumber(c)
  if n then
    if math.abs(n - 0.125) < 0.0001 then return "1/8" end
    if math.abs(n - (1/6)) < 0.0001 then return "1/6" end
    if math.abs(n - (1/4)) < 0.0001 then return "1/4" end
    if math.abs(n - (1/3)) < 0.0001 then return "1/3" end
    if math.abs(n - 0.5) < 0.0001 then return "1/2" end
    if math.abs(n - math.floor(n + 0.5)) < 0.0001 then
      return tostring(math.floor(n + 0.5))
    end
  end

  return c
end

function M.cr_to_xp(system, cr)
  local sys = normalize_system(system)
  local cr_key = normalize_cr(cr)

  if sys == "pf1e" then
    local xp = PF1E_XP_BY_CR[cr_key]
    if xp then
      return format_int_with_commas(xp)
    end
    return "?"
  end

  return "?"
end

return M
