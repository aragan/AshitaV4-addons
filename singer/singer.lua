
addon.name     = 'singer'
addon.author   = 'Aragan'
addon.version  = '1.2.1 - version gate of transformers coming'
addon.desc     = 'Singer with FontManager HUD for Ashita v4'
addon.link     = 'https://github.com/aragan/Ashita-addons/tree/main/singer'

require('common')

--[[
    Singer (Ashita v4) - FontManager HUD (SAFE)
    Author: Aragan

    Goal:
      - Rotate BRD songs on Ashita v4.
      - Native Ashita FontManager HUD; no ImGui or Windower libraries.

    Safety:
      - Use the correct QueueCommand signature in Ashita v4: (command, delay)
      - Delays + a max commands-per-cycle limit to avoid command spam.

    Supported commands:
      /singer on|off|toggle|status
      /singer now
      /singer songs "Song1" "Song2" ...
      /singer delay <sec>
      /singer interval <sec>
      /singer target <tgt>
      /singer nitro on|off|toggle
      /singer ccsv  on|off|toggle
      /singer marcato "Song"

    Also accepts /sing as a shortcut.
--]]
------------------------------------------------------------
-- State
------------------------------------------------------------
local state = {
    enabled     = false,
    busy        = false,
    busy_until  = 0.0,

    -- Internal step queue (to avoid QueueCommand limitations in some Ashita setups)
    pending     = nil,
    pending_i   = 0,
    next_action = 0.0,

    song_delay  = 8.5,
    interval    = 240.0,
    next_cycle  = 0.0,

    songs       = {
        "Mage's Ballad III",
        "Victory March",
        "Blade Madrigal",
    },

    target      = '<me>',

    nitro       = false,
    ccsv        = false,

    -- Extra time after each song to avoid /ma failing due to being busy (Aftercast pad)
    pad         = 2.5,

    -- Song playlists from settings.lua (optional)
    settings    = nil,
    playlist    = nil,

    -- pbar-style HUD state, ported from the Ashita v3 Singer HUD.
    hud_enabled       = true,
    hud_collapsed     = false,
    hud_x             = 20,
    hud_y             = 120,
    hud_font_name     = 'Arial',
    hud_font_size     = 11,
    hud_font_color    = 0xFFFFFFFF,
    hud_font_bold     = true,
    hud_bg_color      = 0xC0101512,
    hud_bg_visible    = true,
    hud_border_color  = 0xFF4E9B62,
    hud_lines         = {},
    hud_actions       = {},
    hud_box           = { x = 20, y = 120, w = 220, h = 40 },
    hud_drag_pending  = false,
    hud_dragging      = false,
    hud_drag_start_x  = 0,
    hud_drag_start_y  = 0,
    hud_drag_dx       = 0,
    hud_drag_dy       = 0,
    hud_next_update   = 0.0,
    hud_error_reported = false,
}


local echo

------------------------------------------------------------
-- settings.lua support (song playlists)
------------------------------------------------------------
-- The legacy settings.lua style uses L{} and T{}.
-- Here we define them as simple functions so the file works without Windower libraries.
if type(_G.L) ~= 'function' then
    _G.L = function(t) return t end
end
if type(_G.T) ~= 'function' then
    _G.T = function(t) return t end
end

local function load_settings()
    -- Reads addons/singer/settings.lua if it exists
    package.loaded['settings'] = nil
    local ok, cfg = pcall(require, 'settings')
    if ok and type(cfg) == 'table' then
        state.settings = cfg
        return true
    end
    state.settings = nil
    return false
end

