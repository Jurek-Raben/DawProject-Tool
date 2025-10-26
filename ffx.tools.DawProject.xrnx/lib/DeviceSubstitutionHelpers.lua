-------------------------------------------------------------------------------
-- Device Substitution Helpers, for replacing Renoise internal fx
-- with common, freely avaialble plugins
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

DeviceSubstitutionHelpers = {}

DeviceSubstitutionHelpers.database = {
  {
    id = 'Audio/Effects/Native/TrackVolPan',
    replacementId = 'Audio/Effects/VST3/4D656C646170726F4D7574694D757469',
    mapping = function(sourceDevice, newDeviceParams)

    end,
  },
  {
    id = 'Audio/Effects/Native/Gainer',
    replacementId = 'Audio/Effects/VST3/4D656C646170726F4D7574694D757469',
    mapping = function(sourceDevice, newDeviceParams)

    end,
  }

}
