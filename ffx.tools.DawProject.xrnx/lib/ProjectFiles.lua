-------------------------------------------------------------------------------
-- Project Files, handles the temporary directory and the .dawproject archive
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

TempDir = './tmp'

ZipPackCommand = 'cd ' .. TempDir .. ' && tar -acvf %s --exclude=".DS_Store" --exclude="*.xrni" %s'
ZipUnpackCommand = 'tar -xf %s --directory ' .. TempDir
-- GNU tar can't create zip files, unlike the bsdtar of macOS and Windows
if (os.platform() == 'LINUX') then
  ZipPackCommand = 'cd ' .. TempDir .. ' && zip -FSr %s %s -x "*.DS_Store" "*.xrni"'
end

ProjectFiles = {}

function ProjectFiles:clearTempDirectory()
  local presetFiles = {}
  pcall(function()
    presetFiles = os.filenames(TempDir .. '/plugins', { '*.aupreset', '*.vstpreset', '*.fxp', '*.xrni' })
  end)
  for i in pairs(presetFiles) do
    os.remove(TempDir .. '/plugins/' .. presetFiles[i])
  end
  os.remove(TempDir .. '/plugins')
  os.remove(TempDir .. '/project.xml')
  os.remove(TempDir .. '/metadata.xml')
  os.mkdir(TempDir)
  os.mkdir(TempDir .. '/plugins')
end

-- Packs the content of the temporary directory into a .dawproject file
function ProjectFiles:packTempDirectory(filePath)
  os.execute(string.format(ZipPackCommand, '../dawproject.zip', '*'))
  os.move('./dawproject.zip', filePath)
end
