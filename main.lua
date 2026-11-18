--- Sandbox — a creative-mode toolbox for Balatro.
--- Four native-styled buttons appear on the right during a run:
---   [Cards] adds one playing card with a chosen rank, suit, enhancement,
---          edition and seal, into the hand or the draw pile.
---   [Stats] edits poker-hand levels, hands/discards, hand-size limit, and money.
---   [Deck]  opens the whole-deck editor for selecting and deleting cards.
---   [Browse] opens the full-screen browser: every Joker/Tarot/Planet/
---          Spectral/Voucher, paginated; CLICK a card to add it.
---
--- Uses only the game's own UI primitives (UIBox, CardArea, option cycles,
--- overlay menus) so everything looks and feels native.
---
--- All game-facing actions are pcall-guarded and log '[Ultimate Sandbox] ...' so version
--- differences surface as readable errors, not crashes.

print('[Ultimate Sandbox] loaded')

local SBX = {
  set = 'Joker',            -- current set: Joker / Tarot / Planet / Spectral
  edition = 1,              -- index into SBX.EDITIONS
  sticker = 1,              -- index into SBX.STICKERS
  page = 1,                 -- browser page
  stats_hand = 'High Card', -- selected poker hand in the run-values menu
  areas = {},               -- browser grid CardAreas
  delete_areas = {},        -- deck-deletion grid CardAreas
  delete_cards = {},        -- deck card references shown in the deletion grid
  delete_selected = {},     -- original card refs currently selected for deletion
  delete_selected_count = 0,
  delete_scale = 0.4,
  delete_mode = 'deck',     -- 'deck' or 'jokers'
}

SBX.SETS = { 'Joker', 'Tarot', 'Planet', 'Spectral', 'Voucher' }
SBX.SET_LABELS = {
  Joker = 'Jokers',
  Tarot = 'Tarot',
  Planet = 'Planet',
  Spectral = 'Spectral',
  Voucher = 'Vouchers',
}
SBX.EDITIONS = {
  { label = 'None', key = nil },
  { label = 'Foil', key = 'foil' },
  { label = 'Holo', key = 'holo' },
  { label = 'Polychrome', key = 'polychrome' },
  { label = 'Negative', key = 'negative' },
}
SBX.STICKERS = {
  { label = 'No Sticker', apply = nil },
  { label = 'Eternal', apply = function(c) c:set_eternal(true) end },
  { label = 'Perishable', apply = function(c) c:set_perishable(true) end },
  { label = 'Rental', apply = function(c) c:set_rental(true) end },
}

local BROWSER_ROWS, BROWSER_COLS = 2, 5
local NEGATIVE_EDITION_INDEX = 5

local function log(msg) print('[Ultimate Sandbox] ' .. tostring(msg)) end

local open_delete_browser
local toggle_delete_selection
local open_stats_browser

local function card_log_name(card)
  local base = card and card.base
  if base and base.value and base.suit then
    return tostring(base.value) .. '_' .. tostring(base.suit)
  end
  return card and card.ability and card.ability.name or '?'
end

local function delete_deck_card(card)
  if not (G and G.GAME and G.playing_cards and card) then
    return false, 'Not in a run'
  end
  if G.STATES and G.STATE == G.STATES.HAND_PLAYED then
    return false, 'Cards cannot be deleted while a hand is scoring'
  end

  local found = false
  for _, v in ipairs(G.playing_cards) do
    if v == card then found = true; break end
  end
  if not found then return false, 'This card is no longer in the deck' end

  local name = card_log_name(card)
  local ok, err = pcall(function() card:remove() end)
  if not ok then return false, tostring(err) end

  if G.deck then
    pcall(function()
      G.deck.config.card_limit = #G.playing_cards
      G.deck.config.card_limits.total_slots = #G.playing_cards
    end)
  end
  return true, name
end

-- ---------------------------------------------------------------- spawning

local function add_voucher(center)
  if not (G and G.GAME and G.GAME.used_vouchers) then
    return false, 'Not in a run'
  end
  if G.GAME.used_vouchers[center.key] then
    return false, 'This Voucher is already owned'
  end

  local voucher = {
    ability = {
      set = 'Voucher',
      name = center.name,
      extra = center.config and center.config.extra,
    },
    config = { center = center, center_key = center.key },
  }

  G.GAME.used_vouchers[center.key] = true
  local ok, err = pcall(Card.apply_to_run, nil, center)
  if not ok then
    G.GAME.used_vouchers[center.key] = nil
    return false, tostring(err)
  end

  if discover_card then pcall(discover_card, center) end
  if set_voucher_usage then pcall(set_voucher_usage, voucher) end
  if check_for_unlock then pcall(check_for_unlock, { type = 'run_redeem' }) end
  local voucher_state = G.GAME.current_round and G.GAME.current_round.voucher
  if type(voucher_state) == 'table' and type(voucher_state.spawn) == 'table' then
    voucher_state.spawn[center.key] = false
  end
  pcall(play_sound, 'coin1')
  return true
end

local function repair_voucher_state()
  if not (G and G.GAME and G.GAME.current_round) then return end
  local voucher_state = G.GAME.current_round.voucher
  if type(voucher_state) == 'table' and type(voucher_state.spawn) == 'table' then return end

  local repaired = { spawn = {} }
  if SMODS and SMODS.get_next_vouchers then
    local ok, next_vouchers = pcall(SMODS.get_next_vouchers, repaired)
    if ok and type(next_vouchers) == 'table' then repaired = next_vouchers end
  end
  if type(repaired.spawn) ~= 'table' then repaired.spawn = {} end
  G.GAME.current_round.voucher = repaired
  log('repaired current_round.voucher state')
end

local function spawn_center(center)
  if not (G.jokers and G.consumeables and center) then return end

  if center.set == 'Voucher' then
    local applied, reason = add_voucher(center)
    if applied then
      log('redeemed Voucher ' .. (center.name or center.key))
    else
      log('could not redeem Voucher ' .. tostring(center.key) .. ': ' .. tostring(reason))
    end
    return applied
  end

  local edition = SBX.EDITIONS[SBX.edition]
  if center.set ~= 'Joker' and edition.key ~= 'negative' then edition = SBX.EDITIONS[1] end
  local sticker = SBX.STICKERS[SBX.sticker]

  local ok, err = pcall(function()
    if center.set == 'Joker' then
      local card = create_card('Joker', G.jokers, nil, nil, nil, nil, center.key)
      card:set_edition(nil, true, true) -- clear the randomly-polled edition
      card:add_to_deck()
      G.jokers:emplace(card)
      if edition.key then card:set_edition({ [edition.key] = true }, true) end
      if sticker.apply then sticker.apply(card) end
      card:juice_up(0.7, 0.7)
      play_sound('timpani')
    else
      local card = create_card(center.set, G.consumeables, nil, nil, nil, nil, center.key)
      card:add_to_deck()
      G.consumeables:emplace(card)
      -- only Negative exists on consumables in the base game
      if edition.key == 'negative' then card:set_edition({ negative = true }, true) end
      card:juice_up(0.7, 0.7)
      play_sound('card1')
    end
  end)
  if ok then
    log('spawned ' .. (center.name or center.key))
  else
    log('spawn error for ' .. tostring(center.key) .. ': ' .. tostring(err))
  end
  return ok
end

-- Click-to-spawn: cards inside sandbox areas spawn their center on click.
local orig_card_click = Card.click
function Card:click()
  if self.area and self.area.config and self.area.config.sandbox_delete then
    toggle_delete_selection(self)
    return
  end
  if self.area and self.area.config and self.area.config.sandbox_grid then
    local spawned = spawn_center(self.config.center)
    if spawned and self.config.center.set == 'Voucher' then self.greyed = true end
    if self.juice_up then self:juice_up(0.4, 0.4) end
    return
  end
  return orig_card_click(self)
end

