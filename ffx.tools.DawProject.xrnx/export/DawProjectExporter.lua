-------------------------------------------------------------------------------
-- DAW Project Exporter, the sequence of an export: reads the song, generates
-- the project data, and writes the .dawproject file.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

require('export/PluginSubstitutions')
require('export/TrackLayout')
require('export/AutomationExporter')
require('export/DeviceExporter')
require('export/TrackExporter')
require('export/ArrangementExporter')

local XML_HEADER = '<?xml version="1.0" encoding="UTF-8"?>\n'


class "DawProjectExporter"

function DawProjectExporter:__init(config, progress)
  self.config = config
  self.progress = progress
end

-- Has to run inside of a coroutine, since it yields regularly
function DawProjectExporter:export(filePath)
  local xml2lua = require("lib/xml2lua/xml2lua")

  local yieldCallback = function(fraction)
    if (fraction ~= nil) then
      self.progress:setPhaseProgress(fraction)
    end
    coroutine.yield()
  end

  self.progress:setPhase('Reading instruments of the tracks', 0, 0.1)
  yieldCallback()
  local substitutions = PluginSubstitutions(self.config)
  local noteAbstraction = NoteAbstraction(substitutions)
  local layout = TrackLayout(self.config, noteAbstraction:collectInstrumentPools(yieldCallback))

  self.progress:setPhase('Reading notes and automation', 0.1, 0.35)
  yieldCallback()
  local songEvents = noteAbstraction:generateSongEvents(yieldCallback)

  local pluginInfoCache = Cache()
  local automationExporter = AutomationExporter(self.config, self.progress, layout, pluginInfoCache)
  local automationEvents = automationExporter:generateAutomationEventsDataForXML(songEvents)

  yieldCallback()

  local deviceExporter = DeviceExporter(self.config, self.progress, layout, pluginInfoCache,
    automationEvents.parametersObj, substitutions)
  local trackExporter = TrackExporter(self.config, self.progress, layout, deviceExporter)
  local arrangementExporter = ArrangementExporter(self.config, self.progress, layout, substitutions)

  local projectStructure = {
    Project = {
      _attr = {
        version = '1.0'
      },
      Application = {
        _attr = { name = 'Renoise', version = renoise.RENOISE_VERSION }
      },
      Transport = {
        Tempo = {
          _attr = {
            min = '20', max = '999', unit = 'bpm', name = 'Tempo', value = Song.transport.bpm
          },
        },
        TimeSignature = {
          _attr = {
            numerator = 4, denominator = 4
          },
        },
      },

      Structure = trackExporter:generateParentTracksStructureDataForXML('Master'),
      Arrangement = {
        Lanes = {
          _attr = {
            timeUnit = "beats",
          },
          Lanes = arrangementExporter:generateNoteEventsDataForXML(songEvents, automationEvents.automationsObj),
        },
        Markers = arrangementExporter:generateMarkersDataForXML()
      }
    }
  }

  -- show the next steps before these block for a moment
  self.progress:setPhase('Writing project file', 0.93, 0.97)
  yieldCallback()

  local fileContent = XML_HEADER .. xml2lua.toXml(projectStructure)

  -- ugly workaround
  fileContent = string.gsub(fileContent, "</Devices>([ \t\r\n]+)<Devices>", "")

  Helpers:writeFile(TempDir .. "/project.xml", fileContent)

  local metaData = {
    MetaData = {
      Artist = Song.artist,
      Title = Song.name,
      Comment = Song.file_name
    }
  }

  Helpers:writeFile(TempDir .. "/metadata.xml", XML_HEADER .. xml2lua.toXml(metaData))

  self.progress:setPhase('Packing .dawproject file', 0.97, 1)
  yieldCallback()

  ProjectFiles:packTempDirectory(filePath)

  if (not self.config.devMode) then
    ProjectFiles:clearTempDirectory()
  end
end
