-------------------------------------------------------------------------------
-- Migratable Plugins Dialog, a sortable table of the installed VST2 plugins
-- which an installed VST3 version can replace, see MigratablePlugins.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

local DIALOG_TITLE = 'Migratable VST2 Plugins'

local PAGE_SIZE = 20
local MARGIN = 8
local ROW_HEIGHT = 18
-- the text views don't cut their text, so it is shortened by an average character width
local AVERAGE_CHARACTER_WIDTH = 6.5

local HEADER_COLOR = { 160, 190, 215 }
local TEXT_COLOR = { 225, 225, 225 }
local GOOD_COLOR = { 90, 200, 90 }
local FAIR_COLOR = { 230, 200, 90 }
local UNKNOWN_COLOR = { 150, 150, 150 }

local SCHEME_LABELS = {
  ['plugin compatibility'] = 'VST3 declaration',
  ['Steinberg'] = 'Steinberg ID',
  ['MeldaProduction'] = 'MeldaProduction ID',
}

local AUTOMATION_LABELS = {
  [MigratablePlugins.AUTOMATION_BY_PLUGIN] = 'Mapped by plugin',
  [MigratablePlugins.AUTOMATION_BY_NAMES] = 'Index and name',
  [MigratablePlugins.AUTOMATION_UNKNOWN] = 'Unknown',
}

local AUTOMATION_COLORS = {
  [MigratablePlugins.AUTOMATION_BY_PLUGIN] = GOOD_COLOR,
  [MigratablePlugins.AUTOMATION_BY_NAMES] = FAIR_COLOR,
  [MigratablePlugins.AUTOMATION_UNKNOWN] = UNKNOWN_COLOR,
}

local COLUMNS = {
  { title = 'VST2 plugin', width = 190, value = function(row) return row.name end },
  { title = 'Vendor', width = 130, value = function(row) return row.vendor end },
  { title = 'Type', width = 75, value = function(row) return row.isInstrument and 'Instrument' or 'Effect' end },
  { title = 'VST3 version', width = 190, value = function(row) return row.vst3Name end },
  { title = 'Found by', width = 125, value = function(row) return SCHEME_LABELS[row.scheme] or row.scheme end },
  {
    title = 'Automation',
    width = 120,
    value = function(row) return AUTOMATION_LABELS[row.automation] or row.automation end,
    color = function(row) return AUTOMATION_COLORS[row.automation] end,
    tooltip = function(row) return row.automationProblem and ('Could not be asked: ' .. row.automationProblem) or '' end,
  },
}

local TABLE_WIDTH = 0
for _, column in ipairs(COLUMNS) do
  TABLE_WIDTH = TABLE_WIDTH + column.width
end

local LEGEND = table.concat({
  'The state of the VST2 plugin is always taken over by the VST3 version.',
  'Found by: "VST3 declaration" means the VST3 plugin declares that it replaces the VST2 plugin. ' ..
  '"Steinberg ID" and "MeldaProduction ID" mean its class id is derived from the VST2 id.',
  'Automation: "Mapped by plugin" means the VST3 version tells the new parameter for each VST2 parameter, ' ..
  'so automation, *Instr. Automation slots and meta device targets are moved reliably.',
  '"Index and name" means the VST3 parameter with the VST2 index as id is used if its name is similar, ' ..
  'otherwise the only parameter with the same name. Parameters without a match can\'t take their automation along.',
  '"Unknown" means the VST3 version could not be asked, the mouse over it shows why.',
}, '\n')

