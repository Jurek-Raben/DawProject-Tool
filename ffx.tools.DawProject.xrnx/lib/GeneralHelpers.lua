------------------------------------------------------------------------------
-- General Helpers, collection of useful basic lua functionality
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
------------------------------------------------------------------------------


Notifiers = {}

function Notifiers:add(observable, callable)
  if not observable:has_notifier(callable) then
    observable:add_notifier(callable)
  end
end

function Notifiers:remove(observable, callable)
  if observable:has_notifier(callable) then
    observable:remove_notifier(callable)
  end
end

MenuEntry = {}

function MenuEntry:add(name, callable)
  if not Tool:has_menu_entry(name) then
    Tool:add_menu_entry({ name = name, invoke = callable })
  end
end

function MenuEntry:remove(name)
  if Tool:has_menu_entry(name) then
    Tool:remove_menu_entry(name)
  end
end

Helpers = {}

function Helpers:rgbToHex(r, g, b)
  local rgb = (r * 0x10000) + (g * 0x100) + b
  return string.format("%06x", rgb)
end

function Helpers:writeFile(filePath, content)
  local f = assert(io.open(filePath, "w"))
  f:write(content)
  f:close()
end

function Helpers:readFile(filePath)
  local f = assert(io.open(filePath, "rb"))
  local data = f:read("*all")
  f:close()
  return data
end

function Helpers:base64ToString(data)
  local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  data = string.gsub(data, '[^' .. b .. '=]', '')
  return (data:gsub('.', function(x)
    if (x == '=') then return '' end
    local r, f = '', (b:find(x) - 1)
    for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and '1' or '0') end
    return r;
  end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
    if (#x ~= 8) then return '' end
    local c = 0
    for i = 1, 8 do c = c + (x:sub(i, i) == '1' and 2 ^ (8 - i) or 0) end
    return string.char(c)
  end))
end

function Helpers:stringToBase64(data)
  local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  return ((data:gsub('.', function(x)
    local r, b = '', x:byte()
    for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and '1' or '0') end
    return r;
  end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
    if (#x < 6) then return '' end
    local c = 0
    for i = 1, 6 do c = c + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0) end
    return b:sub(c + 1, c + 1)
  end) .. ({ '', '==', '=' })[#data % 3 + 1])
end

local status_animation = { "", ".", "..", "..." }
local status_animation_pos = 1
function Helpers:generateStatusAnimation()
  if status_animation_pos >= #status_animation then
    status_animation_pos = 1
  else
    status_animation_pos = status_animation_pos + 1
  end
  return status_animation[status_animation_pos]
end

function Helpers:hexToCharLittleEndian(hexString)
  local binaryString = ""
  for i = 1, #hexString / 2 do
    local hexChar = string.sub(hexString, #hexString - i * 2 + 1, #hexString - i * 2 + 2)
    local binaryChar = string.char(tonumber(hexChar, 16))
    binaryString = binaryString .. binaryChar
  end
  return binaryString
end

function Helpers:hexToCharBigEndian(hexString)
  local binaryString = ""
  for i = 1, #hexString / 2 do
    local hexChar = string.sub(hexString, i * 2 - 1, i * 2)
    local binaryChar = string.char(tonumber(hexChar, 16))
    binaryString = binaryString .. binaryChar
  end
  return binaryString
end

function Helpers:intToBinaryLE(intValue, numBytes)
  return Helpers:hexToCharLittleEndian(string.format("%0" .. (numBytes * 2) .. "x", intValue))
end

function Helpers:intToBinaryBE(intValue, numBytes)
  return Helpers:hexToCharBigEndian(string.format("%0" .. (numBytes * 2) .. "x", intValue))
end

function Helpers:prepareFilenameForXML(string)
  return string.lower(string:gsub('[%p%c%s]', ''))
end

function Helpers:prepareNameForXML(string)
  return string:gsub('[%p%c]', '')
end

function Helpers:round(number, numDecimals)
  return math.floor(number * (10 ^ numDecimals)) / (10 ^ numDecimals)
end

function Helpers:captureConsole(cmd, raw)
  local handle = assert(io.popen(cmd, 'r'))
  local output = assert(handle:read('*a'))

  handle:close()

  if raw then
    return output
  end

  output = string.gsub(
    string.gsub(
      string.gsub(output, '^%s+', ''),
      '%s+$',
      ''
    ),
    '[\n\r]+',
    ' '
  )

  return output
end

function Helpers:getShortOSString()
  if (os.platform() == 'MACINTOSH') then
    return 'mac'
  elseif (os.platform() == 'WINDOWS') then
    return 'win'
  elseif (os.platform() == 'LINUX') then
    return 'linux'
  end
  return nil
end

function Helpers:tableContains(table, element)
  for _, value in pairs(table) do
    if value == element then
      return true
    end
  end
  return false
end
