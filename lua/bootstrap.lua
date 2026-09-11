local M = {}

function M.init(sty_path)
  ttrpg_lib_dir = sty_path and sty_path:match("^(.*)/[^/]+$") or "."
  local lua_dir = ttrpg_lib_dir .. "/lua"

  if not package.path:find(lua_dir, 1, true) then
    package.path = lua_dir .. "/?.lua;" .. lua_dir .. "/?/init.lua;" .. package.path
  end

  local function ttrpg_register_module(name)
    if package.preload[name] == nil then
      package.preload[name] = function()
        return dofile(lua_dir .. "/" .. name .. ".lua")
      end
    end
  end

  ttrpg_register_module("utils")
  ttrpg_register_module("xp")
  ttrpg_register_module("parser")
  ttrpg_register_module("scanner")
  ttrpg_register_module("ogl")
  ttrpg_register_module("folder_counter")
  ttrpg_register_module("randomtable")

  function ttrpg_load_module(name)
    local loaded = package.loaded[name]
    if loaded ~= nil then
      return loaded
    end

    local p = ttrpg_lib_dir .. "/lua/" .. name .. ".lua"
    local mod = dofile(p)
    package.loaded[name] = mod
    return mod
  end

  if not sty_path then
    texio.write_nl(
      "Package ttrpg-core Warning: " ..
      "could not locate ttrpg-core.sty via kpse. " ..
      "Ensure ../_library// is in TEXINPUTS. " ..
      "Lua module resolution may fail."
    )
  end

  local ok, mod = pcall(ttrpg_load_module, "ogl")
  if ok then
    ttrpg_ogl = mod
  end

  local ok_xp, mod_xp = pcall(ttrpg_load_module, "xp")
  if ok_xp then
    ttrpg_xp = mod_xp
  end
end

return M