-- Characters of UTF-8 text, so it isn't cut inside of a character
local function shorten(text, width)
  local maxCharacters = math.floor(width / AVERAGE_CHARACTER_WIDTH)
  local characters = {}
  for character in string.gmatch(tostring(text or ''), '[%z\1-\127\194-\244][\128-\191]*') do
    table.insert(characters, character)
  end
  if (#characters <= maxCharacters) then
    return table.concat(characters)
  end
  return table.concat(characters, '', 1, maxCharacters - 2) .. '..'
end


class "MigratablePluginsDialog"

function MigratablePluginsDialog:__init()
  self.dialog = nil
end

-- result is the one of MigratablePlugins:scan. migrationDataHint is shown, if the plugin migration data is not
-- built yet. onRefresh reads the plugins again.
function MigratablePluginsDialog:show(result, migrationDataHint, onRefresh)
  self:close()
  self.rows = result.rows
  self.sortColumn = 1
  self.isDescending = false
  self.page = 1

  local vb = renoise.ViewBuilder()
  local contentView = vb:column {
    margin = MARGIN,
    spacing = 6,
  }

  local summary = #result.rows .. ' of ' .. result.vst2Count .. ' installed VST2 plugins have an installed VST3 ' ..
      'version, which can replace them.'
  if (result.unreadableCount > 0) then
    summary = summary .. ' ' .. result.unreadableCount .. ' VST2 plugins could not be read, see the scripting ' ..
        'terminal for the reasons.'
  end
  contentView:add_child(vb:text { width = TABLE_WIDTH, text = summary })
  if (migrationDataHint ~= nil) then
    contentView:add_child(vb:text { width = TABLE_WIDTH, text = migrationDataHint, style = 'strong' })
  end

  self.headerButtons = {}
  local headerRow = vb:row {}
  for columnIndex, column in ipairs(COLUMNS) do
    local button = vb:button {
      width = column.width,
      notifier = function() self:sortBy(columnIndex) end,
    }
    self.headerButtons[columnIndex] = button
    headerRow:add_child(button)
  end
  contentView:add_child(headerRow)

  self.cellViews = {}
  for rowIndex = 1, PAGE_SIZE do
    local rowView = vb:row { height = ROW_HEIGHT }
    self.cellViews[rowIndex] = {}
    for columnIndex, column in ipairs(COLUMNS) do
      local cell = vb:text {
        width = column.width,
        height = ROW_HEIGHT,
        style = 'custom',
        color = TEXT_COLOR,
      }
      self.cellViews[rowIndex][columnIndex] = cell
      rowView:add_child(cell)
    end
    contentView:add_child(rowView)
  end

  self.pageText = vb:text { width = 200, align = 'center' }
  self.previousButton = vb:button { text = '<', width = 30, notifier = function() self:showPage(self.page - 1) end }
  self.nextButton = vb:button { text = '>', width = 30, notifier = function() self:showPage(self.page + 1) end }
  contentView:add_child(vb:horizontal_aligner {
    mode = 'center',
    width = TABLE_WIDTH,
    self.previousButton,
    self.pageText,
    self.nextButton,
  })

  contentView:add_child(vb:multiline_text {
    width = TABLE_WIDTH,
    height = 120,
    text = LEGEND,
  })

  contentView:add_child(vb:horizontal_aligner {
    mode = 'right',
    width = TABLE_WIDTH,
    spacing = 6,
    vb:button {
      text = 'Refresh',
      width = 80,
      tooltip = 'Reads new and changed plugins, and the ones that failed before',
      notifier = function()
        self:close()
        onRefresh()
      end,
    },
    vb:button {
      text = 'Close',
      width = 80,
      notifier = function() self:close() end,
    },
  })

  self:sortRows()
  self:updateHeader()
  self:showPage(1)
  self.dialog = renoise.app():show_custom_dialog(DIALOG_TITLE, contentView)
end

function MigratablePluginsDialog:sortBy(columnIndex)
  if (self.sortColumn == columnIndex) then
    self.isDescending = not self.isDescending
  else
    self.sortColumn = columnIndex
    self.isDescending = false
  end
  self:sortRows()
  self:updateHeader()
  self:showPage(1)
end

-- By the sorted column, the name decides between equal values
function MigratablePluginsDialog:sortRows()
  local value = COLUMNS[self.sortColumn].value
  local nameValue = COLUMNS[1].value
  table.sort(self.rows, function(a, b)
    local valueA = string.lower(tostring(value(a) or ''))
    local valueB = string.lower(tostring(value(b) or ''))
    if (valueA ~= valueB) then
      if (self.isDescending) then
        return valueA > valueB
      end
      return valueA < valueB
    end
    return string.lower(tostring(nameValue(a))) < string.lower(tostring(nameValue(b)))
  end)
end

function MigratablePluginsDialog:updateHeader()
  for columnIndex, column in ipairs(COLUMNS) do
    local marker = ''
    if (columnIndex == self.sortColumn) then
      marker = self.isDescending and ' v' or ' ^'
    end
    self.headerButtons[columnIndex].text = column.title .. marker
  end
end

function MigratablePluginsDialog:getPageCount()
  return math.max(1, math.ceil(#self.rows / PAGE_SIZE))
end

function MigratablePluginsDialog:showPage(page)
  self.page = math.max(1, math.min(page, self:getPageCount()))
  local firstIndex = (self.page - 1) * PAGE_SIZE
  for rowIndex = 1, PAGE_SIZE do
    local row = self.rows[firstIndex + rowIndex]
    for columnIndex, column in ipairs(COLUMNS) do
      local cell = self.cellViews[rowIndex][columnIndex]
      if (row == nil) then
        cell.text = ''
        cell.tooltip = ''
      else
        cell.text = shorten(column.value(row), column.width)
        cell.color = column.color and column.color(row) or TEXT_COLOR
        cell.tooltip = column.tooltip and column.tooltip(row) or tostring(column.value(row) or '')
      end
    end
  end

  self.pageText.text = 'Page ' .. self.page .. ' of ' .. self:getPageCount() .. ' (' .. #self.rows .. ' plugins)'
  self.previousButton.active = self.page > 1
  self.nextButton.active = self.page < self:getPageCount()
end

function MigratablePluginsDialog:close()
  if (self.dialog ~= nil and self.dialog.visible) then
    self.dialog:close()
  end
  self.dialog = nil
  self.headerButtons = nil
  self.cellViews = nil
  self.pageText = nil
  self.previousButton = nil
  self.nextButton = nil
end