local function list_playlists()
    local cfg = state.settings
    if not cfg or type(cfg.playlist) ~= 'table' then
        echo('No playlists found. Put settings.lua next to singer.lua.')
        return
    end

    local names = {}
    for k, _ in pairs(cfg.playlist) do
        if type(k) == 'string' then
            names[#names + 1] = k
        end
    end
    table.sort(names)

    if #names == 0 then
        echo('No playlists in settings.lua (playlist table is empty).')
        return
    end

    echo('Playlists: ' .. table.concat(names, ', '))
end

local function set_playlist(name)
    local cfg = state.settings
    if not cfg or type(cfg.playlist) ~= 'table' then
        echo('settings.lua not loaded.')
        return false
    end

    local pl = cfg.playlist[name]
    if type(pl) ~= 'table' then
        echo('Playlist not found: ' .. tostring(name))
        return false
    end

    local songs = {}
    for i = 1, #pl do
        if type(pl[i]) == 'string' and pl[i] ~= '' then
            songs[#songs + 1] = pl[i]
        end
    end

    if #songs == 0 then
        echo('Playlist is empty: ' .. tostring(name))
        return false
    end

    state.songs = songs
    state.playlist = name
    echo('Playlist set: ' .. name)
    echo('Songs: ' .. table.concat(state.songs, ' | '))
    return true
end

------------------------------------------------------------
-- Utilities
------------------------------------------------------------
local function now_clock()
    return os.clock()
end

-- Ashita v4: QueueCommand(command, delay)
-- IMPORTANT: argument order is (command_string, delay_seconds).
local function queue_command(cmd, delay)
    if type(cmd) ~= 'string' or cmd == '' then
        return false
    end

    local cm = AshitaCore and AshitaCore:GetChatManager() or nil
    if not cm then
        return false
    end

    local d = tonumber(delay) or 0
    -- Many Ashita addons use -1 to mean "execute immediately".
    if d < -1 then d = -1 end

    -- Ashita v4 Lua bindings seen in the wild use both:
    --   QueueCommand(command, delay)
    --   QueueCommand(delay, command)
    -- To avoid "does nothing" on one setup (or "spam / freeze" on another),
    -- we try both signatures safely.
    local ok = pcall(function()
        cm:QueueCommand(cmd, d)
    end)

    if not ok then
        ok = pcall(function()
            cm:QueueCommand(d, cmd)
        end)
    end

    return ok
end

echo = function(msg)
    -- Chat messages are English-only per your preference
    local ok = queue_command(('/echo [Singer] %s'):format(msg), 0)
    if not ok then
        -- fallback: at least show it somewhere if QueueCommand is unavailable / wrong.
        print(('[Singer] %s'):format(msg))
    end
end

-- Tokenize commands with support for quotes ""
local function tokenize_command(cmd)
    local out = {}
    local i, n = 1, #cmd
    local inq = false
    local cur = {}

    while i <= n do
        local c = cmd:sub(i, i)
        if c == '"' then
            inq = not inq
        elseif (not inq) and (c == ' ' or c == '\t') then
            if #cur > 0 then
                out[#out+1] = table.concat(cur)
                cur = {}
            end
        else
            cur[#cur+1] = c
        end
        i = i + 1
    end

    if #cur > 0 then
        out[#out+1] = table.concat(cur)
    end

    return out
end

local function norm_prefix(tok)
    tok = tok or ''
    tok = tok:gsub('^//', '/')
    return tok:lower()
end

------------------------------------------------------------
-- Singing logic (no buff checking to avoid API differences)
------------------------------------------------------------
local MAX_ACTIONS_PER_CYCLE = 32

local function begin_busy(total_delay)
    state.busy = true
    state.busy_until = now_clock() + (tonumber(total_delay) or 0) + 0.25
end

local function start_pending(steps)
    if state.pending ~= nil then
        return false
    end
    if type(steps) ~= 'table' or #steps == 0 then
        return false
    end

    state.pending = steps
    state.pending_i = 1
    state.next_action = now_clock() + 0.10

    -- Keep busy enabled while steps are still executing
    local total = 0.0
    for _, s in ipairs(steps) do
        total = total + (tonumber(s.wait) or 0)
    end
    begin_busy(total)
    return true
end

local function build_steps_for_song_list(list)
    local steps = {}
    local actions = 0

    if state.nitro then
        steps[#steps+1] = { cmd = '/ja "Nightingale" <me>', wait = 1.0 }
        steps[#steps+1] = { cmd = '/ja "Troubadour" <me>',  wait = 1.0 }
        actions = actions + 2
    end

    if state.ccsv then
        steps[#steps+1] = { cmd = '/ja "Clarion Call" <me>', wait = 1.6 }
        steps[#steps+1] = { cmd = '/ja "Soul Voice" <me>',   wait = 2.0 }
        actions = actions + 2
    end

    for _, song in ipairs(list) do
        if actions >= MAX_ACTIONS_PER_CYCLE then
            break
        end
        steps[#steps+1] = { cmd = ('/ma "%s" %s'):format(song, state.target), wait = (state.song_delay + (state.pad or 0)) }
        actions = actions + 1
    end

    return steps
end

local function cast_song_list(list)
    if state.pending ~= nil then return false end
    if state.busy then return false end

    if type(list) ~= 'table' or #list == 0 then
        return false
    end

    local steps = build_steps_for_song_list(list)
    return start_pending(steps)
end


local function cast_cycle()
    return cast_song_list(state.songs)
end

local function cast_marcato(song)
    if state.pending ~= nil then return end
    if state.busy then return end
    if type(song) ~= 'string' or song == '' then
        echo('Usage: /singer marcato "Song"')
        return
    end

    local steps = {
        { cmd = '/ja "Marcato" <me>', wait = 1.0 },
        { cmd = ('/ma "%s" %s'):format(song, state.target), wait = (state.song_delay + (state.pad or 0)) },
    }

    start_pending(steps)
    echo(('Marcato: %s'):format(song))
end


------------------------------------------------------------
-- Status and help
------------------------------------------------------------
local function show_status()
    echo(('Status: %s | Delay: %.1fs (+%.1f) | Interval: %.0fs | Target: %s | Nitro: %s | CCSV: %s | Playlist: %s | HUD: %s'):format(
        state.enabled and 'ON' or 'OFF',
        state.song_delay,
        (state.pad or 0),
        state.interval,
        state.target,
        state.nitro and 'ON' or 'OFF',
        state.ccsv and 'ON' or 'OFF',
        state.playlist or 'custom',
        state.hud_enabled and 'ON' or 'OFF'
    ))
    echo(('Songs: %s'):format(table.concat(state.songs, ' | ')))
end

local function show_help()
    echo('Commands:')
    echo('/singer on | off | toggle | status')
    echo('/singer now')
    echo('/singer marcato "Song"')
    echo('/singer songs "Song1" "Song2" ...')
    echo('/singer playlists')
    echo('/singer playlist <name>')
    echo('/singer delay <sec>   (min 0.5)')
    echo('/singer interval <sec> (min 30)')
    echo('/singer target <tgt>  (ex: <me> or <t>)')
    echo('/singer nitro on|off|toggle')
    echo('/singer ccsv  on|off|toggle')
    echo('/singer hud on|off|toggle|collapse|reset|pos <x> <y>')
end

------------------------------------------------------------
-- FontManager HUD (pbar-style, ported from Ashita v3)
------------------------------------------------------------
local HUD_ALIAS = '__singer_addon_hud_v4'
local WM_MOUSEMOVE = 0x0200
local WM_LBUTTONDOWN = 0x0201
local WM_LBUTTONUP = 0x0202
local script_source = debug.getinfo(1, 'S').source:gsub('^@', '')
local script_dir = script_source:match('^(.*[\\/])') or './'
local HUD_CONFIG_PATH = script_dir .. 'settings/hud.lua'
local HUD_ROW_HEIGHT = 18
local hud_row_fonts = {}

local function load_hud_settings()
    local loader = loadfile(HUD_CONFIG_PATH)
    if not loader then return false end

    local ok, cfg = pcall(loader)
    if not ok or type(cfg) ~= 'table' then return false end

    if type(cfg.enabled) == 'boolean' then state.hud_enabled = cfg.enabled end
    if type(cfg.collapsed) == 'boolean' then state.hud_collapsed = cfg.collapsed end
    if tonumber(cfg.x) then state.hud_x = math.floor(tonumber(cfg.x)) end
    if tonumber(cfg.y) then state.hud_y = math.floor(tonumber(cfg.y)) end
    return true
end

local function save_hud_settings()
    local file = io.open(HUD_CONFIG_PATH, 'w')
    if not file then return false end

    file:write('return {\n')
    file:write(('    enabled = %s,\n'):format(state.hud_enabled and 'true' or 'false'))
    file:write(('    collapsed = %s,\n'):format(state.hud_collapsed and 'true' or 'false'))
    file:write(('    x = %d,\n'):format(math.floor(tonumber(state.hud_x) or 20)))
    file:write(('    y = %d,\n'):format(math.floor(tonumber(state.hud_y) or 120)))
    file:write('}\n')
    file:close()
    return true
end

local function hud_init()
    local fm = AshitaCore and AshitaCore:GetFontManager() or nil
    return fm ~= nil
end

local function hud_get_row(index)
    if hud_row_fonts[index] then return hud_row_fonts[index] end

    local fm = AshitaCore and AshitaCore:GetFontManager() or nil
    if not fm then return nil end

    local alias = ('%s_%02d'):format(HUD_ALIAS, index)
    pcall(function() fm:Delete(alias) end)
    local ok, font = pcall(function() return fm:Create(alias) end)
    if not ok or not font then return nil end

    local setup_ok, setup_error = pcall(function()
        font:SetBold(state.hud_font_bold and true or false)
        font:SetColor(state.hud_font_color)
        font:SetFontFamily(state.hud_font_name)
        font:SetFontHeight(state.hud_font_size)
        font:SetAutoResize(false)
        font:SetPadding(0.1)
        font:SetCanFocus(true)
        font:SetVisible(false)

        local bg = font:GetBackground()
        if bg then
            bg:SetColor(state.hud_bg_color)
            bg:SetVisible(state.hud_bg_visible and true or false)
            bg:SetCanFocus(true)
            bg:SetLocked(true)
            bg:SetBorderVisible(false)
        end
    end)
    if not setup_ok then
        pcall(function() fm:Delete(alias) end)
        if not state.hud_error_reported then
            state.hud_error_reported = true
            echo('HUD row initialization failed: ' .. tostring(setup_error))
        end
        return nil
    end

    hud_row_fonts[index] = font
    return font
end

local function hud_destroy()
    local fm = AshitaCore and AshitaCore:GetFontManager() or nil
    if fm then
        for index = 1, #hud_row_fonts do
            local alias = ('%s_%02d'):format(HUD_ALIAS, index)
            pcall(function() fm:Delete(alias) end)
        end
    end
    hud_row_fonts = {}
end

local function hud_set_visible(visible)
    for _, font in ipairs(hud_row_fonts) do
        pcall(function() font:SetVisible(visible and true or false) end)
    end
end

local function hud_col(enabled)
    return enabled and '|cFF38D46A|ON|r' or '|cFFFF6565|OFF|r'
end

local function hud_build_lines()
    state.hud_lines = {}
    state.hud_actions = {}

    local function add(line, action)
        state.hud_lines[#state.hud_lines + 1] = line
        state.hud_actions[#state.hud_lines] = action or false
    end

    add(('|cFF8FD6A3|Singer|r %s'):format(state.hud_collapsed and '[+]' or '[-]'), function()
        state.hud_collapsed = not state.hud_collapsed
        save_hud_settings()
    end)

    if state.hud_collapsed then return end

    add(('Enabled: [%s]'):format(hud_col(state.enabled)), function()
        state.enabled = not state.enabled
        state.busy = false
        if state.enabled then state.next_cycle = now_clock() + 0.5 end
    end)
    add(('Busy:    [%s]'):format(hud_col(state.busy)), nil)
    add(('Nitro:   [%s]'):format(hud_col(state.nitro)), function()
        state.nitro = not state.nitro
    end)
    add(('CCSV:    [%s]'):format(hud_col(state.ccsv)), function()
        state.ccsv = not state.ccsv
    end)
    add(('Playlist: |cFFFFFFFF|%s|r'):format(state.playlist or 'custom'), nil)
    add(('Target:   |cFFFFFFFF|%s|r'):format(state.target), nil)
    add('|cFFFFFF70|[ Cast Now ]|r', function()
        cast_cycle()
    end)

    for i = 1, #state.songs do
        add(('  %d) %s'):format(i, tostring(state.songs[i] or '')), nil)
        if #state.hud_lines >= 14 then break end
    end
end

local function hud_recalc_box()
    local char_w = math.max(6, math.floor((tonumber(state.hud_font_size) or 11) * 0.64))
    local max_len = 0

    for _, line in ipairs(state.hud_lines) do
        local plain = tostring(line):gsub('|c%x%x%x%x%x%x%x%x|', ''):gsub('|r', '')
        if #plain > max_len then max_len = #plain end
    end

    state.hud_box.x = math.floor(tonumber(state.hud_x) or 20)
    state.hud_box.y = math.floor(tonumber(state.hud_y) or 120)
    state.hud_box.w = math.max(180, (max_len * char_w) + 14)
    state.hud_box.h = #state.hud_lines * HUD_ROW_HEIGHT
    state.hud_box.line_h = HUD_ROW_HEIGHT
    state.hud_box.pad = 0
end

local function hud_update(force)
    if not state.hud_enabled then
        hud_set_visible(false)
        return
    end
    if not hud_init() then return end

    local t = now_clock()
    if not force and t < (state.hud_next_update or 0.0) then return end

    hud_build_lines()
    hud_recalc_box()
    local render_ok = true
    local render_error = nil
    for index, line in ipairs(state.hud_lines) do
        local font = hud_get_row(index)
        if not font then
            render_ok = false
            render_error = 'could not create row ' .. tostring(index)
            break
        end

        local ok, err = pcall(function()
            font:SetPositionX(state.hud_box.x)
            font:SetPositionY(state.hud_box.y + ((index - 1) * HUD_ROW_HEIGHT))
            font:SetWindowWidth(state.hud_box.w)
            font:SetWindowHeight(HUD_ROW_HEIGHT)
            font:SetText(line)
            font:SetVisible(true)
        end)
        if not ok then
            render_ok = false
            render_error = err
            break
        end
    end
    for index = #state.hud_lines + 1, #hud_row_fonts do
        pcall(function() hud_row_fonts[index]:SetVisible(false) end)
    end
    if not render_ok and not state.hud_error_reported then
        state.hud_error_reported = true
        echo('HUD render failed: ' .. tostring(render_error))
    end
    state.hud_next_update = t + 0.20
end

local function hud_point_inside(x, y)
    local box = state.hud_box
    return x >= box.x and x <= (box.x + box.w) and y >= box.y and y <= (box.y + box.h)
end

local function hud_line_at(x, y)
    for index = 1, #state.hud_lines do
        local font = hud_row_fonts[index]
        if font then
            local ok, hit = pcall(function() return font:HitTest(x, y) end)
            if ok and hit then return index end
        end
    end

    local box = state.hud_box
    local relative_y = y - box.y
    if relative_y < 0 then return 0 end
    local line = math.floor(relative_y / HUD_ROW_HEIGHT) + 1
    return math.max(1, math.min(line, #state.hud_lines))
end

local function hud_handle_mouse(e)
    local message = tonumber(e.message)
    local x = tonumber(e.x)
    local y = tonumber(e.y)

    if message == WM_LBUTTONUP and (state.hud_dragging or state.hud_drag_pending) then
        if state.hud_drag_pending then
            state.hud_drag_pending = false
            local action = state.hud_actions[1]
            if type(action) == 'function' then pcall(action) end
        else
            state.hud_dragging = false
            save_hud_settings()
        end
        hud_update(true)
        return true
    end

    if not state.hud_enabled or not x or not y then return false end

    if state.hud_dragging then
        if message == WM_MOUSEMOVE then
            state.hud_x = math.floor(x - state.hud_drag_dx)
            state.hud_y = math.floor(y - state.hud_drag_dy)
            hud_update(true)
        end
        return true
    end

    if state.hud_drag_pending then
        if message == WM_MOUSEMOVE then
            local dx = math.abs(x - state.hud_drag_start_x)
            local dy = math.abs(y - state.hud_drag_start_y)
            if dx > 3 or dy > 3 then
                state.hud_drag_pending = false
                state.hud_dragging = true
                state.hud_x = math.floor(x - state.hud_drag_dx)
                state.hud_y = math.floor(y - state.hud_drag_dy)
                hud_update(true)
            end
        end
        return true
    end

    if message == WM_LBUTTONDOWN then
        hud_update(true)
        if not hud_point_inside(x, y) then return false end

        local line = hud_line_at(x, y)
        if line == 1 then
            state.hud_drag_pending = true
            state.hud_drag_start_x = x
            state.hud_drag_start_y = y
            state.hud_drag_dx = x - state.hud_box.x
            state.hud_drag_dy = y - state.hud_box.y
        end
        return true
    end

    if message == WM_LBUTTONUP and hud_point_inside(x, y) then
        local action = state.hud_actions[hud_line_at(x, y)]
        if type(action) == 'function' then pcall(action) end
        hud_update(true)
        return true
    end
    return false
end

------------------------------------------------------------
-- Events
------------------------------------------------------------
ashita.events.register('load', 'singer_load_cb', function()
    state.next_cycle = now_clock() + 2.0
    load_hud_settings()
    hud_update(true)
    echo('Loaded (Ashita v4, FontManager HUD). Use /singer help')

    if load_settings() then
        echo('settings.lua loaded. Use /singer playlists and /singer playlist <name>.')
    end
end)

ashita.events.register('unload', 'singer_unload_cb', function()
    save_hud_settings()
    hud_destroy()
    echo('Unloaded.')
end)

-- BRD only (owner request 2026-08-30): like the Windower Singer's job gate, plus the HUD - on any other
-- main job the HUD is hidden and nothing is cast. Event-driven like Windower's 'job change': the job is
-- read from memory once at load and again only after a job-info packet (0x01B) or a zone-in (0x00A).
local job_is_brd, job_recheck = false, true
local function is_bard()
    if job_recheck then
        job_recheck = false
        local ok, job = pcall(function() return AshitaCore:GetMemoryManager():GetPlayer():GetMainJob() end)
        job_is_brd = (ok and tonumber(job) == 10) and true or false
    end
    return job_is_brd
end

ashita.events.register('packet_in', 'singer_job_cb', function(e)
    -- the packet arrives before the client applies it: defer the read to the next frame
    if e.id == 0x01B or e.id == 0x00A then job_recheck = true end
end)

ashita.events.register('d3d_present', 'singer_present_cb', function()
    local t = now_clock()
    if not is_bard() then
        if not state.hud_hidden_by_job then
            state.hud_hidden_by_job = true
            hud_set_visible(false)
        end
        return
    elseif state.hud_hidden_by_job then
        state.hud_hidden_by_job = false
    end
    hud_update(false)

    -- Execute one step at a time (without relying on QueueCommand to batch multiple commands)
    if state.pending ~= nil then
        local step = state.pending[state.pending_i]
        if step and t >= (state.next_action or 0.0) then
            queue_command(step.cmd, 0)
            local wait = tonumber(step.wait) or 0
            state.pending_i = state.pending_i + 1
            if state.pending_i > #state.pending then
                state.pending = nil
                state.pending_i = 0
                state.busy = false
                state.busy_until = 0.0
            else
                state.next_action = t + wait
            end
        end
        return
    end

    if state.busy and t >= (state.busy_until or 0.0) then
        state.busy = false
    end

    if not state.enabled then
        return
    end

    if state.busy then
        return
    end

    if t >= (state.next_cycle or 0.0) then
        cast_cycle()
        state.next_cycle = t + (state.interval or 240.0)
    end
end)

ashita.events.register('mouse', 'singer_mouse_cb', function(e)
    if state.hud_hidden_by_job then return end   -- hidden on non-BRD jobs: no clicks land on it
    if hud_handle_mouse(e) then e.blocked = true end
end)


ashita.events.register('command', 'singer_command_cb', function(e)
    local cmd = e.command or ''
    if cmd == '' then return end

    local parts = tokenize_command(cmd)
    if #parts == 0 then return end

    local p0 = norm_prefix(parts[1])
    if p0 ~= '/singer' and p0 ~= '/sing' then
        return
    end

    e.blocked = true

    local sub = (parts[2] or ''):lower()

    if sub == '' or sub == 'status' then
        show_status()
        return
    end

    if sub == 'help' then
        show_help()
        return
    end

    if sub == 'hud' then
        local action = (parts[3] or ''):lower()
        if action == '' or action == 'status' then
            echo(('HUD: %s | Collapsed: %s | Position: %d,%d'):format(
                state.hud_enabled and 'ON' or 'OFF',
                state.hud_collapsed and 'YES' or 'NO',
                state.hud_x,
                state.hud_y
            ))
        elseif action == 'on' then
            state.hud_enabled = true
            hud_update(true)
            save_hud_settings()
            echo('HUD: ON')
        elseif action == 'off' then
            state.hud_enabled = false
            hud_set_visible(false)
            save_hud_settings()
            echo('HUD: OFF')
        elseif action == 'toggle' then
            state.hud_enabled = not state.hud_enabled
            hud_update(true)
            save_hud_settings()
            echo(('HUD: %s'):format(state.hud_enabled and 'ON' or 'OFF'))
        elseif action == 'collapse' then
            state.hud_collapsed = not state.hud_collapsed
            hud_update(true)
            save_hud_settings()
        elseif action == 'reset' then
            state.hud_enabled = true
            state.hud_collapsed = false
            state.hud_x = 20
            state.hud_y = 120
            hud_update(true)
            save_hud_settings()
            echo('HUD reset.')
        elseif action == 'pos' or action == 'position' then
            local x = tonumber(parts[4])
            local y = tonumber(parts[5])
            if not x or not y then
                echo('Usage: /singer hud pos <x> <y>')
                return
            end
            state.hud_x = math.floor(x)
            state.hud_y = math.floor(y)
            hud_update(true)
            save_hud_settings()
        else
            echo('Usage: /singer hud on|off|toggle|collapse|reset|pos <x> <y>')
        end
        return
    elseif sub == 'on' then
        state.enabled = true
        state.busy = false
        state.next_cycle = now_clock() + 0.5
        echo('Enabled.')
        return
    elseif sub == 'off' then
        state.enabled = false
        state.busy = false
        echo('Disabled.')
        return
    elseif sub == 'toggle' then
        state.enabled = not state.enabled
        state.busy = false
        if state.enabled then
            state.next_cycle = now_clock() + 0.5
        end
        echo(('Toggled: %s'):format(state.enabled and 'ON' or 'OFF'))
        return
    elseif sub == 'now' then
        local ok = cast_cycle()
        if ok then
            echo('Casting.')
        else
            echo('Busy.')
        end
        return
    elseif sub == 'marcato' then
        local song = parts[3]
        if not song or song == '' then
            echo('Usage: /singer marcato "Song"')
            return
        end
        cast_marcato(song)
        return
    elseif sub == 'songs' then
        local new = {}
        for i = 3, #parts do
            if parts[i] and #parts[i] > 0 then
                new[#new+1] = parts[i]
            end
        end
        if #new == 0 then
            echo('No songs given.')
            return
        end
        state.songs = new
        echo('Songs updated.')
        show_status()
        return
    
elseif sub == 'playlists' then
    if not state.settings then
        load_settings()
    end
    list_playlists()
    return
elseif sub == 'playlist' then
    local name = parts[3]
    if not name or name == '' then
        echo('Usage: /singer playlist <name>')
        return
    end
    if not state.settings then
        load_settings()
    end
    set_playlist(name)
    return
elseif sub == 'delay' then
        local v = tonumber(parts[3] or '')
        if not v or v < 0.5 then
            echo('Invalid delay. Minimum 0.5')
            return
        end
        state.song_delay = v
        echo(('Delay set to %.1f'):format(state.song_delay))
        return
    elseif sub == 'interval' then
        local v = tonumber(parts[3] or '')
        if not v or v < 30 then
            echo('Invalid interval. Minimum 30')
            return
        end
        state.interval = v
        echo(('Interval set to %.0f'):format(state.interval))
        return
    elseif sub == 'target' then
        local t = parts[3]
        if not t or #t == 0 then
            echo('Invalid target.')
            return
        end
        state.target = t
        echo(('Target set to %s'):format(state.target))
        return
    elseif sub == 'nitro' then
        local v = (parts[3] or ''):lower()
        if v == '' or v == 'toggle' then
            state.nitro = not state.nitro
        elseif v == 'on' then
            state.nitro = true
        elseif v == 'off' then
            state.nitro = false
        else
            echo('Usage: /singer nitro on|off|toggle')
            return
        end
        echo(('Nitro: %s'):format(state.nitro and 'ON' or 'OFF'))
        return
    elseif sub == 'ccsv' then
        local v = (parts[3] or ''):lower()
        if v == '' or v == 'toggle' then
            state.ccsv = not state.ccsv
        elseif v == 'on' then
            state.ccsv = true
        elseif v == 'off' then
            state.ccsv = false
        else
            echo('Usage: /singer ccsv on|off|toggle')
            return
        end
        echo(('CCSV: %s'):format(state.ccsv and 'ON' or 'OFF'))
        return
    else
        echo('Unknown command. Use /singer help')
        return
    end
end)
