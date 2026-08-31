Singer (Ashita v4, FontManager HUD)


-- Author: Aragan  

Install:
1) Put folder: Ashita-v4/addons/singer/
   - singer.lua
   - settings.lua
2) /addon load singer

Commands:
- /singer on|off|toggle|status
- /singer now
- /singer songs "Song1" "Song2" ...
- /singer playlists
- /singer playlist <name>
- /singer delay <sec>
- /singer interval <sec>
- /singer target <me|<t>|Name>
- /singer nitro on|off|toggle
- /singer ccsv  on|off|toggle
- /singer hud on|off|toggle|collapse|reset
- /singer hud pos <x> <y>

HUD:
- Click the Singer title to collapse or expand it.
- Drag the Singer title to move the HUD.
- Click Enabled, Nitro, CCSV, or Cast Now to run that action.
- HUD position and collapsed state are saved in settings/hud.lua.

Notes:
- Fix4 adds an aftercast pad (+2.5s) automatically to reduce 'Unable to cast spell.' between songs.