-- ---------------------------------------------------------------- window safety
-- Exclusive fullscreen on Windows can crash or become unrecoverable after
-- Win+D / Show Desktop.  Keep fullscreen, but use LÖVE's borderless desktop
-- mode so the window is a normal minimizable top-level window.
local function log_window_mode(tag)
  local ok, full, fstype = pcall(love.window.getFullscreen)
  if ok then log(tag .. ': fullscreen=' .. tostring(full) .. ', type=' .. tostring(fstype)) end
end

local function use_borderless_fullscreen()
  local ok, full, fstype = pcall(love.window.getFullscreen)
  if ok and full and fstype ~= 'desktop' then
    local switched = pcall(love.window.setFullscreen, true, 'desktop')
    log('fullscreen switched to desktop: ' .. tostring(switched))
  end
end

local orig_set_fullscreen = love.window.setFullscreen
function love.window.setFullscreen(fullscreen, fstype, ...)
  if fullscreen and (fstype == nil or fstype == 'exclusive') then
    fstype = 'desktop'
  end
  return orig_set_fullscreen(fullscreen, fstype, ...)
end

local orig_love_focus = love.focus
function love.focus(focused, ...)
  if focused then
    pcall(function()
      if love.window.isMinimized and love.window.isMinimized() then
        love.window.restore()
      end
      local full, fstype = love.window.getFullscreen()
      if full and fstype ~= 'desktop' then
        love.window.setFullscreen(true, 'desktop')
      end
    end)
  end
  if orig_love_focus then return orig_love_focus(focused, ...) end
end

log_window_mode('window mode')
use_borderless_fullscreen()
log_window_mode('window mode after safety')

-- ---------------------------------------------------------------- cursor safety
-- Balatro hides the OS cursor at boot and expects to show it again on HID
-- transitions.  On some systems that visibility update is lost, leaving mouse
-- mode with neither the OS pointer nor the gamepad cursor.  While the game
-- has focus and the mouse is the active input, draw the pointer ourselves.
local last_mouse_activity = -math.huge

local function mark_mouse_activity()
  last_mouse_activity = love.timer.getTime()
end

local function mouse_mode_active(controller)
  return controller and controller.HID
    and (controller.HID.mouse or love.timer.getTime() - last_mouse_activity < 0.35)
end

local orig_mousemoved = love.mousemoved
function love.mousemoved(x, y, ...)
  mark_mouse_activity()
  return orig_mousemoved(x, y, ...)
end

local orig_mousepressed = love.mousepressed
function love.mousepressed(x, y, ...)
  mark_mouse_activity()
  return orig_mousepressed(x, y, ...)
end

local orig_controller_update = Controller.update
function Controller:update(dt)
  local ret = orig_controller_update(self, dt)
  if mouse_mode_active(self) and love.window.hasFocus() then
    if love.mouse.isVisible() then love.mouse.setVisible(false) end
  elseif not love.window.hasFocus() and not love.mouse.isVisible() then
    love.mouse.setVisible(true)
  end
  return ret
end

local function draw_sandbox_cursor()
  if not (G and G.CONTROLLER and mouse_mode_active(G.CONTROLLER) and love.window.hasFocus()) then
    return
  end

  local x, y = love.mouse.getPosition()
  local s = math.max(1, math.min(love.graphics.getWidth() / 1600, love.graphics.getHeight() / 900))
  love.graphics.push('all')
  love.graphics.origin()
  love.graphics.setCanvas()
  love.graphics.setShader()
  love.graphics.setScissor()
  love.graphics.setBlendMode('alpha')
  love.graphics.setColor(0, 0, 0, 0.9)
  love.graphics.polygon('fill',
    x, y,
    x, y + 19 * s,
    x + 5.5 * s, y + 14.5 * s,
    x + 8.5 * s, y + 21.5 * s,
    x + 12.5 * s, y + 19.5 * s,
    x + 9.5 * s, y + 12.5 * s,
    x + 16 * s, y + 12.5 * s)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.polygon('fill',
    x + 2 * s, y + 2 * s,
    x + 2 * s, y + 14.5 * s,
    x + 5.8 * s, y + 11.2 * s,
    x + 9.2 * s, y + 18 * s,
    x + 11 * s, y + 17 * s,
    x + 7.6 * s, y + 10.2 * s,
    x + 14 * s, y + 10.2 * s)
  love.graphics.pop()
end

local orig_love_draw = love.draw
function love.draw(...)
  orig_love_draw(...)
  draw_sandbox_cursor()
end

-- ---------------------------------------------------------------- grid filling

local function clear_area(area)
  for i = #area.cards, 1, -1 do
    local c = area:remove_card(area.cards[i])
    c:remove(); c = nil
  end
end

local function fill_areas(areas, set, page, cols, scale)
  scale = scale or 1
  local pool = G.P_CENTER_POOLS[set]
  local per_page = #areas * cols
  for j = 1, #areas do clear_area(areas[j]) end
  for j = 1, #areas do
    for i = 1, cols do
      local center = pool[i + (j - 1) * cols + per_page * (page - 1)]
      if center then
        local card = Card(
          areas[j].T.x + areas[j].T.w / 2, areas[j].T.y,
          G.CARD_W * scale, G.CARD_H * scale, G.P_CARDS.empty, center,
          { bypass_discovery_center = true, bypass_discovery_ui = true })
        if set == 'Joker' and get_joker_win_sticker then
          card.sticker = get_joker_win_sticker(center)
        end
        if set == 'Voucher' and G.GAME.used_vouchers[center.key] then
          card.greyed = true
        end
        card.states.drag.can = true
        areas[j]:emplace(card)
      end
    end
  end
end

local function pages_for(set, per_page)
  return math.max(1, math.ceil(#G.P_CENTER_POOLS[set] / per_page))
end

-- ---------------------------------------------------------------- browser (overlay)

local function browser_definition()
  local set = SBX.set
  local pages = pages_for(set, BROWSER_ROWS * BROWSER_COLS)
  if SBX.page > pages then SBX.page = 1 end

  SBX.areas = {}
  local deck_tables = {}
  for j = 1, BROWSER_ROWS do
    SBX.areas[j] = CardArea(
      G.ROOM.T.x + 0.2 * G.ROOM.T.w / 2, G.ROOM.T.h,
      BROWSER_COLS * G.CARD_W, 0.95 * G.CARD_H,
      { card_limit = BROWSER_COLS, type = 'title', highlight_limit = 0, collection = true, sandbox_grid = true })
    table.insert(deck_tables,
      { n = G.UIT.R, config = { align = 'cm', padding = 0.05, no_fill = true }, nodes = {
        { n = G.UIT.O, config = { object = SBX.areas[j] } },
      } })
  end

  local tab_buttons = {}
  for _, s in ipairs(SBX.SETS) do
    table.insert(tab_buttons, UIBox_button({
      button = 'sbx_set_' .. s, label = { SBX.SET_LABELS[s] or s },
      minw = 1.15, minh = 0.42, scale = 0.3, col = true,
      colour = (s == set) and G.C.RED or G.C.BOOSTER,
    }))
  end

  local page_options = {}
  for i = 1, pages do page_options[i] = 'Page ' .. i .. '/' .. pages end
  local edition_options, sticker_options, edition_index = {}, {}, 1
  if set == 'Joker' then
    for i, e in ipairs(SBX.EDITIONS) do edition_options[i] = e.label end
    for i, st in ipairs(SBX.STICKERS) do sticker_options[i] = st.label end
    edition_index = SBX.edition
  elseif set ~= 'Voucher' then
    edition_options[1] = SBX.EDITIONS[1].label
    edition_options[2] = SBX.EDITIONS[NEGATIVE_EDITION_INDEX].label
    edition_index = SBX.edition == NEGATIVE_EDITION_INDEX and 2 or 1
  end

  local contents = {
    { n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = tab_buttons },
  }

  if set ~= 'Voucher' then
    local picker_nodes = {
      create_option_cycle({ options = edition_options, w = 2.2, opt_callback = 'sbx_edition',
        current_option = edition_index, colour = G.C.DARK_EDITION, no_pips = true, scale = 0.58 }),
    }
    if set == 'Joker' then
      picker_nodes[#picker_nodes + 1] = create_option_cycle({ options = sticker_options, w = 2.2,
        opt_callback = 'sbx_sticker', current_option = SBX.sticker,
        colour = G.C.ETERNAL or G.C.RED, no_pips = true, scale = 0.58 })
    end
    table.insert(contents, { n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = picker_nodes })
  end

  table.insert(contents, { n = G.UIT.R, config = { align = 'cm', r = 0.1, colour = G.C.BLACK, emboss = 0.05 }, nodes = deck_tables })
  table.insert(contents, { n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
      { n = G.UIT.T, config = { text = set == 'Voucher'
          and 'Click a Voucher to redeem it permanently. Owned Vouchers are dimmed.'
          or 'Click a card to add it to the current run',
        scale = 0.3, colour = G.C.UI.TEXT_LIGHT } },
    } })
  table.insert(contents, { n = G.UIT.R, config = { align = 'cm' }, nodes = {
      create_option_cycle({ options = page_options, w = 4.5, cycle_shoulders = true,
        opt_callback = 'sbx_page', current_option = SBX.page, colour = G.C.RED, no_pips = true,
        focus_args = { snap_to = true, nav = 'wide' } }),
    } })

  return create_UIBox_generic_options({ back_func = 'exit_overlay_menu', padding = 0.1, contents = contents })
