-------------------------------------------------------------------------------
-- DAW Project Importer, not working yet and not available in the menu.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

class "DawProjectImporter"

function DawProjectImporter:import()
  ProjectFiles:clearTempDirectory()
  local xml2lua = require("lib/xml2lua/xml2lua")
  local handler = require("xmlhandler.tree")

  local filePath = renoise.app():prompt_for_filename_to_read({ '*.dawproject' }, 'Import dawproject...')
  if filePath == '' then
    return
  end
  -- unzip first
  local fileContent = Helpers:readFile(filePath)

  local parser = xml2lua.parser(handler)
  parser:parse(fileContent)
  local data = handler.root
  rprint(data)
end
