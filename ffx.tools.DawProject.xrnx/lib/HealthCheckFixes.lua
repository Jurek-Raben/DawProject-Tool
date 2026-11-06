-------------------------------------------------------------------------------
-- Health Check Fixes, the instructions for solving the problems the health
-- check finds, for the operating system the tool is running on.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

local RELEASES_URL = 'https://github.com/Jurek-Raben/DawProject-Tool/releases'

HealthCheckFixes = {}

function HealthCheckFixes:getToolDirectory()
  return (renoise.tool().bundle_path:gsub('[/\\]+$', ''))
end

function HealthCheckFixes:getBinDirectory()
  local separator = (Helpers:getShortOSString() == 'win') and '\\' or '/'
  return self:getToolDirectory() .. separator .. 'bin'
end

function HealthCheckFixes:getCannotStartFixForMac(toolName, toolOutput)
  if (string.find(toolOutput:lower(), 'bad cpu type', 1, true)) then
    return {
      'This binary is required for bridged plugins and needs Rosetta. Run this in the Terminal:',
      '',
      'softwareupdate --install-rosetta',
    }
  end

  return {
    'The binaries are not signed, so macOS might block them. Run this in the Terminal:',
    '',
    'cd "' .. self:getBinDirectory() .. '"',
    'chmod +x vst2info-tool-* vst3info-tool-*',
    'xattr -dr com.apple.quarantine .',
    '',
    'If it is still blocked on Apple Silicon, also sign the binary locally:',
    '',
    'codesign --force --sign - ' .. toolName,
  }
end

function HealthCheckFixes:getCannotStartFixForWindows()
  return {
    'Windows might block downloaded binaries. Run this in PowerShell:',
    '',
    'Get-ChildItem "' .. self:getBinDirectory() .. '\\*.exe" | Unblock-File',
    '',
    'If your virus scanner removes or blocks the binaries, add an exception for this directory:',
    self:getBinDirectory(),
  }
end

function HealthCheckFixes:getCannotStartFixForLinux(toolOutput)
  if (string.find(toolOutput, 'GLIBC', 1, true)) then
    return {
      'The binaries need a newer system library (glibc) than your system provides.',
      'Update your system, or build the helper tools yourself, see the README of the tool.',
    }
  end

  return {
    'The binaries have to be executable. Run this in a terminal:',
    '',
    'cd "' .. self:getBinDirectory() .. '"',
    'chmod +x vst2info-tool-* vst3info-tool-*',
  }
end

function HealthCheckFixes:getCannotStartFix(toolName, toolOutput)
  local osString = Helpers:getShortOSString()
  if (osString == 'mac') then
    return self:getCannotStartFixForMac(toolName, toolOutput)
  elseif (osString == 'win') then
    return self:getCannotStartFixForWindows()
  end
  return self:getCannotStartFixForLinux(toolOutput)
end

function HealthCheckFixes:getMissingToolFix()
  return {
    'The helper tool is missing or outdated. Install the latest version of this tool from:',
    RELEASES_URL,
    '',
    'If you build the tool from source, run ./build_vst_tools.sh first.',
  }
end

function HealthCheckFixes:getTempDirectoryFix()
  local directory = self:getToolDirectory()
  if (Helpers:getShortOSString() == 'win') then
    return {
      'Make sure that your user is allowed to write into this directory:',
      directory,
    }
  end
  return {
    'Your user has to be allowed to write into the directory of the tool. Run this in a terminal:',
    '',
    'chmod -R u+rwX "' .. directory .. '"',
  }
end

function HealthCheckFixes:getPackCommandFix()
  local osString = Helpers:getShortOSString()
  if (osString == 'linux') then
    return {
      'The zip command is required for packing the .dawproject file. Install it, e.g.:',
      '',
      'sudo apt install zip     (Debian, Ubuntu)',
      'sudo dnf install zip     (Fedora)',
      'sudo pacman -S zip       (Arch)',
    }
  elseif (osString == 'win') then
    return {
      'The tar command is required for packing the .dawproject file.',
      'It is part of Windows 10 version 1803 and newer, so please update your system.',
    }
  end
  return {
    'The tar command is required for packing the .dawproject file.',
    'It is part of macOS, so check that /usr/bin/tar exists and that it is first in your PATH.',
  }
end

function HealthCheckFixes:getPluginDatabaseFix()
  return {
    'Renoise lists its plugins in this database. Let Renoise scan your plugins again:',
    'Edit > Preferences > Plugins/Misc > Rescan plugins',
  }
end

function HealthCheckFixes:getPluginAccessFix()
  local fix = {
    'Plugins that do not exist anymore: reinstall them, or let Renoise scan your plugins again.',
    'Edit > Preferences > Plugins/Misc > Rescan plugins',
    '',
  }

  local osString = Helpers:getShortOSString()
  if (osString == 'mac') then
    table.insert(fix, 'Plugins in protected folders, e.g. Documents or an external drive: allow access under')
    table.insert(fix, 'System Settings > Privacy & Security > Files and Folders or Full Disk Access')
  elseif (osString == 'win') then
    table.insert(fix, 'Other plugins: make sure that your user is allowed to read the plugin files.')
  else
    table.insert(fix, 'Other plugins: make sure that your user is allowed to read the plugin files, e.g.:')
    table.insert(fix, '')
    table.insert(fix, 'chmod -R a+rX "/path/to/the/plugin"')
  end

  return fix
end

function HealthCheckFixes:getBridgedPluginFix()
  return {
    'Use a native version of the plugin. Otherwise its VST2 preset or VST3 automation will be missing.',
  }
end