end

local function open_browser()
  local ok, err = pcall(function()
    G.SETTINGS.paused = true
    G.FUNCS.overlay_menu({ definition = browser_definition() })
    fill_areas(SBX.areas, SBX.set, SBX.page, BROWSER_COLS)
  end)
  if not ok then log('browser error: ' .. tostring(err)) end
end

-- ---------------------------------------------------------------- G.FUNCS wiring

G.FUNCS.sbx_open_browser = function() open_browser() end
for _, s in ipairs(SBX.SETS) do
  G.FUNCS['sbx_set_' .. s] = function()
    SBX.set = s; SBX.page = 1
    if s ~= 'Joker' and s ~= 'Voucher' and SBX.edition ~= NEGATIVE_EDITION_INDEX then
      SBX.edition = 1
    end
    open_browser() -- overlay_menu replaces the previous overlay
  end
end

G.FUNCS.sbx_page = function(args)
  if not args or not args.cycle_config then return end
  SBX.page = args.cycle_config.current_option
  local ok, err = pcall(fill_areas, SBX.areas, SBX.set, SBX.page, BROWSER_COLS)
  if not ok then log('page error: ' .. tostring(err)) end
end

G.FUNCS.sbx_edition = function(args)
  if not (args and args.cycle_config) then return end
  local option = args.cycle_config.current_option
  if SBX.set == 'Joker' then
    SBX.edition = option
  else
    SBX.edition = option == 2 and NEGATIVE_EDITION_INDEX or 1
  end
end

G.FUNCS.sbx_sticker = function(args)
  if args and args.cycle_config then SBX.sticker = args.cycle_config.current_option end
end

-- ---------------------------------------------------------------- HUD buttons

local function buttons_definition()
  return { n = G.UIT.ROOT, config = { align = 'cm', colour = G.C.CLEAR }, nodes = {
    { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
      UIBox_button({ button = 'sbx_open_playing', label = { 'Cards' }, minw = 0.92, maxw = 0.92,
        minh = 0.6, scale = 0.25, colour = G.C.BOOSTER }),
    } },
    { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
      UIBox_button({ button = 'sbx_open_stats', label = { 'Stats' }, minw = 0.92, maxw = 0.92,
        minh = 0.6, scale = 0.25, colour = G.C.GREEN }),
    } },
    { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
      UIBox_button({ button = 'sbx_open_delete', label = { 'Deck' }, minw = 0.92, maxw = 0.92,
        minh = 0.6, scale = 0.25, colour = G.C.RED }),
    } },
    { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
      UIBox_button({ button = 'sbx_open_browser', label = { 'Browse' }, minw = 0.92, maxw = 0.92,
        minh = 0.6, scale = 0.25, colour = G.C.BOOSTER }),
    } },
  } }
end

local function create_hud_buttons()
  if G.SANDBOX_BUTTON then return end
  local ok, err = pcall(function()
    -- right edge at mid-height: free in every game state (consumable cards fill
    -- the old top-right corner), and attention-flagged so cards never cover it
    G.SANDBOX_BUTTON = UIBox({
      definition = buttons_definition(),
      config = { align = 'cri', offset = { x = -0.05, y = 0 }, major = G.ROOM_ATTACH, bond = 'Weak' },
    })
    G.SANDBOX_BUTTON.attention_text = true
  end)
  if not ok then log('button error: ' .. tostring(err)) end
end

local function remove_hud_buttons()
  if G.SANDBOX_BUTTON then
    pcall(function() G.SANDBOX_BUTTON:remove() end)
    G.SANDBOX_BUTTON = nil
  end
end

local orig_start_run = Game.start_run
function Game:start_run(args)
  local ret = orig_start_run(self, args)
  create_hud_buttons()
  return ret
end

local orig_delete_run = Game.delete_run
function Game:delete_run(...)
  remove_hud_buttons()
  return orig_delete_run(self, ...)
end

local orig_update_shop = Game.update_shop
function Game:update_shop(dt)
  repair_voucher_state()
  return orig_update_shop(self, dt)
end

-- ------------------------------------------------- test hotkeys (from v0.1)
-- Secondary feature for calculator validation: spawn playing cards into hand,
-- set hand levels, toggle Plasma scoring. Hold LEFT SHIFT + key. SHIFT+H = help.

local RANK_CODE = { [2]='2',[3]='3',[4]='4',[5]='5',[6]='6',[7]='7',[8]='8',[9]='9',[10]='T',[11]='J',[12]='Q',[13]='K',[14]='A' }
local SUITS = { 'S', 'H', 'D', 'C' }
local ENHANCEMENTS = { 'none', 'steel', 'bonus', 'mult', 'glass', 'stone', 'gold', 'lucky', 'wild' }
local ENH_CENTER = { steel='m_steel', bonus='m_bonus', mult='m_mult', glass='m_glass', stone='m_stone', gold='m_gold', lucky='m_lucky', wild='m_wild' }
local CARD_EDITION_KEY = { foil='foil', holographic='holo', polychrome='polychrome' }
local CARD_EDITIONS = { 'none', 'foil', 'holographic', 'polychrome' }
local SEALS = { 'none', 'red', 'blue', 'gold', 'purple' }
local SEAL_NAME = { red='Red', blue='Blue', gold='Gold', purple='Purple' }

local hk = { rank = 13, suit = 1, enh = 1, ed = 1, seal = 1 }
local saved_back_name = nil

local function hk_desc()
  return string.format('card=%s%s enh=%s ed=%s seal=%s',
    RANK_CODE[hk.rank], SUITS[hk.suit], ENHANCEMENTS[hk.enh], CARD_EDITIONS[hk.ed], SEALS[hk.seal])
end

local function hk_spawn_card()
  if not (G and G.hand) then log('start a run first'); return end
  local enh, ed, seal = ENHANCEMENTS[hk.enh], CARD_EDITIONS[hk.ed], SEALS[hk.seal]
  local ok, err = pcall(function()
    local key = SUITS[hk.suit] .. '_' .. RANK_CODE[hk.rank]
    local center = (enh ~= 'none') and G.P_CENTERS[ENH_CENTER[enh]] or G.P_CENTERS.c_base
    local card = create_playing_card({ front = G.P_CARDS[key], center = center }, G.hand)
    if ed ~= 'none' then card:set_edition({ [CARD_EDITION_KEY[ed]] = true }, true) end
    if seal ~= 'none' then card:set_seal(SEAL_NAME[seal], true) end
  end)
  log(ok and ('spawned ' .. RANK_CODE[hk.rank] .. SUITS[hk.suit] .. ' into hand') or ('card err: ' .. tostring(err)))
end

local function hk_bump_level(delta)
  if not (G.GAME and G.GAME.hands and G.GAME.hands['High Card']) then log('no run'); return end
  local ok, err = pcall(function()
    local ref = (G.jokers and G.jokers.cards[1]) or (G.hand and G.hand.cards[1])
    level_up_hand(ref, 'High Card', true, delta)
  end)
  log(ok and ('High Card level = ' .. G.GAME.hands['High Card'].level) or ('level err: ' .. tostring(err)))
end

local function hk_toggle_plasma()
  if not (G.GAME and G.GAME.selected_back) then log('no run'); return end
  if G.GAME.selected_back.name == 'Plasma Deck' then
    G.GAME.selected_back.name = saved_back_name or 'Red Deck'
    log('Plasma OFF (' .. G.GAME.selected_back.name .. ')')
  else
    saved_back_name = G.GAME.selected_back.name
    G.GAME.selected_back.name = 'Plasma Deck'
    log('Plasma ON (scoring only)')
  end
end

local HK = {
  r = function() hk.rank = hk.rank == 14 and 2 or hk.rank + 1; log(hk_desc()) end,
  t = function() hk.suit = hk.suit % #SUITS + 1; log(hk_desc()) end,
  e = function() hk.enh = hk.enh % #ENHANCEMENTS + 1; log(hk_desc()) end,
  g = function() hk.ed = hk.ed % #CARD_EDITIONS + 1; log(hk_desc()) end,
  b = function() hk.seal = hk.seal % #SEALS + 1; log(hk_desc()) end,
  c = hk_spawn_card,
  l = function() hk_bump_level(1) end,
  k = function() hk_bump_level(-1) end,
  p = hk_toggle_plasma,
  z = function()
    if G and G.hand then pcall(function()
      for i = #G.hand.cards, 1, -1 do G.hand.cards[i]:remove() end
    end) end
    log('cleared hand')
  end,
  h = function()
    log(hk_desc())
    print([[
[Ultimate Sandbox] Hotkeys (hold Left Shift):
  R/T   change rank / suit       E/G/B change enhancement / edition / seal
  C     add the card to hand     Z     clear hand
  L/K   High Card level +1 / -1  P     toggle Plasma Deck scoring
Jokers and consumables: use the [Browse] browser button.
Playing cards: use [Cards] to choose rank, suit, enhancement, edition and seal.]])
  end,
}

local orig_keypressed = love.keypressed
function love.keypressed(key, ...)
  local shift = love.keyboard.isDown('lshift') or love.keyboard.isDown('rshift')
  if shift and HK[key] and not G.OVERLAY_MENU then
    local ok, err = pcall(HK[key])
    if not ok then log('hotkey err: ' .. tostring(err)) end
    return
  end
  if orig_keypressed then return orig_keypressed(key, ...) end
end

-- ---------------------------------------------------------------- run values
-- Custom poker-hand levels, current/base hand & discard counts, and money.

local STATS_HANDS = {
  'High Card', 'Pair', 'Two Pair', 'Three of a Kind', 'Straight', 'Flush',
  'Full House', 'Four of a Kind', 'Straight Flush', 'Five of a Kind',
  'Flush House', 'Flush Five',
}

local ALL_HANDS = '__all_hands__'

-- Every poker hand in the run, including hands contributed by other mods.
local function all_hand_keys()
  local keys = {}
  if not (G and G.GAME and G.GAME.hands) then return keys end
  for key, hand in pairs(G.GAME.hands) do
    if type(hand) == 'table' and tonumber(hand.level) then keys[#keys + 1] = key end
  end
  table.sort(keys)
  return keys
end

local function stats_clamp(value, low, high)
  if value < low then return low end
  if value > high then return high end
  return value
end

local function stats_button(label, button, colour, width)
  width = width or 0.34
  return {
    n = G.UIT.C,
    config = {
      align = 'cm', padding = 0.015, r = 0.07, minw = width, maxw = width,
      minh = 0.30, colour = colour or G.C.BOOSTER, shadow = true, hover = true,
      button = button, focus_args = { snap_to = true },
    },
    nodes = {
      { n = G.UIT.T, config = { text = label, scale = 0.21, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
    },
  }
end

local function stats_section(title)
  return { n = G.UIT.R, config = { align = 'cm', padding = 0.025 }, nodes = {
    { n = G.UIT.T, config = { text = title, scale = 0.34, colour = G.C.ORANGE, shadow = true } },
  } }
end

local function stats_row(label, value, colour, buttons)
  local label_width = 2.1
  local nodes = {
    { n = G.UIT.C, config = { align = 'cm', minw = label_width, maxw = label_width }, nodes = {
      { n = G.UIT.R, config = { align = 'cm', padding = 0.01 }, nodes = {
        { n = G.UIT.T, config = { text = label .. '  ', scale = 0.26,
          colour = G.C.UI.TEXT_LIGHT, shadow = true } },
        { n = G.UIT.T, config = { text = tostring(value), scale = 0.32,
          colour = colour or G.C.WHITE, shadow = true } },
      } },
    } },
  }
  for _, button in ipairs(buttons) do nodes[#nodes + 1] = button end
  return { n = G.UIT.R, config = { align = 'cm', padding = 0.025 }, nodes = nodes }
end

local function stats_panel(title, width, rows)
  local nodes = { stats_section(title) }
  for _, row in ipairs(rows) do nodes[#nodes + 1] = row end
  return {
    n = G.UIT.C,
    config = { align = 'tm', minw = width, maxw = width, r = 0.09,
      colour = G.C.BLACK, emboss = 0.06, padding = 0.05 },
    nodes = nodes,
  }
end

local function stats_button_row(...)
  return { n = G.UIT.R, config = { align = 'cm', padding = 0.025 }, nodes = { ... } }
end

local function stats_hand_options()
  local options, current = { 'All Hands' }, 1
  if SBX.stats_hand == ALL_HANDS then current = 1 end
  for i, key in ipairs(STATS_HANDS) do
    local label = localize and localize(key, 'poker_hands')
    options[#options + 1] = type(label) == 'string' and label or key
    if key == SBX.stats_hand then current = #options end
  end
  return options, current
end

local function stats_definition()
  local hands = (G.GAME and G.GAME.hands) or {}
  local all_mode = SBX.stats_hand == ALL_HANDS
  local selected = hands[SBX.stats_hand] or hands['High Card'] or {}
  local current_round = (G.GAME and G.GAME.current_round) or {}
  local resets = (G.GAME and G.GAME.round_resets) or {}
  local options, option_index = stats_hand_options()
  local hand_limit = (G.hand and G.hand.config and G.hand.config.card_limit) or 0
  local all_keys = all_mode and all_hand_keys() or {}
  local level_value, detail_value = tostring(selected.level or 1), nil
  if all_mode then
    local low, high = nil, nil
    for _, key in ipairs(all_keys) do
      local lvl = tonumber(hands[key] and hands[key].level) or 1
      low = low and math.min(low, lvl) or lvl
      high = high and math.max(high, lvl) or lvl
    end
    level_value = (low and high and low ~= high) and (low .. '-' .. high) or tostring(low or 1)
    detail_value = #all_keys .. ' hands total'
  end

  local hand_panel = stats_panel('Hand Levels', 4.15, {
    { n = G.UIT.R, config = { align = 'cm', padding = 0.025 }, nodes = {
      create_option_cycle({ options = options, w = 2.7, opt_callback = 'sbx_stats_hand',
        current_option = option_index, colour = G.C.GREEN, no_pips = true, scale = 0.48 }),
    } },
    { n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
      { n = G.UIT.T, config = { text = 'Level ', scale = 0.29, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
      { n = G.UIT.T, config = { text = level_value, scale = 0.38,
        colour = G.C.ORANGE, shadow = true } },
      all_mode and { n = G.UIT.T, config = { text = '    ' .. (detail_value or ''),
        scale = 0.25, colour = G.C.UI.TEXT_LIGHT, shadow = true } }
        or { n = G.UIT.T, config = { text = '    Base ', scale = 0.25, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
      (not all_mode) and { n = G.UIT.T, config = {
        text = tostring(selected.chips or 0) .. ' x ' .. tostring(selected.mult or 0),
        scale = 0.30, colour = G.C.WHITE, shadow = true } } or nil,
    } },
    stats_button_row(
      stats_button('-10', 'sbx_level_m10', G.C.RED),
      stats_button('-1', 'sbx_level_m1', G.C.RED),
      stats_button('+1', 'sbx_level_p1', G.C.GREEN),
      stats_button('+10', 'sbx_level_p10', G.C.GREEN),
      stats_button(all_mode and 'Reset All' or 'Reset', 'sbx_level_reset', G.C.BLUE, all_mode and 0.98 or 0.58)
    ),
    all_mode and { n = G.UIT.R, config = { align = 'cm', padding = 0.015 }, nodes = {
      { n = G.UIT.T, config = { text = 'All hands change together; minimum 1.',
        scale = 0.21, colour = G.C.UI.TEXT_LIGHT } },
    } } or nil,
  })

  local counter_panel = stats_panel('Hands, Discards & Size', 5.2, {
    stats_row('Hand Limit', hand_limit, G.C.ORANGE, {
      stats_button('-10', 'sbx_handsize_m10', G.C.RED),
      stats_button('-1', 'sbx_handsize_m1', G.C.RED),
      stats_button('+1', 'sbx_handsize_p1', G.C.GREEN),
      stats_button('+10', 'sbx_handsize_p10', G.C.GREEN),
    }),
    stats_row('Hands This Blind', current_round.hands_left or 0, G.C.BLUE, {
      stats_button('-10', 'sbx_hands_cur_m10', G.C.RED),
      stats_button('-1', 'sbx_hands_cur_m1', G.C.RED),
      stats_button('+1', 'sbx_hands_cur_p1', G.C.GREEN),
      stats_button('+10', 'sbx_hands_cur_p10', G.C.GREEN),
    }),
    stats_row('Discards This Blind', current_round.discards_left or 0, G.C.RED, {
      stats_button('-10', 'sbx_discards_cur_m10', G.C.RED),
      stats_button('-1', 'sbx_discards_cur_m1', G.C.RED),
      stats_button('+1', 'sbx_discards_cur_p1', G.C.GREEN),
      stats_button('+10', 'sbx_discards_cur_p10', G.C.GREEN),
    }),
    stats_row('Future Base Hands', resets.hands or 0, G.C.BLUE, {
      stats_button('-10', 'sbx_hands_base_m10', G.C.RED),
      stats_button('-1', 'sbx_hands_base_m1', G.C.RED),
      stats_button('+1', 'sbx_hands_base_p1', G.C.GREEN),
      stats_button('+10', 'sbx_hands_base_p10', G.C.GREEN),
    }),
    stats_row('Future Base Discards', resets.discards or 0, G.C.RED, {
      stats_button('-10', 'sbx_discards_base_m10', G.C.RED),
      stats_button('-1', 'sbx_discards_base_m1', G.C.RED),
      stats_button('+1', 'sbx_discards_base_p1', G.C.GREEN),
      stats_button('+10', 'sbx_discards_base_p10', G.C.GREEN),
    }),
  })

  local economy_panel = stats_panel('Economy', 9.55, {
    stats_row('Money', (localize and localize('$') or '$') .. tostring((G.GAME and G.GAME.dollars) or 0),
      G.C.MONEY, {
        stats_button('-100', 'sbx_money_m100', G.C.RED, 0.46),
        stats_button('-10', 'sbx_money_m10', G.C.RED),
        stats_button('-1', 'sbx_money_m1', G.C.RED),
        stats_button('+1', 'sbx_money_p1', G.C.GREEN),
        stats_button('+10', 'sbx_money_p10', G.C.GREEN),
        stats_button('+100', 'sbx_money_p100', G.C.GREEN, 0.46),
        stats_button('Reset', 'sbx_money_reset', G.C.BLUE, 0.56),
      }),
  })

  local body = {
    { n = G.UIT.R, config = { align = 'cm', padding = 0.025 }, nodes = {
      { n = G.UIT.T, config = { text = 'Run Values', scale = 0.46, colour = G.C.ORANGE, shadow = true } },
    } },
    { n = G.UIT.R, config = { align = 'tm', padding = 0.035 }, nodes = {
      hand_panel,
      counter_panel,
    } },
    { n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = { economy_panel } },
    { n = G.UIT.R, config = { align = 'cm', minw = 9.55, minh = 0.6, padding = 0.05,
      r = 0.12, colour = G.C.ORANGE, hover = true, shadow = true,
      button = 'exit_overlay_menu', focus_args = { nav = 'wide', button = 'b' } }, nodes = {
      { n = G.UIT.T, config = { text = localize('b_back'), scale = 0.42,
        colour = G.C.UI.TEXT_LIGHT, shadow = true } },
    } },
  }

  return {
    n = G.UIT.ROOT,
    config = { align = 'cm', minw = G.ROOM.T.w * 5, minh = G.ROOM.T.h * 5,
      padding = 0.1, r = 0.1,
      colour = { G.C.GREY[1], G.C.GREY[2], G.C.GREY[3], 0.7 } },
    nodes = {
      { n = G.UIT.R, config = { align = 'cm', minh = 1, r = 0.3, padding = 0.07,
        minw = 10.35, colour = G.C.JOKER_GREY, emboss = 0.1 }, nodes = {
        { n = G.UIT.C, config = { align = 'cm', minh = 1, r = 0.2, padding = 0.16,
          minw = 10.05, colour = G.C.L_BLACK }, nodes = {
          { n = G.UIT.R, config = { align = 'cm', padding = 0.05, minw = 9.55 }, nodes = body },
        } },
      } },
    },
  }
end

open_stats_browser = function()
  local ok, err = pcall(function()
    G.SETTINGS.paused = true
    G.FUNCS.overlay_menu({ definition = stats_definition() })
  end)
  if not ok then log('stats overlay error: ' .. tostring(err)) end
end

local function adjust_hand_level(delta)
  if not (G and G.GAME and G.GAME.hands) then return end

  if SBX.stats_hand == ALL_HANDS then
    local changed, first_error = 0, nil
    for _, key in ipairs(all_hand_keys()) do
      local hand = G.GAME.hands[key]
      local old = tonumber(hand.level) or 1
      local target = stats_clamp(old + delta, 1, 9999)
      if target ~= old then
        local ok, err = pcall(level_up_hand, nil, key, true, target - old)
        if ok then
          changed = changed + 1
        else
          first_error = first_error or err
        end
      end
    end
    if changed > 0 then
      log('all hand levels ' .. (delta > 0 and '+' or '') .. delta .. ' on ' .. changed .. ' hands')
      pcall(play_sound, 'tarot1')
    else
      pcall(play_sound, 'cancel')
    end
    if first_error then log('all hand level error: ' .. tostring(first_error)) end
    open_stats_browser()
    return
  end

  local key = SBX.stats_hand
  local hand = G.GAME.hands[key]
  if not hand then return end

  local old = tonumber(hand.level) or 1
  local target = stats_clamp(old + delta, 1, 9999)
  if target == old then
    pcall(play_sound, 'cancel')
    return
  end

  local ok, err = pcall(level_up_hand, nil, key, true, target - old)
  if ok then
    log('hand level ' .. key .. ': ' .. old .. ' -> ' .. target)
    pcall(play_sound, 'tarot1')
  else
    log('hand level error: ' .. tostring(err))
  end
  open_stats_browser()
end

local function adjust_current(field, delta, low, high)
  if not (G and G.GAME and G.GAME.current_round) then return end
  local round = G.GAME.current_round
  local old = tonumber(round[field]) or 0
  local target = stats_clamp(old + delta, low, high)
  if target ~= old then
    round[field] = target
    log(field .. ': ' .. old .. ' -> ' .. target)
    pcall(play_sound, 'cardSlide1')
  else
    pcall(play_sound, 'cancel')
  end
  open_stats_browser()
end

local function adjust_base(field, delta, low, high)
  if not (G and G.GAME and G.GAME.round_resets) then return end
  local resets = G.GAME.round_resets
  local old = tonumber(resets[field]) or 0
  local target = stats_clamp(old + delta, low, high)
  if target ~= old then
    resets[field] = target
    log('base ' .. field .. ': ' .. old .. ' -> ' .. target)
    pcall(play_sound, 'cardSlide1')
  else
    pcall(play_sound, 'cancel')
  end
  open_stats_browser()
end

local function adjust_hand_limit(delta)
  if not (G and G.hand and G.hand.config) then return end
  local config = G.hand.config
  local old = tonumber(config.card_limit)
    or tonumber(config.card_limits and config.card_limits.total_slots) or 8
  local target = stats_clamp(old + delta, 1, 99)
  if target ~= old then
    local ok, err = pcall(function()
      config.card_limit = target
      if G.hand.handle_card_limit then G.hand:handle_card_limit() end
    end)
    if ok then
      log('hand limit: ' .. old .. ' -> ' .. target)
      pcall(play_sound, 'cardSlide1')
    else
      log('hand limit error: ' .. tostring(err))
    end
  else
    pcall(play_sound, 'cancel')
  end
  open_stats_browser()
end

local function adjust_money(delta)
  if not (G and G.GAME) then return end
  local old = tonumber(G.GAME.dollars) or 0
  local target = stats_clamp(old + delta, 0, 999999)
  if target ~= old then
    local ok, err = pcall(ease_dollars, target - old, true)
    if ok then
      log('money: ' .. old .. ' -> ' .. target)
    else
      log('money error: ' .. tostring(err))
    end
  else
    pcall(play_sound, 'cancel')
  end
  open_stats_browser()
end

G.FUNCS.sbx_open_stats = function() open_stats_browser() end
G.FUNCS.sbx_stats_hand = function(args)
  if not args or not args.cycle_config then return end
  local option = args.cycle_config.current_option
  SBX.stats_hand = option == 1 and ALL_HANDS or (STATS_HANDS[option - 1] or STATS_HANDS[1])
  open_stats_browser()
end
G.FUNCS.sbx_level_m10 = function() adjust_hand_level(-10) end
G.FUNCS.sbx_level_m1 = function() adjust_hand_level(-1) end
G.FUNCS.sbx_level_p1 = function() adjust_hand_level(1) end
G.FUNCS.sbx_level_p10 = function() adjust_hand_level(10) end
G.FUNCS.sbx_level_reset = function()
  if SBX.stats_hand == ALL_HANDS then
    local changed = 0
    for _, key in ipairs(all_hand_keys()) do
      local hand = G.GAME.hands[key]
      local old = tonumber(hand.level) or 1
      if old ~= 1 then
        local ok = pcall(level_up_hand, nil, key, true, 1 - old)
        if ok then changed = changed + 1 end
      end
    end
    log('all hand levels reset to 1 (' .. changed .. ' changed)')
    pcall(play_sound, changed > 0 and 'tarot1' or 'cancel')
    open_stats_browser()
    return
  end
  local hand = G.GAME and G.GAME.hands and G.GAME.hands[SBX.stats_hand]
  if hand then adjust_hand_level(1 - (tonumber(hand.level) or 1)) end
end
G.FUNCS.sbx_hands_cur_m10 = function() adjust_current('hands_left', -10, 0, 999) end
G.FUNCS.sbx_hands_cur_m1 = function() adjust_current('hands_left', -1, 0, 999) end
G.FUNCS.sbx_hands_cur_p1 = function() adjust_current('hands_left', 1, 0, 999) end
G.FUNCS.sbx_hands_cur_p10 = function() adjust_current('hands_left', 10, 0, 999) end
G.FUNCS.sbx_discards_cur_m10 = function() adjust_current('discards_left', -10, 0, 999) end
G.FUNCS.sbx_discards_cur_m1 = function() adjust_current('discards_left', -1, 0, 999) end
G.FUNCS.sbx_discards_cur_p1 = function() adjust_current('discards_left', 1, 0, 999) end
G.FUNCS.sbx_discards_cur_p10 = function() adjust_current('discards_left', 10, 0, 999) end
G.FUNCS.sbx_hands_base_m10 = function() adjust_base('hands', -10, 1, 999) end
G.FUNCS.sbx_hands_base_m1 = function() adjust_base('hands', -1, 1, 999) end
G.FUNCS.sbx_hands_base_p1 = function() adjust_base('hands', 1, 1, 999) end
G.FUNCS.sbx_hands_base_p10 = function() adjust_base('hands', 10, 1, 999) end
G.FUNCS.sbx_discards_base_m10 = function() adjust_base('discards', -10, 0, 999) end
G.FUNCS.sbx_discards_base_m1 = function() adjust_base('discards', -1, 0, 999) end
G.FUNCS.sbx_discards_base_p1 = function() adjust_base('discards', 1, 0, 999) end
G.FUNCS.sbx_discards_base_p10 = function() adjust_base('discards', 10, 0, 999) end
G.FUNCS.sbx_handsize_m10 = function() adjust_hand_limit(-10) end
G.FUNCS.sbx_handsize_m1 = function() adjust_hand_limit(-1) end
G.FUNCS.sbx_handsize_p1 = function() adjust_hand_limit(1) end
G.FUNCS.sbx_handsize_p10 = function() adjust_hand_limit(10) end
G.FUNCS.sbx_money_m100 = function() adjust_money(-100) end
G.FUNCS.sbx_money_m10 = function() adjust_money(-10) end
G.FUNCS.sbx_money_m1 = function() adjust_money(-1) end
G.FUNCS.sbx_money_p1 = function() adjust_money(1) end
G.FUNCS.sbx_money_p10 = function() adjust_money(10) end
G.FUNCS.sbx_money_p100 = function() adjust_money(100) end
G.FUNCS.sbx_money_reset = function() adjust_money(-((G.GAME and G.GAME.dollars) or 0)) end

-- ---------------------------------------------------------------- playing cards
-- Add a single playing card with a chosen rank, suit, enhancement, edition and
-- seal, either into the current hand or into the draw pile.

local PC_RANKS = {
  { code = 'A', label = 'A' }, { code = '2', label = '2' }, { code = '3', label = '3' },
  { code = '4', label = '4' }, { code = '5', label = '5' }, { code = '6', label = '6' },
  { code = '7', label = '7' }, { code = '8', label = '8' }, { code = '9', label = '9' },
  { code = 'T', label = '10' }, { code = 'J', label = 'J' }, { code = 'Q', label = 'Q' },
  { code = 'K', label = 'K' },
}
local PC_SUITS = {
  { code = 'S', label = 'Spades' }, { code = 'H', label = 'Hearts' },
  { code = 'D', label = 'Diamonds' }, { code = 'C', label = 'Clubs' },
}
local PC_ENHANCEMENTS = {
  { label = 'No Enhancement' },
  { label = 'Steel', center = 'm_steel' },
  { label = 'Bonus', center = 'm_bonus' },
  { label = 'Mult', center = 'm_mult' },
  { label = 'Glass', center = 'm_glass' },
  { label = 'Stone', center = 'm_stone' },
  { label = 'Gold', center = 'm_gold' },
  { label = 'Lucky', center = 'm_lucky' },
  { label = 'Wild', center = 'm_wild' },
}
local PC_EDITIONS = {
  { label = 'None' }, { label = 'Foil', key = 'foil' },
  { label = 'Holo', key = 'holo' }, { label = 'Polychrome', key = 'polychrome' },
}
local PC_SEALS = {
  { label = 'No Seal' }, { label = 'Red Seal', name = 'Red' }, { label = 'Blue Seal', name = 'Blue' },
  { label = 'Gold Seal', name = 'Gold' }, { label = 'Purple Seal', name = 'Purple' },
}

SBX.playing = { rank = 1, suit = 1, enh = 1, edition = 1, seal = 1 }

local function pc_front_key(p)
  return PC_SUITS[p.suit].code .. '_' .. PC_RANKS[p.rank].code
end

local function pc_center(p)
  local enh = PC_ENHANCEMENTS[p.enh]
  return enh.center and G.P_CENTERS[enh.center] or G.P_CENTERS.c_base
end

local function pc_apply_extras(card, p)
  local edition = PC_EDITIONS[p.edition]
  if edition.key then card:set_edition({ [edition.key] = true }, true) end
  local seal = PC_SEALS[p.seal]
  if seal.name then card:set_seal(seal.name, true) end
end

local function refresh_playing_preview()
  local area = SBX.playing_area
  if not area then return end
  for i = #area.cards, 1, -1 do
    local c = area:remove_card(area.cards[i])
    if c then c:remove() end
  end

  local p = SBX.playing
  local ok, err = pcall(function()
    local card = Card(0, 0, G.CARD_W, G.CARD_H, G.P_CARDS[pc_front_key(p)], pc_center(p),
      { bypass_discovery_center = true, bypass_discovery_ui = true })
    pc_apply_extras(card, p)
    card.states.drag.can = false
    area:emplace(card)
  end)
  if not ok then log('preview error: ' .. tostring(err)) end
end

local function spawn_playing_card(dest)
  if not (G and G.GAME and G.hand and G.deck) then
    log('not in a run')
    return
  end
  local p = SBX.playing
  local area = (dest == 'deck') and G.deck or G.hand
  local ok, err = pcall(function()
    local card = create_playing_card({ front = G.P_CARDS[pc_front_key(p)], center = pc_center(p) }, area)
    pc_apply_extras(card, p)
    card:juice_up(0.6, 0.6)
    play_sound('card1')
  end)
  if ok then
    log('added ' .. pc_front_key(p) .. ' to ' .. tostring(dest))
  else
    log('playing card error: ' .. tostring(err))
  end
end

local function playing_definition()
  SBX.playing_area = CardArea(0, 0, G.CARD_W, G.CARD_H,
    { card_limit = 1, type = 'title', highlight_limit = 0, collection = true })

  local function labels(list)
    local out = {}
    for i, v in ipairs(list) do out[i] = v.label end
    return out
  end

  local contents = {
    { n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
      create_option_cycle({ options = labels(PC_RANKS), w = 1.2, opt_callback = 'sbx_play_rank',
        current_option = SBX.playing.rank, colour = G.C.RED, no_pips = true, scale = 0.5 }),
      create_option_cycle({ options = labels(PC_SUITS), w = 2.0, opt_callback = 'sbx_play_suit',
        current_option = SBX.playing.suit, colour = G.C.RED, no_pips = true, scale = 0.45 }),
    } },
    { n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
      create_option_cycle({ options = labels(PC_ENHANCEMENTS), w = 2.3, opt_callback = 'sbx_play_enh',
        current_option = SBX.playing.enh, colour = G.C.DARK_EDITION, no_pips = true, scale = 0.45 }),
      create_option_cycle({ options = labels(PC_EDITIONS), w = 1.9, opt_callback = 'sbx_play_edition',
        current_option = SBX.playing.edition, colour = G.C.DARK_EDITION, no_pips = true, scale = 0.42 }),
      create_option_cycle({ options = labels(PC_SEALS), w = 1.8, opt_callback = 'sbx_play_seal',
        current_option = SBX.playing.seal, colour = G.C.DARK_EDITION, no_pips = true, scale = 0.42 }),
    } },
    { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
      { n = G.UIT.O, config = { object = SBX.playing_area } },
    } },
    { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
      UIBox_button({ button = 'sbx_play_hand', label = { 'Add to Hand' },
        minw = 1.8, maxw = 2.2, minh = 0.5, scale = 0.32, colour = G.C.BLUE }),
      UIBox_button({ button = 'sbx_play_deck', label = { 'Add to Deck' },
        minw = 1.8, maxw = 2.2, minh = 0.5, scale = 0.32, colour = G.C.GREEN }),
    } },
    { n = G.UIT.R, config = { align = 'cm' }, nodes = {
      { n = G.UIT.T, config = { text = 'Rank / suit / enhancement / edition / seal. Changes apply immediately.',
        scale = 0.27, colour = G.C.UI.TEXT_LIGHT } },
    } },
  }

  return create_UIBox_generic_options({ back_func = 'exit_overlay_menu', padding = 0.1, contents = contents })
end

local function open_playing()
  local ok, err = pcall(function()
    G.SETTINGS.paused = true
    G.FUNCS.overlay_menu({ definition = playing_definition() })
    refresh_playing_preview()
  end)
  if not ok then log('playing overlay error: ' .. tostring(err)) end
end

G.FUNCS.sbx_open_playing = function() open_playing() end
G.FUNCS.sbx_play_hand = function() spawn_playing_card('hand') end
G.FUNCS.sbx_play_deck = function() spawn_playing_card('deck') end

local function pc_option(key)
  return function(args)
    if args and args.cycle_config then
      SBX.playing[key] = args.cycle_config.current_option
      refresh_playing_preview()
    end
  end
end
G.FUNCS.sbx_play_rank = pc_option('rank')
G.FUNCS.sbx_play_suit = pc_option('suit')
G.FUNCS.sbx_play_enh = pc_option('enh')
G.FUNCS.sbx_play_edition = pc_option('edition')
G.FUNCS.sbx_play_seal = pc_option('seal')

-- ---------------------------------------------------------------- deck deletion
-- Shows the whole run deck on one screen. Clicking a card toggles its selection;
-- the delete button removes all selected cards at once and redraws the grid.

local DELETE_COLS = 13
local DELETE_BASE_SCALE = 0.4
local DELETE_SUIT_ORDER = { Spades = 1, Hearts = 2, Clubs = 3, Diamonds = 4 }

local function deck_card_list()
  local list = {}
  if not (G and G.GAME and G.playing_cards) then return list end
  for _, card in ipairs(G.playing_cards) do
    if card and not card.removed then list[#list + 1] = card end
  end
  table.sort(list, function(a, b)
    local ab, bb = a.base or {}, b.base or {}
    local ao = DELETE_SUIT_ORDER[ab.suit] or 9
    local bo = DELETE_SUIT_ORDER[bb.suit] or 9
    if ao ~= bo then return ao < bo end
    return (ab.id or 0) < (bb.id or 0)
  end)
  return list
end

local function joker_card_list()
  local list = {}
  if not (G and G.jokers and G.jokers.cards) then return list end
  for _, card in ipairs(G.jokers.cards) do
    if card and not card.removed then list[#list + 1] = card end
  end
  return list
end

local function delete_card_list()
  if SBX.delete_mode == 'jokers' then return joker_card_list() end
  return deck_card_list()
end

local function delete_joker_card(card)
  if not (G and G.jokers and card) then return false, 'not in a run' end
  if G.STATES and G.STATE == G.STATES.HAND_PLAYED then
    return false, 'cards cannot be deleted while a hand is scoring'
  end

  local found = false
  for _, v in ipairs(G.jokers.cards) do
    if v == card then found = true; break end
  end
  if not found then return false, 'this Joker is no longer in play' end

  local name = (card.config and card.config.center and card.config.center.name)
    or (card.ability and card.ability.name) or '?'
  -- Card:remove() unregisters the Joker without running sell logic, so eternal,
  -- perishable and rental stickers cannot block the deletion.
  local ok, err = pcall(function() card:remove() end)
  if not ok then
    pcall(function() G.jokers:remove_card(card) end)
    return false, tostring(err)
  end
  return true, name
end

local function fill_delete_areas()
  local areas = SBX.delete_areas or {}
  local cards = SBX.delete_cards or {}
  local scale = SBX.delete_scale or DELETE_BASE_SCALE
  for j = 1, #areas do clear_area(areas[j]) end
  for j = 1, #areas do
    for i = 1, DELETE_COLS do
      local original = cards[i + (j - 1) * DELETE_COLS]
      if original then
        local ok, err = pcall(function()
          local display = copy_card(original, nil, scale)
          display.T.x = areas[j].T.x + areas[j].T.w / 2
          display.T.y = areas[j].T.y
          display:hard_set_T()
          display.states.drag.can = false
          display.sandbox_delete_target = original
          areas[j]:emplace(display)
        end)
        if not ok then log('delete preview error: ' .. tostring(err)) end
      end
    end
  end
end

toggle_delete_selection = function(display)
  local target = display and display.sandbox_delete_target
  if not target then return end
  local area = display.area

  if SBX.delete_selected[target] then
    SBX.delete_selected[target] = nil
    SBX.delete_selected_count = math.max(0, SBX.delete_selected_count - 1)
    if area then pcall(function() area:remove_from_highlighted(display, true) end) end
  else
    SBX.delete_selected[target] = true
    SBX.delete_selected_count = SBX.delete_selected_count + 1
    if area then pcall(function() area:add_to_highlighted(display) end) end
  end
  pcall(play_sound, 'cardSlide1')
end

local function clear_delete_selection()
  for _, area in ipairs(SBX.delete_areas or {}) do
    pcall(function() area:unhighlight_all() end)
  end
  SBX.delete_selected = {}
  SBX.delete_selected_count = 0
end

local function delete_definition()
  local jokers = SBX.delete_mode == 'jokers'
  local cards = delete_card_list()
  SBX.delete_cards = cards

  local rows = math.max(1, math.ceil(#cards / DELETE_COLS))
  local scale = math.min(DELETE_BASE_SCALE, 1.65 / rows)
  if scale < 0.22 then scale = 0.22 end
  SBX.delete_scale = scale

  SBX.delete_areas = {}
  local deck_tables = {}
  for j = 1, rows do
    SBX.delete_areas[j] = CardArea(
      G.ROOM.T.x + 0.2 * G.ROOM.T.w / 2, G.ROOM.T.h,
      DELETE_COLS * G.CARD_W * scale, G.CARD_H * scale,
      { card_limit = DELETE_COLS, type = 'title', highlight_limit = 999,
        collection = true, sandbox_delete = true })
    table.insert(deck_tables,
      { n = G.UIT.R, config = { align = 'cm', padding = 0.02, no_fill = true }, nodes = {
        { n = G.UIT.O, config = { object = SBX.delete_areas[j] } },
      } })
  end

  local selection_count = DynaText({
    string = {{ prefix = 'Selected ', ref_table = SBX, ref_value = 'delete_selected_count',
      suffix = jokers and ' Jokers' or ' cards' }},
    colours = { G.C.WHITE }, shadow = true, scale = 0.45, pop_in = 0, silent = true,
  })

  local empty_note = nil
  if #cards == 0 then
    empty_note = { n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
      { n = G.UIT.T, config = { text = (jokers
          and 'No Jokers in play. Add some from the Browse screen first.'
          or 'The deck is empty.'),
        scale = 0.29, colour = G.C.UI.TEXT_LIGHT } },
    } }
  end

  local contents = {
    { n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
      UIBox_button({ button = 'sbx_delete_mode_deck', label = { 'Deck' },
        minw = 1.1, maxw = 1.3, minh = 0.48, scale = 0.33,
        colour = (not jokers) and G.C.RED or G.C.BLUE }),
      UIBox_button({ button = 'sbx_delete_mode_jokers', label = { 'Jokers' },
        minw = 1.3, maxw = 1.5, minh = 0.48, scale = 0.33,
        colour = jokers and G.C.RED or G.C.BLUE }),
    } },
    { n = G.UIT.R, config = { align = 'cm' }, nodes = {
      { n = G.UIT.T, config = { text = (jokers
          and ('' .. #cards .. ' Jokers in play. Click a Joker to toggle selection.')
          or ('This deck contains ' .. #cards .. ' cards. Click a card to toggle selection.')),
        scale = 0.29, colour = G.C.UI.TEXT_LIGHT } },
    } },
    empty_note or { n = G.UIT.R, config = { align = 'cm', r = 0.1, colour = G.C.BLACK, emboss = 0.05 }, nodes = deck_tables },
    { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
      { n = G.UIT.O, config = { object = selection_count } },
      UIBox_button({ button = 'sbx_delete_commit', label = { 'Delete Selected' },
        minw = 2.1, maxw = 2.4, minh = 0.5, scale = 0.31, colour = G.C.RED }),
      UIBox_button({ button = 'sbx_delete_clear', label = { 'Clear Selection' },
        minw = 2.0, maxw = 2.3, minh = 0.5, scale = 0.29, colour = G.C.BLUE }),
    } },
    { n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
      { n = G.UIT.T, config = { text = (jokers
          and 'Jokers are removed directly; eternal, perishable and rental stickers do not block deletion.'
          or 'All deck cards are shown. Deleting removes them from every deck area.'),
        scale = 0.26, colour = G.C.UI.TEXT_LIGHT } },
    } },
  }

  return create_UIBox_generic_options({ back_func = 'exit_overlay_menu', padding = 0.1, contents = contents })
end

open_delete_browser = function()
  clear_delete_selection()
  local ok, err = pcall(function()
    G.SETTINGS.paused = true
    G.FUNCS.overlay_menu({ definition = delete_definition() })
    fill_delete_areas()
  end)
  if not ok then log('delete overlay error: ' .. tostring(err)) end
end

local function delete_selected_cards()
  if G.STATES and G.STATE == G.STATES.HAND_PLAYED then
    log('delete error: cards cannot be deleted while a hand is scoring')
    pcall(play_sound, 'cancel')
    return
  end

  local targets = {}
  for _, card in ipairs(delete_card_list()) do
    if SBX.delete_selected[card] then targets[#targets + 1] = card end
  end
  if #targets == 0 then
    log('no cards selected')
    pcall(play_sound, 'cancel')
    return
  end

  local deleted, failed, first_error = 0, 0, nil
  local jokers = SBX.delete_mode == 'jokers'
  for _, card in ipairs(targets) do
    local ok, reason = jokers and delete_joker_card(card) or delete_deck_card(card)
    if ok then
      deleted = deleted + 1
    else
      failed = failed + 1
      first_error = first_error or reason
    end
  end

  local what = jokers and 'jokers' or 'deck cards'
  if failed > 0 then
    log('deleted ' .. deleted .. ' selected ' .. what .. '; ' .. failed .. ' failed: ' .. tostring(first_error))
  else
    log('deleted ' .. deleted .. ' selected ' .. what)
  end
  pcall(play_sound, deleted > 0 and 'cardSlide2' or 'cancel')

  if G.E_MANAGER then
    G.E_MANAGER:add_event(Event({ trigger = 'immediate', func = function()
      open_delete_browser()
      return true
    end }))
  else
    open_delete_browser()
  end
end

G.FUNCS.sbx_open_delete = function() open_delete_browser() end
G.FUNCS.sbx_delete_commit = function() delete_selected_cards() end
G.FUNCS.sbx_delete_clear = function() clear_delete_selection() end
G.FUNCS.sbx_delete_mode_deck = function()
  if SBX.delete_mode == 'deck' then return end
  SBX.delete_mode = 'deck'
  open_delete_browser()
end
G.FUNCS.sbx_delete_mode_jokers = function()
  if SBX.delete_mode == 'jokers' then return end
  SBX.delete_mode = 'jokers'
  open_delete_browser()
end
