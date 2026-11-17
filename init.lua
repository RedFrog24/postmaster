-- postmaster/init.lua
-- Created by: RedFrog
-- Created: 2026-07-28
-- Courier of Favor quest assistant - Live only, House of Thule (Sunrise Hills neighborhood).
-- Reward: Featherweight Satchel of the Courier (20-slot, 100% WR) + Hyredel Swiftstride.
-- Prereqs: Postmaster's Challenge (18 deliveries) + The Nonad Brothers (+ Taxes #528).
-- Phase 2 (Nonad Brothers + Taxes) and Phase 3 (18 deliveries) complete. Phase 4 (Lysric turn-in) built.
-- Version controlled by `version` below (single source of truth - drives window title and console print).

local mq = require('mq')
local imgui = require('ImGui')

-- Launch args: /lua run postmaster [travel] - "travel" (or "go") auto-heads to Sunrise Hills.
local launchArgs = { ... }

-- Preflight (computed once - these do not change mid-session)
local version = "2.68"
local myName = mq.TLO.Me.Name() or "unknown"
local myRace = mq.TLO.Me.Race() or "Unknown"
local myServer = mq.TLO.EverQuest.Server() or "unknown"
local isEmu = (mq.TLO.MacroQuest.BuildName() or ""):lower() == "emu"

-- Per-character-per-server settings in their own subfolder (fleet pattern).
local configDir = mq.configDir .. '/postmaster'
local okLfs, lfs = pcall(require, 'lfs')
if okLfs then lfs.mkdir(configDir)
else os.execute(string.format('mkdir "%s"', configDir:gsub("/", "\\"))) end
local settingsFile = string.format("%s/postmaster_%s_%s.lua", configDir, myName, (myServer:gsub("[^%w]", "")):lower())

-- Classic evil races commonly KOS in this quest's good-aligned cities (Qeynos, Felwithe,
-- Kelethin, Erudin, Halas, dwarf/gnome cities). A caution, not a guarantee - faction varies.
local factionRisk = myRace == "Dark Elf" or myRace == "Troll" or myRace == "Ogre" or myRace == "Iksar"
-- AL (2026-08-08): above this level, guard aggro stops being a real problem - "50+ characters would
-- not even care IF they got attacked" (a survivability threshold, more confident than the separate
-- ~100 "guards don't even attack unless you walk up" aggro-behavior threshold AL wasn't fully sure of -
-- using the more conservative, more-confident number). Gates the invis/guard-avoidance system only -
-- NOT the movement pipeline, which is for everyone regardless of level (efficiency, not safety).
-- Different threshold from the separate, still-unbuilt "Level 15 or something" gnoll-danger disclaimer
-- ToDo (TRAVEL_REFERENCE.md Zone-Transit Hazards) - two different dangers, don't conflate the numbers.
-- ONE table for every tuned threshold in the script, gathered here from four places up to 2800 lines
-- apart. Two reasons, and the second is the one that matters day to day:
--   1. The main chunk sits on Lua's hard 200-local ceiling - a UI rewrite once failed to compile
--      outright with "too many local variables" - so five names folding into one buys back four slots.
--   2. THREE of these are still first guesses that have never been checked against field data. Having
--      them in one block means reading the current values, and changing them, is one place instead of
--      a treasure hunt. Record what each was tuned against, right here, when it finally is.
-- Same pattern as `items` / `aric` / `lysric` / `ui`. **Put new tuned numbers here, not loose.**
local tuning = {}

-- Below this level, a character is treated as at real risk from city guards. AL's own field data:
-- guards cap around 40-50, so above it the danger is near zero in a 130-level game. Gates the
-- invis/guard-avoidance system ONLY - NOT the movement pipeline, which is for everyone regardless of
-- level (efficiency, not safety). Different threshold again from the separate, still-unbuilt
-- "Level 15 or something" gnoll-danger disclaimer - two different dangers, don't conflate the numbers.
tuning.factionRiskLevel = 50

-- STARTING GUESS (AL, 2026-08-08), never yet tuned - "there are likely other places, Felwithe gate,
-- Kelethin Lift, etc." not tested. How far out to look for a hostile NPC before taking cover.
tuning.guardRadius = 200
-- AL, 2026-08-11: "if race is evil AND less than level 60 we will go get a Goblin Rogue Shroud... this
-- way we just do it from the start" - "due to City travel dangers." Deliberately a DIFFERENT (higher)
-- cutoff than tuning.factionRiskLevel above, not a typo - this supersedes the older reactive Invis
-- pipeline in practice for its whole target population (evil race, under this level) once live; that
-- pipeline isn't removed, it just stops being what actually fires for most characters that would have
-- used it.
tuning.shroudLevel = 60

-- STARTING GUESS, no field data on the ideal range yet. How close `/stick ... behind` is told to sit
-- when approaching a hostile NPC from behind.
tuning.stickDistance = 12

-- How far short of an NPC a walk stops (MQ2Nav's `distance=`, which also waits for line of sight to the
-- NPC before it counts as there). Without it nav aims for the very spot the NPC stands ON, and for a
-- merchant behind a counter or a bartender behind the bar that means walking into the woodwork and
-- grinding against it - going in, and again coming out (player report, 2026-09-25: Ton Firepride and
-- Tasya Huntlan in South Qeynos). 14 is what public scripts that hand items to NPCs already stop at -
-- lsgift walks up with `dist=14 los=on` and then opens the give window with `/click left target`,
-- exactly the give this script does - so it is inside hand-in range as well as /say range.
tuning.npcStop = 14

-- The MQ2AutoSize self size that gets a character cleanly over Ton Firepride's counter in South Qeynos,
-- which has little room above it. MEASURED at Ton (AL, 2026-09-25), two races:
--   Drakkin (natural size 6, 4.06 tall):  10 won't fit the shop door, 8 hits the ceiling on the counter,
--                                          5 sticks, 4 CLEAN (2.70 tall)
--   Vah Shir (natural size 7, 4.37 tall): natural gets a little stuck, 3 a little difficulty, 4 CLEAN
--                                          (2.49 tall)
-- Clean at 4 on both, and SMALLER was worse, not better - so v2.28 sets exactly this size for everyone
-- (AL: "size 4 for everyone") rather than v2.27's "2.70 or shorter", which left anyone already smaller
-- (AL's own everyday size 3) at the size that struggled. Height is linear in size per race, and two races
-- cannot yet say whether the size or the height is what counts; a gnome or an ogre at 4 would.
tuning.counterSize = 4

-- How long to keep waiting for health to come back before giving up and carrying on regardless.
tuning.healWaitMs = 180000

-- The 18 deliveries (pickup NPC/zone -> delivery NPC/zone). Data only; drives the checklist
-- now and the automation in Phase 3.
-- Fields: from/to = NPC names; fz/toZone = display zone labels; pz/toZoneShort = /travelto shortnames;
-- city = the keyword for "I will deliver to <city>".
-- NPCs, zones and pairings cross-verified against Paul Lynch's Courier of Favor guide (all correct).
-- REVAMP-SHORTNAME TRAP: public zone lists show CLASSIC shortnames; revamped ("2.0") zones retire the
-- classic name to a non-routable ghost, so use the LIVE variant: Freeport = freeportwest/freeporteast
-- (NOT freportw/freporte); Innothule = innothuleb (NOT innothule). STILL TO CONFIRM: Nektulos (#12) -
-- it was revamped, so `nektulos` may be a ghost; the live name is likely `nektulosa`. When a /travelto
-- returns "Not Found", suspect a revamp variant FIRST before any routing/mesh theory.
-- itemId = the exact item id this delivery's letter/pouch carries once picked up (field-confirmed via
-- the TEMPORARY known_item_ids_TEMP.lua data-gathering aid, all 18 filled 2026-08-10 - see CHANGELOG).
-- Not consulted by pickupOnly (it captures the live Cursor.ID() at the moment of pickup, unambiguous
-- either way) - kept here as confirmed reference data, same role as the zone shortnames above.
-- There is deliberately NO `kos` field. v1.42 and earlier flagged senders confirmed hostile to a
-- bad-faction character; v1.43 replaced that with a LIVE /consider check on every approach
-- (approachAndInteract), because the static flag gave zero protection to anyone who simply had not been
-- flagged yet - Marton in Halas was never confirmed hostile, but he had never been confirmed SAFE
-- either. A single stale `kos = true` survived on Ticar's row until v2.19 as "historical data"; it was
-- read by nothing, so it was just a lie waiting to mislead the next reader. Removed.
local DELIVERIES = {
    { from = "Ticar Lorestring",    fromZone = "Erudin",        fromZoneShort = "erudnext",   city = "Qeynos",    to = "Tralyn Marsinger",    toZone = "S.Qeynos",   toZoneShort = "qeynos",      itemId = 18151 },
    { from = "Marton Stringsinger", fromZone = "Halas",         fromZoneShort = "halas",      city = "Qeynos",    to = "Tralyn Marsinger",    toZone = "S.Qeynos",   toZoneShort = "qeynos",      itemId = 18150 },
    { from = "Lislia Goldtune",     fromZone = "High Keep",     fromZoneShort = "highkeep",   city = "Qeynos",    to = "Eve Marsinger",       toZone = "S.Qeynos",   toZoneShort = "qeynos",      itemId = 18165 },
    { from = "Sivina Lutewhisper",  fromZone = "Surefall Glade",fromZoneShort = "qrg",        city = "Qeynos",    to = "Tralyn Marsinger",    toZone = "S.Qeynos",   toZoneShort = "qeynos",      itemId = 18154 },
    { from = "Mistrana Two Notes",  fromZone = "West Karana",   fromZoneShort = "qey2hh1",    city = "Qeynos",    to = "Tralyn Marsinger",    toZone = "S.Qeynos",   toZoneShort = "qeynos",      itemId = 18153 },
    { from = "Ton Twostring",       fromZone = "E.Freeport",    fromZoneShort = "freeporteast",   city = "Highpass",  to = "Lislia Goldtune",     toZone = "High Keep",  toZoneShort = "highkeep",    itemId = 18156 },
    { from = "Eve Marsinger",       fromZone = "S.Qeynos",      fromZoneShort = "qeynos",     city = "Highpass",  to = "Lislia Goldtune",     toZone = "High Keep",  toZoneShort = "highkeep",    itemId = 18152 },
    { from = "Drizda Tunesinger",   fromZone = "Feerrott",      fromZoneShort = "feerrott",   city = "Freeport",  to = "Felisity Starbright", toZone = "E.Freeport", toZoneShort = "freeporteast", itemId = 18158 },
    { from = "Lislia Goldtune",     fromZone = "High Keep",     fromZoneShort = "highkeep",   city = "Freeport",  to = "Ton Twostring",       toZone = "E.Freeport", toZoneShort = "freeporteast", itemId = 18166 },
    { from = "Dark Deathsinger",    fromZone = "Innothule",     fromZoneShort = "innothuleb", city = "Freeport",  to = "Felisity Starbright", toZone = "E.Freeport", toZoneShort = "freeporteast", itemId = 18157 },
    { from = "Idia",                fromZone = "Kelethin",      fromZoneShort = "gfaydark",   city = "Freeport",  to = "Felisity Starbright", toZone = "E.Freeport", toZoneShort = "freeporteast", itemId = 18164 },
    { from = "Travis Two Tone",     fromZone = "Nektulos",      fromZoneShort = "nektulos",   city = "Freeport",  to = "Felisity Starbright", toZone = "E.Freeport", toZoneShort = "freeporteast", itemId = 18155 },
    { from = "Silna Songsmith",     fromZone = "Rivervale",     fromZoneShort = "rivervale",  city = "Freeport",  to = "Felisity Starbright", toZone = "E.Freeport", toZoneShort = "freeporteast", itemId = 18159 },
    { from = "Lyra Lyrestringer",   fromZone = "Ak'Anon",       fromZoneShort = "akanon",     city = "Kelethin",  to = "Jakum Webdancer",     toZone = "Kelethin",   toZoneShort = "gfaydark",    itemId = 18160 },
    { from = "Siltria Marwind",     fromZone = "Butcherblock",  fromZoneShort = "butcher",    city = "Kelethin",  to = "Jakum Webdancer",     toZone = "Kelethin",   toZoneShort = "gfaydark",    itemId = 18162 },
    { from = "Tacar Tissleplay",    fromZone = "N.Felwithe",    fromZoneShort = "felwithea",  city = "Kelethin",  to = "Jakum Webdancer",     toZone = "Kelethin",   toZoneShort = "gfaydark",    itemId = 18163 },
    { from = "Ton Twostring",       fromZone = "E.Freeport",    fromZoneShort = "freeporteast",   city = "Kelethin",  to = "Idia",                toZone = "Kelethin",   toZoneShort = "gfaydark",    itemId = 18167 },
    { from = "Kilam Oresinger",     fromZone = "S.Kaladim",     fromZoneShort = "kaladima",   city = "Kelethin",  to = "Jakum Webdancer",     toZone = "Kelethin",   toZoneShort = "gfaydark",    itemId = 18161 },
}

-- Runtime state
local running = true
local hidden = false      -- /postmaster hides/shows the window; the X button stops the script
local bagLocation = nil   -- "inventory" | "bank" | nil, refreshed by poll()
local traveling = false
local travelRequested = false
local nonadBusy = false
local nonadRequested = false
local vicusBoxRequested = false   -- "Go to Vicus" manual shortcut - AL, 2026-08-14: deleted the box+list
                                   -- to re-test the flow and had no way to just re-request them without
                                   -- restarting the whole chain from Pagus for a new tonic
local pmBusy = false
local pmRequested = false
local pmSpaceNeeded = nil   -- {need=N, free=M} when a batch is blocked on inventory space; else nil
local syncHeldIdx = nil     -- delivery index the "Sync held" button requested, or nil
local lysricBusy = false
-- Declared up here, not down with the rest of the UI, because runLysricStep is defined ABOVE that
-- point and needs to record its outcome for the Final Hail panel to display.
local ui = {}
ui.lysricMsg = nil          -- last Lysric outcome, shown inline in the panel
ui.sharedSatchels = 0       -- satchels in the account-wide SHARED bank (poll); may be another character's
ui.lysricMsgCol = nil
ui.sayQueue = {}            -- FIFO of {text, xml}; drained by the main loop, paced so lines cannot
ui.sayNextAt = 0            -- cut each other off (SPF_PURGEBEFORESPEAK - see TTS_REFERENCE.md)
ui.lastTaxActive = nil      -- accordion transition flag for the tax-merchant list. nil on purpose: the
                             -- first frame then always counts as a transition, which sets the correct
                             -- initial open/closed state instead of leaving it to chance.
local lysricRequested = false
local lastShroudedState = nil   -- tracks Me.Shrouded() across polls - AL, 2026-08-11: shroud/unshroud
                                 -- clears both EQ and MQ chat, leaving no visible confirmation either
                                 -- direction; the main loop prints one when this flips, whether the
                                 -- script or the user caused it (manual shroud/unshroud included).
local justFledCombat = false    -- set by fleeIfInCombat(), checked/cleared by retryStep() - AL,
                                 -- 2026-08-11: an automatic retry ran straight back at an already-
                                 -- hostile, already-attacking Ticar right after fleeing, circling him
                                 -- while getting hit. Retrying "approach the KOS NPC" makes no sense
                                 -- immediately after fleeing that exact NPC's aggro.
local radiusWatchZoneId = nil      -- radiusWatch's last-seen Zone.ID(), to detect a real zone-line
                                    -- transition (v1.47 - see radiusWatch's own comment)
local radiusWatchLatched = false   -- true once a hostile NPC has been found in the CURRENT zone - once
                                    -- true, stays Sneak+Hidden with no more considering until the next
                                    -- real zone change resets it
local radiusWatchConsidered = {}   -- spawn ids already /consider-ed this zone, keyed by id - avoids
                                    -- re-checking a still-nearby NPC that already read safe every poll
local radiusWatchKnownHostileZones = {}   -- zone ids that have read hostile at least once THIS SCRIPT
                                           -- RUN, keyed by zone id (v1.49) - in-memory only, never
                                           -- persisted to disk (a stale saved flag would be exactly the
                                           -- kind of unverified assumption this project avoids - faction
                                           -- can genuinely change mid-run via the Faction-Fix Helper).
                                           -- Re-entering a known-hostile zone re-latches immediately, no
                                           -- exposed scan-first gap - see radiusWatch's own comment.
local reachedNeighborhoodOnce = false   -- sticky: once true, Travel stops re-claiming the accordion
                                         -- even if a later automated run briefly leaves the zone
local lastActiveSection = nil           -- last computed accordion "active" section, for transition detection

-- Persisted progress
local state = {
    postmasterDone = false,
    nonadDone = false,
    lysricDone = false,  -- Featherweight Satchel confirmed received from Lysric (the final reward)
    challengeStarted = false,   -- accepted the challenge from Aric (Postmaster's Challenge started)
    pmFullAuto = false,  -- off = one cluster per click (checkpoint, the default); on = chain all
                          -- remaining clusters (and on into Finish at Aric) until done or a real failure
    deliveries = {},
    held = {},                  -- [deliveryIdx] = parcel name currently carried (verified vs inventory)
    taxes = {},          -- [merchantName] = true once their tax is collected + boxed
    taxesInVicus = false,-- Full box handed to Vicus; only the Pagus report remains
    factionAck = false,
    neighborhood = "Alliance of the Forsaken Village",   -- typed into the Guild Lobby gate's search. The
                                 -- public neighborhood on every server - by its FULL name (v2.31, AL).
                                 -- The default was the bare word "Alliance" until then, and a search for
                                 -- that also returns guild and player neighborhoods with it in their name:
                                 -- travel took row 1 and could land in somebody's personal neighborhood.
    theme = "Ledger",   -- key into ui.THEMES. Chooses BOTH the palette and whether the artwork draws
                         -- at all: a theme without `art` is a plain, wordmark-only look.
    soundOn = true,      -- WAV chimes on milestones (played with /beep, Windows PlaySound)
    ttsOn = false,       -- speak milestones via MQTextToSpeech; off by default, it is intrusive
    ttsVoice = "",       -- last voice set from the picker, purely informational
    fitCounters = true,  -- "Fit through counters": shrink via MQ2AutoSize while running (see `fit`). ON by
                          -- default (v2.27, AL) so every player gets it; untickable in Settings.
    autosizeRestore = {},-- the player's own AutoSize settings while we have them changed; empty = nothing
                          -- to put back. On DISK on purpose - see fit.apply.
    factionGoal = "Apprehensive",   -- Faction tab: the Reaction a helper quest stops at (v2.29). The
                                    -- default is what Vicus Nonad needs before he will talk.
    factionGoals = {},   -- v2.58: one Stop at per helper, by key (AL's decision 2 - Apprehensive for Antonius
                          -- Bayle, Ally for the bards). A helper with no entry uses its own `goal`, and Bone Chips
                          -- falls back to factionGoal above, so an older save keeps the goal it had.
    autoShroud = false,  -- Shroud Strategy (v1.25): a Dark Elf, Troll, Ogre or Iksar under tuning.shroudLevel
                          -- takes a Goblin Rogue shroud before the courier and Nonad runs. OFF by default since
                          -- v2.46 (AL: *"we will tackle it in our true form until I see no way around it"*) - the
                          -- Faction tab can now fix a character's faction, and a shroud blanks the Faction window
                          -- until a camp. Untickable in Settings. The Faction tab's hidden give shrouds anyway.
}

-- The default neighborhood, captured from the table above BEFORE loadState can overwrite it - so the
-- Reset button (v2.30) and the empty-field fallback below both use the one value, and cannot drift.
ui.defaultNeighborhood = state.neighborhood

-- Persistence

local function loadState()
    local f = io.open(settingsFile, "r")
    if f then
        f:close()
        local saved = mq.unpickle(settingsFile, {}) or {}
        -- GENERIC restore, not a field-by-field whitelist. saveState() pickles the WHOLE state table,
        -- so everything was always being written correctly - but the loader listed each key by hand,
        -- and by v2.02 it had silently dropped FOUR settings that nobody remembered to add to it:
        -- theme, soundOn, ttsOn and ttsVoice. Each saved fine and was simply never read back, so the
        -- symptom was "my setting resets every time I restart" with nothing wrong at the save end.
        -- Adding a setting must not mean remembering to edit a second place; now it doesn't.
        -- Two guards keep this as safe as the whitelist was:
        --   state[k] ~= nil  - only KNOWN keys are accepted, so a stale key left in an old save file
        --                      by a removed feature is ignored rather than resurrected.
        --   type match       - a corrupted or hand-edited file cannot poison a boolean with a string
        --                      or a table with a number.
        -- A key absent from the file simply keeps its default, which is what the old `or false` did.
        for k, v in pairs(saved) do
            if state[k] ~= nil and type(v) == type(state[k]) then state[k] = v end
        end
        -- Lua treats "" as truthy, so an explicitly-saved empty neighborhood survives the merge and
        -- has to be caught here - old saves without one still want the default.
        if state.neighborhood == nil or state.neighborhood == "" then state.neighborhood = ui.defaultNeighborhood end
        -- v2.31: the bare "Alliance" was the OLD default, and it is the setting that landed players in the
        -- wrong neighborhood (see the default above). Nearly every save file holds it, because the whole
        -- state is saved whenever anything changes - so upgrade it rather than leave the bug in place.
        if state.neighborhood == "Alliance" then state.neighborhood = ui.defaultNeighborhood end
        -- A theme that no longer exists (renamed, or hand-edited) falls back rather than leaving the
        -- Settings combo displaying a name nothing matches. croakwatch validates its saved theme the
        -- same way: `if saved.theme and THEMES[saved.theme]`.
        if not ui.THEMES[state.theme] then state.theme = "Ledger" end
    end
    for i = 1, #DELIVERIES do
        if state.deliveries[i] == nil then state.deliveries[i] = false end
    end
end

local function saveState()
    mq.pickle(settingsFile, state)
end

-- Detection

-- How many of an item there are, and where: carried, in THIS character's bank, and in the SHARED bank.
-- v2.29 fix: the shared bank belongs to the whole ACCOUNT, so an item there may be another character's -
-- AL's InvSlot Inspector showed a Featherweight Satchel in Genali's shared bank that Genali never earned,
-- and our own tip tells players to bank one there. FindItemBank and FindItemBankCount both search the
-- shared bank as well (MQ's CountBankItems walks BankItems then SharedBankItems), so neither can answer
-- "does THIS character have one" - and both quest rewards were being judged that way. Me.SharedBank[n]
-- reads the shared slots on their own, bag contents included; the personal bank is whatever the bank count
-- finds beyond them.
local function countsOf(name)
    local shared = 0
    for n = 1, 10 do   -- past the account's real shared slots, SharedBank returns an empty item
        local slot = mq.TLO.Me.SharedBank(n)
        if slot.Name() == name then shared = shared + 1 end
        for k = 1, (slot.Container() or 0) do
            if slot.Item(k).Name() == name then shared = shared + 1 end
        end
    end
    local banked = (mq.TLO.FindItemBankCount("=" .. name)() or 0) - shared
    return mq.TLO.FindItemCount("=" .. name)() or 0, math.max(banked, 0), shared
end

-- The satchel is Lore + Heirloom: a second can be obtained once the first is banked. bagLocation is THIS
-- character's (carried or personal bank); ui.sharedSatchels is the account's, shown for information only.
local function poll()
    local carried, banked, shared = countsOf("Featherweight Satchel of the Courier")
    bagLocation = (carried > 0 and "inventory") or (banked > 0 and "bank") or nil
    ui.sharedSatchels = shared
end

local function deliveredCount()
    local n = 0
    for i = 1, #DELIVERIES do
        if state.deliveries[i] then n = n + 1 end
    end
    return n
end

-- Travel seam: get to Sunrise Hills (any neighborhood works). Reuses AL's guildhall.lua
-- lobby->neighborhood sequence, with timeouts/bail on every wait. Run from the main loop
-- ONLY (uses mq.delay - never call from the render thread).

-- Every fixed zone and switch id the travel code keys on, in one table: five names, one local slot.
--
-- POSITION IS LOAD-BEARING - this table must stay declared up here, above travelToSunriseHills. The
-- PoK shortname once lived down with the travel helpers, and because travelToSunriseHills is defined
-- long before that point, its reference resolved to a nil GLOBAL - and `zone ~= nil` is always true,
-- which silently disabled an "am I already in PoK?" guard. Caught by luacheck as an undefined variable,
-- which is precisely the class it exists to catch.
local zones = {
    gateSwitch   = 38,              -- the Guild Lobby's neighborhood gate (a door/switch id)
    guildLobby   = 344,
    neighborhood = 712,             -- shared by EVERY housing neighborhood - anchor on NPCs, not this
    pokShort     = "poknowledge",   -- PoK shortname (matches AL's pppoker)
    -- `Me.ZoneBound.ID() == 202` is how a PoK bind is confirmed - the value is taken from pppoker's
    -- own field-verified config, not guessed.
    pokId        = 202,
}

-- Is the character bound somewhere Gate is actually useful? Gate AA, the Gate spell, the Philter and the
-- Vial all land at the BIND, so they only help when the bind is one of the two travel hubs. PoK has the
-- books to every city; the Guild Lobby is where Sunrise Hills is reached from, one short hop from PoK.
-- Read LIVE every time, never remembered: a player can rebind between runs, and a saved "yes" would
-- quietly send Gate somewhere else.
function zones.boundAtHub()
    local id = mq.TLO.Me.ZoneBound.ID() or 0
    return id == zones.pokId or id == zones.guildLobby
end

-- Standing in a hub where nothing can attack you? MQ has no native "safe/no-combat zone" flag (AL,
-- 2026-08-11, confirmed - not guessed), so it is these three. AL: shrouding happens in PoK, and engaging
-- Sneak immediately afterward meant walking the whole PoK/Guild-Lobby hub portion of travel at Sneak's
-- reduced speed for zero safety benefit, since those zones are never dangerous.
-- v2.32: moved up here from near ensureHealed (it was `inSafeHubZone`) so navToNpc's guard watch, which
-- sits far above that point, can use it too - a Lua local is invisible above its own declaration.
function zones.inSafeHub()
    local zid = mq.TLO.Zone.ID() or 0
    return (mq.TLO.Zone.ShortName() or "") == zones.pokShort or zid == zones.guildLobby or zid == zones.neighborhood
end

-- Death check shared by both wait helpers below (AL, 2026-08-11: died mid-travel twice in one session -
-- once the script kept blindly continuing toward a stale destination after a manual respawn, once a wait
-- just sat out its full timeout instead of noticing death immediately). Me.Hovering() is true only while
-- the respawn window is open - that is the whole of the death test, and it is instant - bailing here means
-- every travel/nav wait in the script stops fast and honestly instead of continuing to poll uselessly
-- (nothing can move while dead) or blaming a generic "stuck"/timeout when the real cause was death.
local function diedWhileWaiting()
    if mq.TLO.Me.Hovering() then
        print('\ar[Postmaster]\ax you died - stopping this step. Respawn, then run again.')
        return true
    end
    return false
end

local ensureHealed   -- defined near considerNpc (needs waitUntil) - forward-declared here (not just at
                      -- the usual ensure* block further down) so waitWhileProgressing below can call it
                      -- on every poll, not just once at the top of a travel call. AL, 2026-08-11: arrived
                      -- in PoK at 2% HP mid-multi-hop-journey with no heal check, because the old
                      -- single-shot call only fires once at the very start of travelToZone - a route that
                      -- happens to pass BACK through PoK partway through (the Halas fallback-via-PoK case)
                      -- never got a second chance. "PoK should be an always hp check."

local fleeIfInCombat   -- defined near considerNpc (needs zones.pokShort, justFledCombat) - forward-declared
                        -- here so waitUntil/waitWhileProgressing below can check it on EVERY poll, not
                        -- just at the few explicit checkpoints inside approachAndInteract's retry loop.
                        -- AL, 2026-08-13: a shrouded character walking through Erudin (ordinary travel,
                        -- not the approach-a-KOS-NPC sequence at all) got attacked by zone guards with
                        -- zero combat awareness anywhere in the travel/nav code path, and died before
                        -- ever reaching the point where approachAndInteract's own checks would have run.
                        -- Sneak alone was never a guarantee - this is the missing "if it's actually
                        -- happening, bail now" safety net for the whole travel engine, not just the
                        -- narrow approach-and-interact window.
local approachAndInteract   -- defined after radiusWatch/stickBehind - forward-declared so the Nonad and Taxes
                             -- steps above it can use it too (v2.51: in invis, every NPC is dealt with from
                             -- behind - AL; they used to walk up to the front and speak).
local radiusWatch   -- defined near considerNpc/reactionIsSafe (needs considerSpawnId, reactionIsSafe,
                     -- tuning.guardRadius) - forward-declared here so waitUntil/waitWhileProgressing
                     -- below can call it on EVERY poll, same shape as fleeIfInCombat/ensureHealed. AL,
                     -- 2026-08-14: Sneak's movement-speed penalty during ordinary travel was itself the
                     -- danger (field death on v1.46, Tox Forest guards) - "guards kill me because we are
                     -- sneak (super slow walk)". Full speed until the first confirmed hostile NPC in a
                     -- zone, then latch Sneak+Hide for the rest of that zone, no more re-checking. See
                     -- POSTMASTER_PIPELINE.md "Radius Watch pipeline". navToNpc's own travel wait is a
                     -- plain waitUntil (not waitWhileProgressing), and it's exactly the last-mile leg
                     -- where a guard is encountered - both primitives need this, same reasoning as
                     -- fleeIfInCombat above.

-- Run / Pause / Stop for automated runs (v2.29 - the Faction tab's helper quests are the first to use
-- them). Both wait primitives below check these on EVERY poll, in the same place they already check
-- `running` for the X button, so a click lands within one poll wherever the run happens to be.
--   stop   - ends the run the way X does, but leaves the script open. Silent: the user asked for it.
--   paused - holds the run where it stands until Continue. Paused time is not counted against any wait,
--            and waitWhileProgressing restarts its stuck clock afterwards - otherwise a long pause reads as
--            "no progress" and the run gives up the moment the user comes back.
-- DECLARED ABOVE the wait primitives on purpose: they use it, and a local is only visible below its own
-- declaration.
local automation = { stop = false, paused = false,
    -- v2.38: hold off the automatic shroud. Every travel leg calls ensureShroud, which is right for the
    -- courier run but wrong while the Faction tab is buying and banking as the character's NORMAL self -
    -- a shroud cannot reach its own money or bags, so it must come AFTER those steps, not before.
    noShroud = false,
    -- v2.50, the flee that carries on (AL): the zone we are in and the one we came from (kept by Radius Watch),
    -- the zone a flee left, and the NPC the last walk was heading for (a repeat fight is judged by it).
    zoneNow = nil, zoneFrom = nil, fledFrom = nil, lastNpc = nil,
    -- v2.51: an NPC interaction is under way - Radius Watch must not put invis back on in the middle of it.
    interacting = false }

function automation.hold()
    while automation.paused and running and not automation.stop do
        ui.drainSpeech()
        mq.delay(200)
    end
end

-- Diagnostic output, off by default, toggled with `/postmaster debug`. Croakwatch's pattern
-- (`cwDebug` + `/croakwatch debug`).
--
-- WHAT BELONGS HERE: internal measurements and step-by-step narration that only matter when something
-- has gone wrong - distances, attempt counters, "trying X instead" routing chatter. These earned their
-- keep while the script was being built (v2.06, v2.09 and v2.11 were all root-caused from console logs
-- AL pasted back) but they are noise to somebody who just wants their bag.
--
-- WHAT DOES NOT: anything the user must act on, and one line per real milestone. Those stay visible.
-- Also kept: anything that explains a VISIBLE PAUSE or a visible change in behaviour (meditating for
-- mana, healing, dropping to a Sneak crawl). A silent stall reads as a hang and costs a support
-- question, which is worse than the one line it would have taken to explain it.
--
-- THE RULE THAT DECIDES THE REST - do not narrate what a plugin already narrates. EasyFind and Nav
-- announce their own progress, so a matching line from us is pure duplication. The exception is when
-- the plugin's version is OPAQUE: "[Nav] Navigating to switch: OBJ_IRONGATESWITCH" means nothing to a
-- player, so ours is the line worth keeping and theirs is the one worth squelching.
--
-- DELIBERATELY DEFINED HERE, above the two wait primitives, and that position is load-bearing: the
-- stuck-detection message inside waitWhileProgressing needs it, and a local is only in scope AFTER its
-- declaration. Declared below them, `dbg` there would silently resolve to a nil global - `luac -p`
-- accepts that, and it would crash only when a route actually stalls, which can be an hour into a run.
local pmDebug = false
local function dbg(msg)
    if pmDebug and running then print('\ao[Postmaster debug]\ax ' .. msg) end
end

local function waitUntil(cond, timeoutMs, stepMs)
    stepMs = stepMs or 200
    local elapsed = 0
    local fledAtStart = justFledCombat   -- a wait that is PART of a retreat's recovery must not end on it
    while elapsed < timeoutMs do
        if not running then return false end   -- user closed the script mid-wait: abort long travels
        if automation.paused then automation.hold() end
        if automation.stop then return false end
        if diedWhileWaiting() then return false end
        ui.drainSpeech()
        if mq.TLO.Me.Shrouded() then
            if fleeIfInCombat() then return false end
            radiusWatch()
            -- v2.55: Radius Watch can start a retreat itself (invis would not go on) - end the wait, as a flee does.
            if justFledCombat and not fledAtStart then return false end
        end
        if cond() then return true end
        mq.delay(stepMs)
        elapsed = elapsed + stepMs
    end
    return false
end

-- Like waitUntil, but instead of a single fixed timeout, tracks whether the character is actually
-- making progress (position changing meaningfully) and gives up EARLY the moment it detects a genuine
-- stall - instead of always sitting through a fixed ceiling regardless of whether the route is
-- slow-but-working or truly stuck. This is the recurring "60s-timeout trap" bug class (West Karana,
-- Kelethin CALL-nav, Guild Lobby, the Halas PoK-wait all hit variations of it) solved properly instead
-- of just raising the number again every time it recurs. Adapted from Lisie's epiclaziness travel-loop
-- pattern (epiclaziness/utils/travel.lua travelLoop) - periodically compares current position against
-- a reference point updated only on meaningful movement, not her separate Navigation.Velocity()
-- sampling (that turned out to be a secondary diagnostic, not the actual stuck check).
-- stuckAfterMs: how long with NO meaningful movement before giving up early. ceilingMs: true worst-case
-- safety net in case movement detection itself misbehaves.
local function waitWhileProgressing(cond, stuckAfterMs, ceilingMs, stepMs)
    stepMs = stepMs or 500
    local lastX, lastY, lastZ = mq.TLO.Me.X() or 0, mq.TLO.Me.Y() or 0, mq.TLO.Me.Z() or 0
    local lastProgressTime = mq.gettime()
    local elapsed = 0
    local fledAtStart = justFledCombat   -- a wait that is PART of a retreat's recovery must not end on it
    while elapsed < ceilingMs do
        if not running then return false end
        if automation.paused then
            automation.hold()
            lastX, lastY, lastZ = mq.TLO.Me.X() or 0, mq.TLO.Me.Y() or 0, mq.TLO.Me.Z() or 0
            lastProgressTime = mq.gettime()
        end
        if automation.stop then return false end
        if diedWhileWaiting() then return false end
        ui.drainSpeech()
        if mq.TLO.Me.Shrouded() then
            if fleeIfInCombat() then return false end
            local watchStart = mq.gettime()
            radiusWatch()
            -- v2.55: Radius Watch can start a retreat itself (invis would not go on) - end the wait, as a flee does.
            if justFledCombat and not fledAtStart then return false end
            -- ...and standing still to hide is not a stall: restart the no-progress clock after a long stop.
            if mq.gettime() - watchStart > 1000 then
                lastX, lastY, lastZ = mq.TLO.Me.X() or 0, mq.TLO.Me.Y() or 0, mq.TLO.Me.Z() or 0
                lastProgressTime = mq.gettime()
            end
        end
        if cond() then return true end
        -- Heal-in-PoK check on every poll, not just once at the top of a travel call (AL, 2026-08-11) -
        -- a route that happens to pass back through a safe hub zone partway through a multi-hop journey
        -- (e.g. the Halas fallback-via-PoK case) now gets a real chance to catch it. Resets the stuck-
        -- detection's progress timer when it actually pauses to heal - otherwise a multi-minute heal
        -- would immediately look like a navigation stall the moment this loop resumes.
        if ensureHealed() then
            lastX, lastY, lastZ = mq.TLO.Me.X() or 0, mq.TLO.Me.Y() or 0, mq.TLO.Me.Z() or 0
            lastProgressTime = mq.gettime()
        end
        local x, y, z = mq.TLO.Me.X() or 0, mq.TLO.Me.Y() or 0, mq.TLO.Me.Z() or 0
        local moved = math.sqrt((x - lastX) * (x - lastX) + (y - lastY) * (y - lastY) + (z - lastZ) * (z - lastZ))
        if moved > 15 then
            lastX, lastY, lastZ = x, y, z
            lastProgressTime = mq.gettime()
        elseif mq.gettime() - lastProgressTime > stuckAfterMs then
            dbg(string.format('no progress for %ds - looks stuck, not just slow.', math.floor(stuckAfterMs / 1000)))
            return false
        end
        mq.delay(stepMs)
        elapsed = elapsed + stepMs
    end
    return false
end

-- "Fit through counters" (v2.26, AL's idea) - MQ2AutoSize sets the character to the size that gets over
-- Ton Firepride's counter cleanly (the measurements are on tuning.counterSize). ON by default, untickable
-- in Settings (v2.27). A fixed size for everyone since v2.28.
--
-- v2.27, AL: load the plugin ourselves when the player doesn't run it, and unload it at the end ONLY if we
-- were the ones who loaded it - otherwise most players would never get the fix. A player who already runs
-- AutoSize gets their own settings back at the end, not a reset (AL's choice: "their own settings back").
-- `noauto` on the load, so MacroQuest.ini never learns about it and it does not follow them to other
-- characters. This is a deliberate exception to the studio rule of never unloading at exit - safe here
-- because we only ever unload what we loaded ourselves.
--
-- WHY THE ORIGINALS ARE SAVED TO DISK, NOT JUST HELD IN A VARIABLE: with AutoSave on, every /autosize
-- change is written to the plugin's own INI at once. A /lua stop kills this script without reaching the
-- restore after the main loop, so a memory-only copy would leave the player's SAVED size shrunk for good -
-- and the next run would then capture that shrunk size as "their" setting and never undo it. Saved here
-- before anything changes, the originals survive a stop or a crash and are put back at the next start.
--
-- Driven from the main loop through fit.request, never from the Settings checkbox itself: apply waits for
-- the resize to land, and nothing may wait inside the render thread.
local fit = { request = nil }

-- Makes sure MQ2AutoSize is loaded. Returns (loaded, loadedByThisCall). The root plugin pattern: `load`,
-- never a bare `/plugin` (that toggles, and would UNLOAD a loaded one); `noauto`; verify after, and say
-- which feature is off if it will not load (the DLL may simply not be there). mq.delay rather than
-- waitUntil because the end-of-script restore runs after `running` has gone false, and waitUntil gives
-- up at once when it has.
function fit.load()
    if mq.TLO.Plugin('MQ2AutoSize').IsLoaded() then return true, false end
    mq.cmd('/squelch /plugin mq2autosize load noauto')
    mq.delay(5000, function() return mq.TLO.Plugin('MQ2AutoSize').IsLoaded() == true end)
    if not mq.TLO.Plugin('MQ2AutoSize').IsLoaded() then
        print('\ay[Postmaster]\ax could not load MQ2AutoSize - Fit through counters is off. If you snag on a '
            .. 'counter, the stuck-nudge still works.')
        return false, false
    end
    return true, true
end

-- Loads the plugin if it has to, because a record on disk can outlive the plugin: /lua stop or a crash,
-- then EQ restarted, and a plugin we loaded with `noauto` is gone - yet its INI still holds OUR size.
-- Loading it just to write the player's values back is the only way to repair that.
function fit.restore()
    local s = state.autosizeRestore
    if not s.size then return end
    local ok, loadedNow = fit.load()
    if not ok then return end   -- keep the record; the next start tries again
    if s.size >= 1 then mq.cmdf('/squelch /autosize sizeself %d', s.size) end
    if not s.self then mq.cmd('/squelch /autosize self off') end
    if not s.enabled then mq.cmd('/squelch /autosize off') end
    if s.weLoaded or loadedNow then mq.cmd('/squelch /plugin mq2autosize unload') end
    state.autosizeRestore = {}
    saveState()
    print('\ag[Postmaster]\ax your character size is back as it was.')
end

function fit.apply()
    if state.autosizeRestore.size then return end   -- already applied
    local ok, loadedNow = fit.load()
    if not ok then return end
    local a = mq.TLO.AutoSize
    -- Already exactly where we would put them (a player's own AutoSize at this size): nothing to change,
    -- and nothing to undo. Only when THEY had it loaded - if we just loaded it, the record below is what
    -- makes the end-of-run unload happen, so it must be written even if the size already matches.
    if not loadedNow and a.Enabled() and a.ResizeSelf() and (a.SizeSelf() or 0) == tuning.counterSize then
        dbg(string.format('already at AutoSize size %d - nothing to change.', tuning.counterSize))
        return
    end
    state.autosizeRestore = { enabled = a.Enabled() == true, self = a.ResizeSelf() == true,
        size = a.SizeSelf() or 0, weLoaded = loadedNow }
    saveState()
    -- Explicit on/off forms (MQ docs: `/autosize [on|off]`, `/autosize self [on|off]`), never the bare
    -- toggles - a toggle sent against the wrong starting state would do the opposite of what we meant.
    if not state.autosizeRestore.enabled then mq.cmd('/squelch /autosize on') end
    if not state.autosizeRestore.self then mq.cmd('/squelch /autosize self on') end
    local before = mq.TLO.Me.Height() or 0
    mq.cmdf('/squelch /autosize sizeself %d', tuning.counterSize)
    if not waitUntil(function() return (mq.TLO.AutoSize.SizeSelf() or 0) == tuning.counterSize end, 3000, 100) then
        print('\ay[Postmaster]\ax Fit through counters could not set your size - putting your AutoSize settings back.')
        fit.restore()
        return
    end
    -- The setting reads back at once; the model catches up a moment later. Wait briefly for the height to
    -- move so the line below reports the real result (it will not move if they were already this size).
    waitUntil(function() return math.abs((mq.TLO.Me.Height() or 0) - before) > 0.01 end, 1500, 100)
    print(string.format('\ay[Postmaster]\ax Fit through counters: set you to size %d (%.2f tall) so you fit over '
        .. 'shop counters. Your normal size comes back when Postmaster closes.', tuning.counterSize, mq.TLO.Me.Height() or 0))
end

-- Skips a failure print if the true cause was the user closing the script (running went false) mid-wait,
-- not a genuine timeout - waitUntil/waitWhileProgressing return the same plain `false` either way, so
-- without this every wait-timeout message looks like a real problem even when the script is just
-- shutting down (SCRIPT_SELFCHECK category 4: abort paths that lie). Scoped to the travel/nav engine's
-- direct wait-timeout prints only, where the user is most likely to be waiting mid-run - the return value
-- (and whatever it unwinds into) still happens either way, this only silences the misleading console line.
local function printIfRunning(msg)
    if running and not automation.stop then print(msg) end   -- a Stop click is the same case as X
end

-- A clickable EQ item link for console output - the purple links you can click to open the real item
-- window - instead of a bare name in text. Pattern confirmed in croakwatch (`ItemLink('CLICKABLE')`,
-- the BigBag approach); printing that string is what EQ's chat renders as a link.
--
-- Falls back to the plain name whenever the item cannot be found, which is a REAL case here and not
-- just defensiveness: FindItem does not see an item still sitting on the cursor, and several of these
-- messages fire exactly when stowing has failed. A plain name is a fine degrade; a nil is not.
local function itemLink(name)
    local it = mq.TLO.FindItem("=" .. name)
    if it() == nil then it = mq.TLO.FindItemBank("=" .. name) end
    if it() == nil then return name end
    return it.ItemLink('CLICKABLE')() or name
end

local function lysricNear()
    return (mq.TLO.Spawn("npc Lysric Loresinger").ID() or 0) > 0
end

-- Forward declarations: travelToSunriseHills (below) auto-continues into these once in-zone, but
-- both are defined later in the file (Phase 3/4 sections) - Lua needs the local slot to exist first.
local finishChallenge
local runLysricStep
local tryGate         -- defined below with travelToZone; forward-declared so travelToSunriseHills (the
                       -- OTHER travel entry point) can Gate too. It could not before, which is exactly
                       -- how it ended up running the long way home from Vicus.
local gateIsReady     -- the "can we Gate right now" test, in ONE place. It was written out inline
                       -- twice already and the two copies were the seed of this bug class.
local checkBind       -- defined near tryGate; reports a bind Gate cannot use. NEVER changes the bind
local bindNoted = false   -- checkBind speaks once per run, not on every trip home
local shroudTooLowNoted = false   -- ensureShroud says "too low to shroud" once per run, not on every trip
local invisMissingZone = nil   -- zone id where "no invis available" was last said: once per zone (v2.32)
local ensureMovementBuff   -- defined near navToNpc (needs printIfRunning, item/spell/AA data tables)
local ensureShroud   -- defined near getGoblinRogueShroud (needs navToNpc, zones.pokShort, waitWhileProgressing)
-- ensureHealed forward-declared earlier (right before waitUntil/waitWhileProgressing), not here - it
-- needs to be visible to waitWhileProgressing itself, not just this block's own callers.

local function travelToSunriseHills()
    if mq.TLO.Zone.ID() == zones.neighborhood then
        print(lysricNear() and '\ag[Postmaster]\ax already in Sunrise Hills.'
            or '\ay[Postmaster]\ax in a neighborhood, but Lysric not found - check VoA / instance.')
        return
    end
    if state.neighborhood == "" then
        print('\ar[Postmaster]\ax set your neighborhood name in the window first.')
        return
    end

    ensureMovementBuff()   -- before the Guild Lobby leg starts, not just the last-mile navToNpc walk -
                             -- confirmed both pppoker and Astone apply their movement buff before
                             -- /travelto too (2026-08-09), not only during the final NPC approach.
    checkBind()   -- says so once if the bind is somewhere Gate cannot use. Reports only - the Gate tiers
                   -- make their own live bind check at the moment they fire.
    ensureShroud()   -- evil race + under tuning.shroudLevel gets a Goblin Rogue Shroud from the start, if
                      -- Settings asks for it (state.autoShroud, off since v2.46) - same single-early-hook
                      -- shape as the two calls above.
    ensureHealed()   -- AL, 2026-08-11: arrived in PoK hurt after escaping Erudin, then died to the Halas
                      -- zone-in guards partly for having gone in already hurt - free, risk-free recovery
                      -- since combat can't happen in a safe hub zone anyway.

    traveling = true

    -- 1. Guild Lobby
    if mq.TLO.Zone.ID() ~= zones.guildLobby then
        -- GATE FIRST on a long haul. This entry point used to go straight to /travelto, so a
        -- Gate-capable character RAN the entire way home - AL, 2026-08-24, returning from Vicus in
        -- North Qeynos: "we do have a Gate call, we run".
        --
        -- THIRD instance of one bug class. travelToZone got Gate-first routing in v1.21; its own Halas
        -- exit block had to be fixed separately in v1.22 because it ran BEFORE that logic; and this
        -- function never had it at all, because it is a wholly separate travel entry point that never
        -- calls travelToZone. The lesson from that v1.22 fix - "a path that runs before the main
        -- routing logic needs its own copy of any routing-priority fix" - applies across functions too,
        -- not just within one.
        --
        -- gateIsReady() is only true while bound in PoK or the Guild Lobby, so Gate lands at one of
        -- the two and the rest of the way here is short - from a Lobby bind, Gate lands right at the
        -- destination. Best-effort - if Gate fails or is down, the /travelto below still does the
        -- whole journey exactly as before.
        if (mq.TLO.Zone.ShortName() or "") ~= zones.pokShort and gateIsReady() then
            dbg('gating to the Plane of Knowledge first (much faster than running).')
            tryGate()
        end
        -- No "traveling to Guild Lobby..." line here: EasyFind announces the same thing on the very
        -- next line and says it better. Squelched so its three-line running commentary does not
        -- bury our own output either (owlbear does the same: `/squelch /travelto poknowledge`).
        dbg('travelto guildlobby')
        mq.cmd('/squelch /travelto guildlobby')
        -- 180s (not 60s): field-proven a multi-hop route (e.g. South Qeynos -> N.Qeynos -> PoK ->
        -- Guild Lobby) can take just over 60s to actually finish - same class of bug already fixed for
        -- the Kelethin CALL-nav and West Karana's navToNpc (EasyFind was still working, we just quit too early).
        if not waitUntil(function() return mq.TLO.Zone.ID() == zones.guildLobby end, 180000, 1000) then
            printIfRunning('\ar[Postmaster]\ax never reached the Guild Lobby (is /travelto available?).')
            traveling = false
            return
        end
        -- Was a flat 10s here (copied from guildhall.lua, no documented reason for that specific
        -- number). Cut to the same settle delay used elsewhere in this script after a zone-in; the
        -- v0.49 gate-nav retry loop (3 attempts) already absorbs any residual mesh-load lag.
        mq.delay(2000)
    end

    -- 2. Open the neighborhood gate
    --
    -- This line stays VISIBLE while Nav's own is silenced, and that is the deliberate way round. Nav
    -- announces this leg as "Navigating to switch: OBJ_IRONGATESWITCH", which tells a player nothing -
    -- so ours is the line worth keeping and the plugin's is the one worth suppressing.
    print('\ay[Postmaster]\ax in the Guild Lobby - navigating to the neighborhood gate...')
    -- (A bare `/nav log=off` used to sit here, inherited from guildhall.lua. It never did anything:
    -- MQ2Nav's own help calls log= an option that adjusts "log level for command", so it needs a
    -- navigation command to attach to. With no destination it is a no-op, which is why the [Nav]
    -- chatter kept appearing. The real control is log=off appended to each /nav below.)
    -- Navigation.Active() sometimes reads false before the walk even engages (same flake we hit on
    -- the Kelethin CALL-nav), so "wait for finish" can trivially pass with zero actual movement. Retry
    -- the whole nav+distance check a few times before giving up - cheaper and more honest than a
    -- one-shot bail, and the distance print gives real numbers if it still fails.
    local gateDist = nil
    for attempt = 1, 3 do
        mq.cmdf('/nav door id %d log=off', zones.gateSwitch)
        waitUntil(function() return mq.TLO.Navigation.Active() end, 5000, 100)       -- wait for nav to START
        waitUntil(function() return not mq.TLO.Navigation.Active() end, 30000, 200)  -- then wait for it to FINISH
        mq.delay(500)
        mq.cmdf('/squelch /doortarget id %d', zones.gateSwitch)
        mq.delay(300)
        gateDist = mq.TLO.Switch.Distance()
        dbg(string.format('gate attempt %d: distance=%s', attempt, tostring(gateDist)))
        if gateDist and gateDist <= 25 then break end
        mq.delay(1000)
    end
    -- only click once we're ACTUALLY at the gate (the "too far away" error was an early click)
    if gateDist and gateDist > 25 then
        printIfRunning('\ar[Postmaster]\ax did not reach the gate after 3 tries (too far to click) - try again.')
        traveling = false
        return
    end
    mq.cmd('/click left door')

    if not waitUntil(function() return mq.TLO.Window('RealEstateNeighborhoodWnd').Open() end, 20000) then
        printIfRunning('\ar[Postmaster]\ax the neighborhood window never opened.')
        traveling = false
        return
    end

    -- 3. SearchType index 3 = "neighborhood"; search the saved name, then enter the row whose NAME matches
    -- it exactly. v2.31: this used to take row 1 whatever it was, and the search matches any part of a
    -- name - "Alliance" also returns guild and player neighborhoods, one of which could be row 1. Column 1
    -- of RENW_NeighborhoodList is the neighborhood name (the game's own EQUI_RealEstateNeighborhoodWnd.xml).
    mq.cmd('/notify RealEstateNeighborhoodWnd RENW_SearchType_Combobox listselect 3')
    mq.delay(800)
    mq.TLO.Window('RealEstateNeighborhoodWnd/RENW_Search_EditBox').SetText(state.neighborhood)()
    mq.delay(600)
    mq.cmd('/notify RealEstateNeighborhoodWnd RENW_Search_Button leftmouseup')
    local results = mq.TLO.Window('RealEstateNeighborhoodWnd/RENW_NeighborhoodList')
    -- v2.47: the SERVER answers the search, and until it does the list still holds what the window opened
    -- with. 2.31-2.46 read the row the instant Search was pressed, so it could find the name in that OLD
    -- list; by the time listselect ran the results had replaced it, the row pointed at nothing, nothing was
    -- selected and Go did nothing (AL, Xanley, 2.46 - the first field run of the 2.31 change). So: the 1.5 s
    -- wait the pre-2.31 code always had, then only a row that reads the SAME on two polls in a row.
    mq.delay(1500)
    local row, last = 0, -1
    waitUntil(function()
        row = results.List('=' .. state.neighborhood, 1)() or 0
        local steady = row > 0 and row == last
        last = row
        return steady
    end, 5000, 500)
    if row == 0 then
        -- No exact match (a partial name typed, or a spelling off): take the first result as before, but
        -- SAY which one, so a wrong neighborhood is never a silent surprise.
        row = 1
        print(string.format('\ay[Postmaster]\ax no neighborhood named exactly "%s" - entering the first result, "%s".',
            state.neighborhood, results.List(1, 1)() or "?"))
    end
    -- Select, and CHECK it took before pressing Go - Go with nothing selected does nothing at all.
    for _ = 1, 2 do
        mq.cmdf('/notify RealEstateNeighborhoodWnd RENW_NeighborhoodList listselect %d', row)
        mq.delay(600)
        if (results.SelectedIndex() or 0) == row then break end
    end
    dbg(string.format('neighborhood: row %d of %d, selected %d, "%s"', row, results.Items() or 0,
        results.SelectedIndex() or 0, tostring(results.List(row, 1)())))
    mq.cmd('/notify RealEstateNeighborhoodWnd RENW_Go_Button leftmouseup')

    -- 4. Confirm arrival
    if not waitUntil(function() return mq.TLO.Zone.ID() == zones.neighborhood end, 45000, 1000) then
        printIfRunning('\ar[Postmaster]\ax did not zone into the neighborhood.')
        traveling = false
        return
    end
    mq.delay(2000)
    print(lysricNear() and '\ag[Postmaster]\ax arrived in Sunrise Hills - Lysric detected.'
        or '\ay[Postmaster]\ax in the neighborhood, but Lysric not found - check VoA / instance.')
    traveling = false

    -- All 18 delivered but Aric not yet hailed? Finish that automatically now that we're here -
    -- no need for a separate button click (finishChallenge sees we're already in-zone and skips
    -- re-traveling, then chains into Lysric itself). If Aric's already done but the satchel isn't,
    -- go straight to Lysric (covers a retry after she was performing last time).
    if deliveredCount() >= #DELIVERIES and not state.postmasterDone then
        finishChallenge()
    elseif state.postmasterDone and not state.lysricDone then
        runLysricStep()
    end
end

-- Nonad Brothers (Phase 2). PLACEHOLDERS - verify against the game (Allakhazam starting values).
-- The Nonad Brothers questline's NPCs, say-phrases and travel arg: seven names, one local slot.
-- Say-phrases must be EXACT - an NPC answers only its own keywords.
local nonad = {
    pagus          = "Pagus Nonad",
    vicus          = "Vicus Nonad",
    reward         = "Miniature Action Lashun",   -- Pagus's reward figure = Nonad completion flag (confirmed)
    brotherPhrase  = "Tell me about your brother",
    helpPhrase     = "help you with collections",
    listPhrase     = "What list?",   -- Vicus forgets the List of Debtors unless you ask (keyword [list])
    qeynosTravelto = "qeynos",       -- PLACEHOLDER: /travelto arg that lands in South Qeynos - verify
}
-- ONE table for every quest item name. These were six separate locals and the main chunk sits right on
-- Lua's 200-local ceiling (REFACTOR_NOTES.md #1) - folding them frees five slots and gives anything new
-- an obvious home. Same pattern as `aric` / `lysric` / `ui`. **Put new item names here.**
local items = {
    tonic   = "Cough Tonic",
    box     = "Tax Collection Box",
    hyredel = "Hyredel Swiftstride",
    satchel = "Featherweight Satchel of the Courier",
}
items.list = "List of Debtors"
-- Zones reached via an intermediate hop. Revamped Freeport shortnames are "freeportwest" /
-- "freeporteast" (per pppoker, zone IDs 383/382); route East Freeport via West Freeport to be safe.
local zoneRule = {}
zoneRule.via = {
    ["freeporteast"] = "freeportwest",   -- no PoK book to E.Freeport; hop across the W.Freeport zone line
}
-- Destinations where a direct /travelto legitimately succeeds (so waitWhileProgressing never trips its
-- stuck check - real movement the whole way) but takes a known-bad route to get there. Skip the direct
-- attempt entirely for these, go straight to the PoK-hub route. Everything not listed here keeps the
-- normal try-direct-first behavior (confirmed good for Halas/Everfrost). Add to as AL finds more.
-- qrg (Surefall Glade): ran Highpass->E Karana overland instead of PoK->Qeynos (AL: "took a MUCH longer
-- path... we might need a travel list").
-- felwithea (N.Felwithe): from Butcherblock (Siltria's pickup), direct travel started walking overland
-- through Butcherblock instead of porting via PoK. AL, in-field: "its faster to go back to PoK, then
-- Felwithe."
-- gfaydark (Kelethin): same story, from S.Kaladim (Kilam's pickup, the cluster's last stop) on into the
-- final Kelethin turn-in - also tried to run through Butcherblock. AL: "faster to run to PoK, THEN
-- Kelethin." Applies to both directions (Idia's #11 pickup in Kelethin and this cluster's delivery) -
-- both use this same shortname, and there's no reason to expect the pickup leg fares any better.
-- freeporteast (E.Freeport): from N.Felwithe (heading to Ton Twostring, #17), direct routed via a boat
-- crossing (Ocean of Tears) instead of PoK - exactly the "boat/island route nav can't reliably cross"
-- case this project already avoids PoK-routing for elsewhere (see the travelToZone header comment).
-- AL: "Leaving Felwithe should use Plane of Knowledge - 2." Applies to every approach to E.Freeport in
-- this quest (pickup #17 AND the freeporteast cluster's own final delivery), not just the Felwithe one -
-- a boat crossing is a bad idea from any Faydwer-side departure point, and PoK + the existing zoneRule.via
-- W.Freeport hop is already an established, working route regardless of where the trip started.
zoneRule.preferPok = {
    ["qrg"] = true,
    ["felwithea"] = true,
    ["gfaydark"] = true,
    ["freeporteast"] = true,
    ["qey2hh1"] = true,
}
-- qey2hh1 (West Karana) history: added v0.85 (EasyFind's own "-2" zone connection is broken - navmesh
-- can't locate it, falls back to "-1" only after a real stall). REMOVED v0.93 after AL manually
-- walk-tested the Qeynos Hills approach and saw it resolve to the good "-1". RE-ADDED v0.96(field) -
-- the actual script leg (direct FROM Surefall Glade, right after Sivina's pickup) still picked the
-- broken "-2" and had to fall back through PoK, which is what correctly landed on "-1" (via North
-- Qeynos -> Qeynos Hills - a DIFFERENT approach vector than starting from Surefall Glade, even though
-- both pass through Qeynos Hills). So it's not simply "near Qeynos Hills = safe" - the connection
-- EasyFind picks depends on the exact starting point of the path computation, and AL's manual test
-- apparently started from a different spot than where the script actually is on this leg. Lesson:
-- trust the SCRIPT's own field log over a manual approximation of the same route - don't remove this
-- again without seeing the script itself succeed direct multiple times.
-- Destinations where computing the FULL path in one /travelto picks a bad connection (see
-- zoneRule.preferPok above), but a SHORT, targeted 2-hop route - taken as two separate /travelto calls -
-- sidesteps it without paying the full PoK detour. Different from zoneRule.via (which hops AFTER already
-- reaching PoK): this is tried BEFORE falling back to PoK, as a faster alternative. Falls through to
-- the normal zoneRule.preferPok->PoK route automatically if either hop stalls, so this is a pure
-- speed optimization with the existing safety net intact, not a replacement for it.
-- qey2hh1 (West Karana): AL noticed the current PoK-route's OWN last leg (North Qeynos -> Qeynos Hills
-- -> West Karana) already proves approaching from Qeynos Hills resolves to the good "-1" - it's
-- specifically the Surefall-Glade-to-West-Karana SINGLE computation that picks the broken "-2", not
-- Qeynos Hills itself. AL: "what if instead of /travelto PoK, we simply /travelto qeynos hills to leave
-- Surefall, and once in Qeynos Hills THEN go to Western Plains - 1." Untested - if it doesn't pan out,
-- the qey2hh1 zoneRule.preferPok entry below still catches it via the normal PoK fallback.
zoneRule.viaDirect = {
    ["qey2hh1"] = "qeytoqrg",
}
-- v1.02 FAILED - a fresh /travelto qey2hh1 fired from Qeynos Hills STILL picked the broken "-2" (AL
-- field test, 2026-08-07). AL: "we had this similar problem in pppoker with leaving Neriak... a break
-- in the mesh code... only one [connector] has it working. We had to force a particular route in
-- Neriak." Checked pppoker's actual fix (EASYFIND_NERIAKA_SHORTNAME = "Neriak - Foreign Quarter - 1",
-- fired via `/easyfind <full connection name>`, NOT `/travelto`) - confirmed via RedGuides docs that
-- `/easyfind [search term]` searches the CURRENT zone's own known destinations and navigates directly
-- to a match, which is a genuinely different mechanism than `/travelto` (which computes its own path
-- and picks whichever connection it wants - confirmed earlier this project has no argument to choose).
-- Same technique should force the correct connection here: fire `/easyfind` with the exact connection
-- name (matching AL's own pasted console text) once standing in the zone that connection exists in,
-- instead of a bare `/travelto` to the destination zone.
zoneRule.forceConnection = {
    ["qey2hh1"] = "The Western Plains of Karana - 1",
}
-- Zones known to be directly walkable from each other (field-confirmed, not guessed) - used by
-- runClusterBatch to bundle a "passing right by" pickup into the current local leg instead of a
-- separate PoK round trip later. Add to as AL finds more; keep both directions in sync.
zoneRule.adjacent = {
    ["butcher"]  = { "kaladima" },   -- Butcherblock <-> S.Kaladim (AL: "we pass right by South Kaladim")
    ["kaladima"] = { "butcher" },
    ["qeynos"]   = { "qeynos2" },   -- S.Qeynos <-> N.Qeynos (AL, 2026-08-14: "walking over a little to
    ["qeynos2"]  = { "qeynos" },    -- the zone line" - a Gate-ready character was skipping straight to
                                     -- Gate+PoK for this hop since it wasn't in this table yet)
}
-- The Taxes #528 sub-quest: its say-phrase, debtors, their zones and the Flynn workaround - seven
-- names, one local slot. Same declare-then-fill pattern as `kelethin` / `halas`.
local tax = {}
tax.phrase = "tax collection"
items.fullbox = "Full Tax Collection Box"
-- The 10 tax debtors. PLACEHOLDER names - verify in-field (navToNpc finds them by live spawn).
-- First 8 are in South Qeynos; the last 2 live in other Qeynos zones (see tax.merchantZone).
tax.merchants = {
    "Ton Firepride", "Mar Sedder", "Nesiff Tallaherd", "Fhara Semhart",
    "Tasya Huntlan", "Captain Rohand", "Fish Ranamer", "Voleen Tassen",
    "Sneed Galliway", "Mira Sayer",
}

-- Merchants NOT in South Qeynos -> the /travelto arg for their home zone (both field-verified).
-- Merchants absent from this map are assumed to be in South Qeynos.
tax.merchantZone = {
    ["Sneed Galliway"] = "qeynos2",    -- North Qeynos (verified)
    -- Mira Sayer (Qeynos Hills, qeytoqrg) is SKIPPED - her tax is collected straight from Flynn.
}

-- Mira's tax may be "robbed" - then it's collected from Flynn Merrington (North Qeynos) with an
-- exact phrase. PLACEHOLDERs - verify name / zone / phrase in-field.
tax.mira        = "Mira Sayer"
tax.flynn       = "Flynn Merrington"
tax.flynnZone   = "qeynos2"
tax.flynnPhrase = "I am a gnoll loving weakling who isn't fit to comb my feet"

-- Engine helpers (reused by every quest step in Phase 2 and 3). Main-loop only (use mq.delay).

-- Kelethin bard-guild lift (Greater Faydark). TWO switches: ID 73 = bottom button, ID 74 = top.
-- Field-captured static locs (loc order Y X Z, matching /nav loc & /moveto). The platform surface has
-- NO navmesh, so we /nav (mesh) to CALL, then /moveto (straight walk, no mesh) on/off the platform.
-- Mechanics (AL): lifts rest UP; click 73 to call down (~8s), step on, click 73 again to rise (~8s),
-- step off. Ground z ~7.09, top landing z ~75.90 (Switch[73].Z~9 / Switch[74].Z~78 are references).
-- navToNpc still assist-bridges anything past the lift (platform-maze bridges/ramps).
local kelethin = {}
kelethin.btn     = 73
kelethin.call    = { y = 136.13, x = 233.77, z = 7.09 }    -- ground spot to click switch 73
kelethin.board   = { y = 135.38, x = 254.25, z = 7.09 }    -- platform center at the bottom
kelethin.alight  = { y = 134.51, x = 277.74, z = 75.90 }   -- top landing (step off here)
kelethin.topZ   = 75.90                                   -- arrived at top when Me.Z ~ this
kelethin.topBtn = 74                                      -- top button (only switch reachable from up top)
kelethin.boardTop = { y = 135.38, x = 254.25, z = 75.90 } -- platform center at the TOP (BOARD x/y, top z)

-- Halas exit: nav crosses the lake fine getting OUT, but can't climb the water-to-land edge on the
-- far side - field-confirmed stuck point 2026-08-04 (AL, same result twice, first-person camera did
-- not help). AL's manual recovery works every time: pause nav, hold forward ~3s, release, resume.
local halas = {}
halas.exitStuck = { y = -460.90, x = 3.60, z = -20.07 }
-- Climb out here instead of right at the stuck point - the shuttle raft sometimes parks/arrives at the
-- normal exit spot and physically blocks the climb (real drowning risk for low levels waiting on it to
-- move). Field-confirmed 2026-08-05: far enough to the side that the raft never interferes.
halas.exitClear = { y = -471.63, x = -5.24, z = -0.06 }

-- Halas entry via the lake shuttle "The Gwenavyne" - field-confirmed 2026-08-05 (AL): moves along Y
-- only (X/Z constant on the spawn itself), parks ~30s at each dock, ~5s crossing at Speed 71.42. The
-- character's actual standing Z on the deck is a constant -0.06 - NOT the boat's own reported Z
-- (-4.00, presumably its keel/anchor point underwater) - matches AL's own on-shore Z exactly, so no
-- Z-matching to the boat itself is needed. Same underlying mechanic as the Kelethin lift (board a
-- moving platform, ride passively, alight) - just horizontal motion instead of vertical.
halas.shuttleName = "The Gwenavyne"
halas.shuttleDockZonein = { y = -441.00, x = 12.00 }   -- where it parks on the zone-in side
halas.shuttleDockCity   = { y = -100.00, x = 12.00 }   -- where it parks on the city side
halas.shuttleDeckZ = -0.06                             -- character's standing Z while aboard
halas.shuttleWaitZonein = { y = -472.40, x = 12.32, z = -0.06 }  -- solid ground, zone-in side, wait here for it to dock
halas.shuttleLandingCity = { y = -29.22, x = 11.67, z = 1.93 }  -- solid ground, city side, off the deck

local function clickDoorSwitch(id)
    mq.cmdf('/squelch /doortarget id %d', id)
    mq.delay(200)
    mq.cmd('/squelch /face switch'); mq.delay(400)
    mq.cmd('/click left door'); mq.delay(800)
end

local function rideKelethinLift()
    dbg(string.format('rideKelethinLift: entered, meZ=%.1f', mq.TLO.Me.Z() or -1))
    -- already up at platform level? then the gap is a bridge/ramp, not the lift - let assist handle it
    if (mq.TLO.Me.Z() or 0) > kelethin.topZ - 20 then
        dbg('rideKelethinLift: already at platform level - skipping (bridge/ramp gap, not the lift).')
        return false
    end

    -- 1. nav (mesh) to the ground calling spot
    dbg(string.format('rideKelethinLift: navving to CALL (%.2f,%.2f,%.2f)',
        kelethin.call.y, kelethin.call.x, kelethin.call.z))
    mq.cmdf('/nav loc %.2f %.2f %.2f log=off', kelethin.call.y, kelethin.call.x, kelethin.call.z)
    mq.delay(500)
    -- 180s (not 60s): field-proven nav to CALL always succeeds but sometimes takes longer than 60s
    -- (path length varies with which zone connection we entered gfaydark through).
    if not waitUntil(function() return not mq.TLO.Navigation.Active() end, 180000, 200) then
        print('\ay[Postmaster]\ax could not reach the Kelethin lift - falling back to a manual assist.')
        return false
    end
    mq.cmd('/squelch /nav stop'); mq.delay(400)
    dbg(string.format('rideKelethinLift: at CALL area, meZ=%.1f', mq.TLO.Me.Z() or -1))

    -- 2. call the platform down (it rests up) and wait ~8s for it to arrive
    dbg('calling lift down via switch ' .. kelethin.btn)
    dbg('calling the Kelethin lift down...')
    clickDoorSwitch(kelethin.btn)
    mq.delay(9000)   -- ~8s travel + margin (AL-measured)

    -- 3. /moveto ONTO the platform (no navmesh on it), then confirm we actually landed on it (z ~ ground)
    dbg('stepping onto the lift platform...')
    mq.cmdf('/squelch /moveto loc %.2f %.2f %.2f', kelethin.board.y, kelethin.board.x, kelethin.board.z)
    mq.delay(500)
    waitUntil(function() return not mq.TLO.Me.Moving() end, 8000, 100)
    mq.delay(400)
    local dy, dx = (mq.TLO.Me.Y() or 0) - kelethin.board.y, (mq.TLO.Me.X() or 0) - kelethin.board.x
    if math.sqrt(dy * dy + dx * dx) > 6 or math.abs((mq.TLO.Me.Z() or 0) - kelethin.board.z) > 5 then
        print(string.format('\ay[Postmaster]\ax not on the platform (meZ=%.1f) - assist fallback.', mq.TLO.Me.Z() or 0))
        return false
    end

    -- 4. click 73 again to rise; wait until Me.Z reaches the top landing height
    dbg('rising via switch ' .. kelethin.btn)
    dbg('riding the lift up...')
    clickDoorSwitch(kelethin.btn)
    if not waitUntil(function() return (mq.TLO.Me.Z() or 0) >= kelethin.topZ - 4 end, 15000, 200) then
        print('\ay[Postmaster]\ax lift did not reach the top - assist fallback.')
        return false
    end
    mq.delay(800)

    -- 5. /moveto OFF the platform onto the top landing (no mesh here either), then navToNpc takes over
    dbg('stepping off onto the top landing...')
    mq.cmdf('/squelch /moveto loc %.2f %.2f %.2f', kelethin.alight.y, kelethin.alight.x, kelethin.alight.z)
    mq.delay(500)
    waitUntil(function() return not mq.TLO.Me.Moving() end, 8000, 100)
    mq.delay(500)
    dbg(string.format('up at platform, z=%.1f', mq.TLO.Me.Z() or 0))
    print('\ag[Postmaster]\ax up at the Kelethin platform - heading to the NPC.')
    return true
end

-- Controlled descent (leaving Kelethin). EasyFind's /travelto rides the lift down by clicking mid-run,
-- so we run onto the moving platform and fall off the side. Instead we take the lift down ourselves
-- first: /moveto onto the parked-up platform (STOP), click 74 (the only switch reachable up top) to
-- descend, ride to ground, /moveto off. Then /travelto starts from solid ground and skips the elevator.
local function descendKelethinLift()
    if (mq.TLO.Me.Z() or 0) < kelethin.topZ - 20 then return false end   -- not up top; nothing to do

    dbg('stepping onto the top platform to descend...')

    -- NAV to the landing FIRST, then /moveto onto the platform. This mirrors the UP path exactly
    -- (/nav to CALL, then /moveto onto BOARD) and it was MISSING here - the descent went straight to
    -- /moveto from wherever the character happened to be standing.
    --
    -- Why that mattered (AL's log, 2026-08-24): after a Kelethin delivery the character is deep in the
    -- platform maze, and /moveto is a STRAIGHT-LINE walk with no pathing. It reported
    -- "off by 347.0 - meY=-211.6" against a target of 135.38 - it never got close, because it cannot
    -- path around the bridges and ramps. The landing DOES have navmesh (nav reaches it on the way up),
    -- so navving there first turns the /moveto back into the short hop it was designed to be.
    --
    -- This is very likely why the descent has always been the unreliable half while the ascent has
    -- multiple clean runs. **Needs field confirmation** - the mechanism fits the evidence exactly, but
    -- it has not yet been watched working.
    mq.cmdf('/nav loc %.2f %.2f %.2f log=off', kelethin.alight.y, kelethin.alight.x, kelethin.alight.z)
    waitUntil(function() return mq.TLO.Navigation.Active() end, 5000, 100)
    waitUntil(function() return not mq.TLO.Navigation.Active() end, 30000, 200)
    mq.delay(400)

    mq.cmdf('/squelch /moveto loc %.2f %.2f %.2f', kelethin.boardTop.y, kelethin.boardTop.x, kelethin.boardTop.z)
    mq.delay(500)
    waitUntil(function() return not mq.TLO.Me.Moving() end, 8000, 100)
    mq.delay(400)
    local dy, dx = (mq.TLO.Me.Y() or 0) - kelethin.boardTop.y, (mq.TLO.Me.X() or 0) - kelethin.boardTop.x
    if math.sqrt(dy * dy + dx * dx) > 6 then
        -- Sentence stays visible, numbers go to debug: "off by 347.0 - meY=-211.6 meX=256.9 meZ=78.5"
        -- is exactly what diagnosed this, and exactly what a player cannot read.
        dbg(string.format('board-top miss: off by %.1f - meY=%.1f meX=%.1f meZ=%.1f',
            math.sqrt(dy * dy + dx * dx), mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0, mq.TLO.Me.Z() or 0))
        dbg('could not board the lift platform - letting EasyFind route down instead.')
        return false
    end

    dbg('descending via switch ' .. kelethin.topBtn)
    dbg('riding the lift down...')
    clickDoorSwitch(kelethin.topBtn)
    if not waitUntil(function() return (mq.TLO.Me.Z() or 0) <= kelethin.board.z + 4 end, 15000, 200) then
        dbg('descent did not complete - letting EasyFind route down.')
        return false
    end
    mq.delay(800)

    mq.cmdf('/squelch /moveto loc %.2f %.2f %.2f', kelethin.call.y, kelethin.call.x, kelethin.call.z)
    mq.delay(500)
    waitUntil(function() return not mq.TLO.Me.Moving() end, 8000, 100)
    print('\ag[Postmaster]\ax down at Kelethin ground - continuing travel.')
    return true
end

-- Watches for the known Halas exit stuck point WHILE nav is actively driving normal travel (does NOT
-- nav to the point itself as a destination - v0.68/v0.69 tried that and field logs showed nav simply
-- "arrived" at our chosen point and went idle on its own success, making /nav pause a rejected no-op
-- ("Navigation must be active to pause") since there was nothing left to pause - the hold-forward never
-- had a real stuck-nav condition to work against, matching AL's report that it never paused or moved.
-- AL's real manual recovery happens while nav is STILL actively churning against the ledge, not after
-- it's given up - so this only intervenes under that same condition. Me.FeetWet doubles as the "still
-- stuck" guard AND the outcome check - once it goes false, later polls no-op naturally.
-- Deliberately allowed to re-attempt on every poll if still stuck (see travelToZone) - one climb
-- attempt doesn't always fully clear the ledge, and re-polling gives it another push. Me.FeetWet is
-- the natural guard: once actually out of the water, this no-ops on every subsequent poll.
local function halasExitWatch()
    if not mq.TLO.Me.FeetWet() then return end
    if not mq.TLO.Navigation.Active() then return end
    local dy, dx = (mq.TLO.Me.Y() or 0) - halas.exitStuck.y, (mq.TLO.Me.X() or 0) - halas.exitStuck.x
    if math.sqrt(dy * dy + dx * dx) >= 15 then return end
    print('\ao[Postmaster]\ax at the Halas stuck point - pausing nav, moving clear of the shuttle raft spot, and climbing out...')
    -- Pause first (nav is genuinely active here, so this succeeds - same proven-safe moment as before).
    -- Shift over via /moveto (a plain straight-line move, not a new /nav target) so we never touch
    -- nav's own destination - redirecting nav itself risks the exact "arrives and goes idle" bug this
    -- whole handler was built to avoid. /nav pause off at the end resumes nav's ORIGINAL target.
    -- Deliberately NO delay between /moveto and the not-Moving check (v0.72 added one, matching
    -- descendKelethinLift's pattern - REVERTED in v0.74). AL directly compared both in the field: with
    -- no delay, the hold-forward overlaps the still-resolving /moveto and reliably clears the shuttle
    -- raft's spot whether it's present or not; with the delay forcing a full stop first, /moveto gets
    -- flat-out blocked when the shuttle is actually there, degrading to "wait for the shuttle to leave."
    -- The Kelethin platform has no moving obstruction to get blocked by - that pattern doesn't transfer.
    mq.cmd('/nav pause')
    mq.cmdf('/squelch /moveto loc %.2f %.2f %.2f', halas.exitClear.y, halas.exitClear.x, halas.exitClear.z)
    waitUntil(function() return not mq.TLO.Me.Moving() end, 8000, 200)
    mq.cmd('/keypress forward hold')
    mq.delay(3000)
    mq.cmd('/keypress forward')
    mq.cmd('/nav pause off')
    if mq.TLO.Me.FeetWet() then
        print('\ar[Postmaster]\ax still in the water after climbing - trying again next poll...')
    else
        print('\ag[Postmaster]\ax confirmed out of the water - continuing travel.')
    end
end

-- Field-captured (AL, 2026-08-06): stepping onto Erudin's first gem (docks -> up into the city), nav
-- sometimes loops in place right at the gem without ever triggering the port on its own ("maybe a race
-- issue" - AL, seen 100% of the time on one character, intermittently on others). Gem isn't targetable,
-- so this is fixed-coordinate. Confirms via a big Z jump (stuck Z ~-42, ported Z ~36 - a real port, not
-- a normal walking delta - field-captured, both locs confirmed by AL, and confirmed identical again on
-- a second capture - same spot, well within the 15-unit radius below).
-- v0.99 wired this into travelToZone - wrong spot, dead code (its first line returns early once the
-- anchor NPC's spawn is "known," which happens clear across the zone before the gem is ever reached).
-- v1.00 moved it to navToNpc's POST-timeout branch, modeled on rideKelethinLift - ALSO wrong, still zero
-- console output. Root cause this time: unlike the Kelethin lift (no path exists at all, so nav gives up
-- FAST and cleanly), Erudin's gem is walkable right up to the edge, so nav keeps finding a "path" and
-- retrying instead of ever going idle - Navigation.Active() likely never goes false during the whole
-- stuck loop, so navToNpc's first wait (up to 180s) never even gets past its own gate to reach the
-- Kelethin-style branch at all. This is the SAME shape as the Halas exit fix, not the Kelethin lift -
-- stuck WHILE nav is still genuinely active, not after it gives up. v1.01 hooks this into navToNpc's
-- first wait's own cond callback instead (checked on every poll, same as halasExitWatch), and restores
-- the /nav pause + /nav pause off around the nudge, since nav IS still active here and would otherwise
-- fight the manual keypress.
local ERUDIN_GEM_STUCK = { y = -1398.66, x = -255.09, z = -42.02 }

local function tryErudinGem()
    if (mq.TLO.Me.Z() or 0) > 0 then return false end
    local dy, dx = (mq.TLO.Me.Y() or 0) - ERUDIN_GEM_STUCK.y, (mq.TLO.Me.X() or 0) - ERUDIN_GEM_STUCK.x
    if math.sqrt(dy * dy + dx * dx) >= 15 then return false end
    print('\ao[Postmaster]\ax at the Erudin gem - pausing nav and nudging forward to trigger the port...')
    mq.cmd('/nav pause')
    -- Short hold, not the Halas climb-out's 3000ms - AL described this as "simply step forward a nudge,"
    -- a much smaller correction than fighting water collision. May need tuning after the first test.
    mq.cmd('/keypress forward hold')
    mq.delay(800)
    mq.cmd('/keypress forward')
    mq.cmd('/nav pause off')
    if (mq.TLO.Me.Z() or 0) > 0 then
        print('\ag[Postmaster]\ax confirmed ported up - continuing.')
        return true
    end
    print('\ar[Postmaster]\ax still down at the gem - will try again next poll.')
    return false
end

-- Rides the Halas lake shuttle instead of swimming across (see HALAS_SHUTTLE_* constants above for the
-- field-confirmed mechanics). Best-effort: on any failure (shuttle not found, never docks on our side,
-- crossing takes too long) it just returns false and lets the caller's normal navToNpc swim across as
-- it always has - this is a sidestep of the swim, not a replacement for the fallback.
-- v0.79 fix: the original version waited for the shuttle wherever travelToZone happened to drop us,
-- instead of actually walking to the dock first - AL caught this in the field ("we are still at zone
-- line until the shuttle docks... wrong"). Now navs to the confirmed waiting spot BEFORE waiting.
local function rideHalasShuttleIn()
    if (mq.TLO.Spawn(halas.shuttleName).ID() or 0) == 0 then
        dbg('Halas shuttle not found - swimming across instead.')
        return false
    end
    print('\ao[Postmaster]\ax heading to the shuttle dock...')
    mq.cmdf('/nav loc %.2f %.2f %.2f log=off', halas.shuttleWaitZonein.y, halas.shuttleWaitZonein.x, halas.shuttleWaitZonein.z)
    mq.delay(500)
    waitUntil(function() return not mq.TLO.Navigation.Active() end, 30000, 200)

    print('\ao[Postmaster]\ax waiting for the Halas shuttle to dock...')
    -- 180s ceiling, not the original 120s - the dock-pause duration is uncertain (AL's own estimate
    -- was rough, "maybe 30 seconds or so"), so a full dock-to-dock cycle could run longer than assumed.
    if not waitUntil(function()
        local s = mq.TLO.Spawn(halas.shuttleName)
        return not s.Moving() and (s.Y() or 0) < -300
    end, 180000, 1000) then
        dbg('shuttle did not dock on our side in time - swimming across instead.')
        return false
    end
    local boatY = mq.TLO.Spawn(halas.shuttleName).Y() or halas.shuttleDockZonein.y
    print('\ao[Postmaster]\ax boarding the shuttle...')
    mq.cmdf('/squelch /moveto loc %.2f %.2f %.2f', boatY, halas.shuttleDockZonein.x, halas.shuttleDeckZ)
    mq.delay(500)
    waitUntil(function() return not mq.TLO.Me.Moving() end, 8000, 200)
    print('\ao[Postmaster]\ax aboard - waiting for it to depart...')
    -- Two phases, not one blind timeout (field bug 2026-08-05: a single 60s wait covering BOTH the
    -- dock-pause AND the crossing fired mid-crossing because the dock pause alone ran close to or past
    -- 60s). (1) Wait for it to actually START moving - not moving yet here is NORMAL (still in its
    -- dock pause), not a sign of trouble, so this needs a generous ceiling. (2) Once genuinely moving,
    -- the crossing itself is short and well-understood (~5s at its confirmed Speed 71.42) - if it
    -- doesn't dock on the far side reasonably quickly from THIS point, something's actually wrong.
    if not waitUntil(function() return mq.TLO.Spawn(halas.shuttleName).Moving() end, 180000, 1000) then
        dbg('shuttle never departed - continuing manually.')
        return false
    end
    print('\ao[Postmaster]\ax riding across...')
    if not waitUntil(function()
        local s = mq.TLO.Spawn(halas.shuttleName)
        return not s.Moving() and (s.Y() or -999) > -200
    end, 30000, 500) then
        dbg('shuttle crossing took too long - continuing manually.')
        return false
    end
    mq.cmdf('/squelch /moveto loc %.2f %.2f %.2f', halas.shuttleLandingCity.y, halas.shuttleLandingCity.x, halas.shuttleLandingCity.z)
    mq.delay(500)
    waitUntil(function() return not mq.TLO.Me.Moving() end, 8000, 200)
    print('\ag[Postmaster]\ax off the shuttle on solid ground - continuing.')
    return true
end

-- Mirror of rideHalasShuttleIn for the return trip (AL: "on the way back same routing in reverse to
-- leave Halas"). Best-effort, same as the entry version - on any failure it returns false and leaves
-- the existing swim-based climbOutOfHalas/halasExitWatch fix as the fallback (still wired into
-- travelToZone's PoK-hub wait, unchanged).
local function rideHalasShuttleOut()
    if (mq.TLO.Spawn(halas.shuttleName).ID() or 0) == 0 then
        dbg('Halas shuttle not found - swimming out instead.')
        return false
    end
    print('\ao[Postmaster]\ax heading to the shuttle dock (city side)...')
    mq.cmdf('/nav loc %.2f %.2f %.2f log=off', halas.shuttleLandingCity.y, halas.shuttleLandingCity.x, halas.shuttleLandingCity.z)
    mq.delay(500)
    waitUntil(function() return not mq.TLO.Navigation.Active() end, 30000, 200)

    print('\ao[Postmaster]\ax waiting for the Halas shuttle to dock...')
    -- 180s ceiling, not the original 120s - see rideHalasShuttleIn for why (uncertain dock-pause length).
    if not waitUntil(function()
        local s = mq.TLO.Spawn(halas.shuttleName)
        return not s.Moving() and (s.Y() or -999) > -200
    end, 180000, 1000) then
        dbg('shuttle did not dock on our side in time - swimming out instead.')
        return false
    end
    local boatY = mq.TLO.Spawn(halas.shuttleName).Y() or halas.shuttleDockCity.y
    print('\ao[Postmaster]\ax boarding the shuttle...')
    mq.cmdf('/squelch /moveto loc %.2f %.2f %.2f', boatY, halas.shuttleDockCity.x, halas.shuttleDeckZ)
    mq.delay(500)
    waitUntil(function() return not mq.TLO.Me.Moving() end, 8000, 200)
    print('\ao[Postmaster]\ax aboard - waiting for it to depart...')
    -- Two phases, not one blind timeout - see rideHalasShuttleIn for the field bug this fixes (a
    -- single 60s wait covering both the dock-pause and the crossing fired mid-crossing).
    if not waitUntil(function() return mq.TLO.Spawn(halas.shuttleName).Moving() end, 180000, 1000) then
        dbg('shuttle never departed - continuing manually.')
        return false
    end
    print('\ao[Postmaster]\ax riding back...')
    if not waitUntil(function()
        local s = mq.TLO.Spawn(halas.shuttleName)
        return not s.Moving() and (s.Y() or 0) < -300
    end, 30000, 500) then
        dbg('shuttle crossing took too long - continuing manually.')
        return false
    end
    mq.cmdf('/squelch /moveto loc %.2f %.2f %.2f', halas.shuttleWaitZonein.y, halas.shuttleWaitZonein.x, halas.shuttleWaitZonein.z)
    mq.delay(500)
    waitUntil(function() return not mq.TLO.Me.Moving() end, 8000, 200)
    print('\ag[Postmaster]\ax off the shuttle, back on solid ground - continuing.')
    return true
end

-- Movement (speed) pipeline (TRAVEL_REFERENCE.md "Speed / Movement Pipeline"), applied before every
-- navToNpc walk - unconditional, not zone-gated. AL (2026-08-08): "movement is for everyone, its not
-- for 'escaping' its used for getting the quest done faster" - unlike Invis (danger-specific), this
-- benefits every character regardless of level or faction, so it just runs everywhere. Self-guards via
-- the already-buffed check below, so calling it unconditionally costs nothing when a buff is already up.
-- "Already buffed?" is a generic SPA-3 (SE_MovementSpeed) buff-slot scan - adapted from pppoker's
-- pppokerMovementBuffPresent() - catches a speed buff from ANY source (spell, AA, item) with no
-- per-class name list needed, same technique whether the buff came from this pipeline or something else.
-- Now a FULL AA -> class spell -> item chain (2026-08-09) - AA/spell names pulled directly from
-- pppoker's own field-verified MOVEMENT_CLASS_BUFFS/MOVEMENT_SELF_AA_NAMES config, not guessed (the
-- earlier item-tier-only version was a deliberate gap, not a permanent design - see CHANGELOG v1.11).
-- Field case that surfaced this (AL, 76 Druid, 2026-08-09): expected Spirit of Wolf, got Worn Totem
-- instead, since the spell tier simply didn't exist yet.
-- Best-effort: WARNS and proceeds unbuffed if nothing is available, does not bail - this reduces risk
-- crossing the zone, it does not guarantee safety (AL's own High Keep deaths happened twice even WITH a
-- speed buff already up), and the caller still has to cross the zone either way.
local MOVEMENT_CLASS_SPELLS = {
    BRD = { "Selo's Accelerando", "Selo's Song of Travel" },
    BST = { "Spirit of Wolf", "Spirit of the Shrew" },
    DRU = { "Spirit of Wolf", "Spirit of Cheetah" },
    RNG = { "Spirit of Wolf" },
    SHM = { "Spirit of Wolf", "Spirit of Cheetah" },
}
local MOVEMENT_SELF_AA_NAMES = {
    "Selo's Sonata",              -- BRD
    "Spirit of the White Wolf",   -- BST
}

local function hasMovementBuff()
    if (mq.TLO.Me.Mount.ID() or 0) > 0 then return true end
    for i = 1, 42 do
        local buffName = mq.TLO.Me.Buff(i).Name()
        if buffName and buffName ~= "" then
            local ok, hasSpa = pcall(function() return mq.TLO.Spell(buffName).HasSPA(3)() end)
            if ok and hasSpa then return true end
        end
    end
    return false
end

-- Full memorize-and-cast for a class buff spell - matches pppoker's pppokerApplyMovementClassBuff AND
-- Astone's useMovementBuff in complete detail, not just the cast sequence. v1.17/v1.19 fixed pieces of
-- the CAST (real cast time, self-target, settle delay) but never handled memorization - four straight
-- field failures on the same Spirit-of-Wolf case (76 Druid) turned out to be because the spell simply
-- wasn't memmed, so the cast block was never even reached; every cast-sequence fix was correct but
-- inert. Shared by Movement and Invis's spell tiers (both need the identical mem/meditate/cast dance).
-- Sequence, cross-checked against BOTH proven scripts: skip if the spell doesn't exist or the character
-- isn't high enough level -> find where it's already memmed (scan gem NAMES) or free/clear a slot and
-- /memspell it -> up to 2 attempts: meditate for mana if short, self-target, cast, wait for the real
-- cast time to clear, settle, then verifyFn (exact-buff check for movement, Me.Invis(1) for invis).
local function memorizeAndCastSpell(spell, verifyFn)
    local spellData = mq.TLO.Spell(spell)
    if (spellData.ID() or 0) == 0 then return false end
    local myLevel = mq.TLO.Me.Level() or 0
    local minLevel = spellData.MinCasterLevel() or 0
    if minLevel > 0 and myLevel < minLevel then return false end

    local maxGems = mq.TLO.Me.NumGems() or 8
    local gemSlot = nil
    for i = 1, maxGems do
        local n = mq.TLO.Me.Gem(i).Name()
        if n and n:lower() == spell:lower() then
            gemSlot = i
            break
        end
    end
    if not gemSlot then
        for i = 1, maxGems do
            if (mq.TLO.Me.Gem(i).ID() or 0) == 0 then
                gemSlot = i
                break
            end
        end
        if not gemSlot then
            gemSlot = maxGems
            mq.cmdf('/memspell %d clear', gemSlot)
            mq.delay(2000)
        end
        dbg(string.format('memorizing %s in gem %d...', spell, gemSlot))
        mq.cmdf('/memspell %d "%s"', gemSlot, spell)
        mq.delay(8000)
    end

    for _ = 1, 2 do
        local neededMana = math.max(40, spellData.Mana() or 0)
        if (mq.TLO.Me.MaxMana() or 0) > 0 and (mq.TLO.Me.CurrentMana() or 0) < neededMana then
            print(string.format('\ay[Postmaster]\ax meditating for mana (need %d, have %d)...', neededMana, mq.TLO.Me.CurrentMana() or 0))
            mq.cmd('/sit on')
            local t0 = mq.gettime()
            while (mq.TLO.Me.CurrentMana() or 0) < neededMana and mq.gettime() - t0 < 120000 do
                mq.delay(500)
            end
            mq.cmd('/stand')
        end
        if mq.TLO.Me.SpellReady(spell)() then
            mq.cmd('/target myself')
            mq.delay(400)
            mq.cmdf('/cast "%s"', spell)
            local castTime = spellData.CastTime() or 5000
            waitUntil(function() return not mq.TLO.Me.Casting() end, castTime + 3000, 100)
            mq.delay(350)
            if verifyFn() then return true end
        else
            mq.delay(2000)
        end
    end
    return false
end

ensureMovementBuff = function()
    if hasMovementBuff() then return true end
    for _, aaName in ipairs(MOVEMENT_SELF_AA_NAMES) do
        local aa = mq.TLO.Me.AltAbility(aaName)
        if (aa.ID() or 0) > 0 and mq.TLO.Me.AltAbilityReady(aaName)() then
            mq.cmdf('/alt activate %d', aa.ID())
            mq.delay(1000)
            if hasMovementBuff() then return true end
        end
    end
    local spellList = MOVEMENT_CLASS_SPELLS[(mq.TLO.Me.Class.ShortName() or ""):upper()]
    if spellList then
        for _, spell in ipairs(spellList) do
            if memorizeAndCastSpell(spell, function() return (mq.TLO.Me.Buff(spell).ID() or 0) > 0 or hasMovementBuff() end) then
                return true
            end
        end
    end
    local boots = mq.TLO.FindItem("=Journeyman's Boots")
    if (boots.ID() or 0) > 0 then
        mq.cmdf('/useitem "%s"', boots.Name())
        mq.delay(1000)
        if hasMovementBuff() then return true end
    end
    local totem = mq.TLO.FindItem("=Worn Totem")
    if (totem.ID() or 0) > 0 and (totem.TimerReady() or 0) == 0 then
        mq.cmdf('/useitem "%s"', totem.Name())
        mq.delay(1500)
        if hasMovementBuff() then return true end
    end
    -- AL, 2026-08-11: died to the Halas zone-in guards partly for lack of a speed buff - "I might need
    -- to add a reminder to user to get a SoW potion perhaps." A cheap Spirit of Wolf potion covers any
    -- class/level with no AA/spell/item source of its own; this is a reminder only, not an automated
    -- purchase (no confirmed vendor/price to buy against).
    printIfRunning('\ay[Postmaster]\ax no speed buff available for this hazard zone - crossing without one, extra caution advised. Consider buying a Spirit of Wolf potion if you plan to keep running dangerous zones bare.')
    return false
end

-- Invis pipeline (TRAVEL_REFERENCE.md "Invisibility Pipeline"): AA -> class spell -> Cloudy Potion.
-- Full per-class table (2026-08-08) pulled directly from pppoker's own field-verified config, cross-
-- checked against EQResource AA IDs - see TRAVEL_REFERENCE.md "Class Sources" for the sourcing/notes on
-- each entry. Living/NORMAL invis only (Me.Invis(1)) - any IVU (invis-vs-undead) options are excluded,
-- they don't help against living NPC guards (confirmed trap: Allakhazam's SHD wiki page surfaces the
-- WRONG-type AA; "Cloak of Shadows" - not in that wiki table - is the real living-invis one).
local INVIS_CLASS_SPELLS = {
    NEC = { "Skin of the Shadow", "Gather Shadows" },
    BRD = { "Shauri's Sonorous Clouding" },
    DRU = { "Improved Superior Camouflage", "Superior Camouflage", "Camouflage" },
    RNG = { "Superior Camouflage", "Camouflage" },
    ENC = { "Superior Invisibility", "Invisibility" },
    MAG = { "Invisibility" },
    WIZ = { "Superior Invisibility", "Improved Invisibility", "Invisibility" },
    SHM = { "Spirit Veil", "Invisibility" },
}
-- Self-only invis AAs, name-checked (not ID-checked) so untrained/wrong-class AAs cleanly return 0 and
-- get skipped - pppoker hit a real bug (v3.60) checking AA readiness by ID, which read "ready" for AAs
-- the character never trained. Tried in this order for every class; wrong-class names just no-op.
local INVIS_SELF_AA_NAMES = {
    "Perfected Invisibility",              -- ENC/MAG/WIZ
    "Cloak of Shadows",                    -- NEC/SHD - living invis (NOT the IVU AA)
    "Innate Camouflage",                   -- DRU/RNG
    "Perfected Natural Invisibility", "Improved Natural Invisibility", "Natural Invisibility",  -- BST
    "Perfected Silent Presence", "Silent Presence",  -- SHM
}

local function ensureInvisBuff()
    if mq.TLO.Me.Invis(1)() then return true end
    for _, aaName in ipairs(INVIS_SELF_AA_NAMES) do
        local aa = mq.TLO.Me.AltAbility(aaName)
        if (aa.ID() or 0) > 0 and mq.TLO.Me.AltAbilityReady(aaName)() then
            mq.cmdf('/alt activate %d', aa.ID())
            mq.delay(1000)
            if mq.TLO.Me.Invis(1)() then return true end
        end
    end
    local spellList = INVIS_CLASS_SPELLS[(mq.TLO.Me.Class.ShortName() or ""):upper()]
    if spellList then
        for _, spell in ipairs(spellList) do
            if memorizeAndCastSpell(spell, function() return mq.TLO.Me.Invis(1)() end) then
                return true
            end
        end
    end
    local potion = mq.TLO.FindItem("=Cloudy Potion")
    if (potion.ID() or 0) > 0 then
        mq.cmdf('/useitem "%s"', potion.Name())
        mq.delay(1000)
        if mq.TLO.Me.Invis(1)() then return true end
    end
    -- ONCE per zone (v2.32). navToNpc's guard watch calls this on every poll of a walk while a guard is
    -- near, so with nothing to cast it printed the same line 28 times in one walk (AL, level 1 Iksar).
    -- The finding does not change mid-zone; saying it once is the whole of its value.
    if invisMissingZone ~= mq.TLO.Zone.ID() then
        invisMissingZone = mq.TLO.Zone.ID()
        printIfRunning('\ay[Postmaster]\ax no invis available - crossing near a guard without one, KOS risk.')
    end
    return false
end

-- Drops invis before an NPC interaction that would otherwise be ignored while invisible (confirmed
-- Halas mechanic - invis blocks NPC response). /makemevisible is the primary tool (TRAVEL_REFERENCE.md
-- "Dropping Invis On Demand") - no buff-name tracking needed, clears both standard and undead invis.
-- Falls back to a partial-match /removebuff if that somehow doesn't clear it. Returns true if it
-- actually dropped something, so the caller knows to reapply after.
local function dropInvisForInteraction()
    if not (mq.TLO.Me.Invis(1)() or false) then return false end
    mq.cmd('/makemevisible')
    if not waitUntil(function() return not (mq.TLO.Me.Invis(1)() or false) end, 3000, 200) then
        mq.cmd('/removebuff invis')
        waitUntil(function() return not (mq.TLO.Me.Invis(1)() or false) end, 3000, 200)
    end
    return true
end

-- Dynamic guard-proximity check (AL, 2026-08-08) - replaces the idea of pre-mapping every dangerous
-- zone/loc: any zone with an unmapped guard cluster (Felwithe gate, Kelethin lift, South Kaladim's
-- "outside AND inside, LOTS of them") gets covered automatically, no field-captured coordinates needed.
-- Verified spawn-search syntax (MQ docs "Spawn Search"): "name" does a substring match, combinable with
-- "radius #" in one search string. Confirmed South Kaladim's actual guard names ("Guard Kindor",
-- "Kaladim Guard") both contain "guard" regardless of prefix/suffix position, so a substring match
-- catches either naming convention.
local function guardNearby()
    return (mq.TLO.Spawn(string.format("npc name guard radius %d", tuning.guardRadius)).ID() or 0) > 0
end

local function navToNpc(name)
    automation.lastNpc = name   -- a fight near this NPC counts as "at" it (retryStep's repeat-fight wait)
    local id = mq.TLO.Spawn("npc " .. name).ID() or 0
    if id == 0 then
        print('\ar[Postmaster]\ax NPC not found nearby: ' .. name)
        return false
    end
    local watchErudinGem = (mq.TLO.Zone.ShortName() or "") == "erudnext"
    -- Movement: unconditional, for everyone (see ensureMovementBuff's own comment). Invis/guard-watch:
    -- only for factionRisk characters below the level where guard aggro stops mattering.
    -- Not in a safe hub (v2.32): the Guild Lobby has NPCs with "guard" in the name, so a level 1 Iksar
    -- walking to its reagent vendor tripped the watch on every poll, where nothing can attack at all.
    local watchGuards = factionRisk and (mq.TLO.Me.Level() or 0) < tuning.factionRiskLevel and not zones.inSafeHub()
    local function farFrom(range) return (mq.TLO.Spawn("id " .. id).Distance3D() or 999) > range end
    -- The player closes the last bit by hand and we carry on the moment they are within `range`.
    local function waitForPlayer(range)
        if not waitUntil(function() return not farFrom(range) end, 600000, 1000) then
            printIfRunning('\ar[Postmaster]\ax still not near ' .. name .. ' - stopping. Get to them, then run again.')
            return false
        end
        print('\ag[Postmaster]\ax near ' .. name .. ' - continuing.')
        return true
    end

    -- One walk: fire the nav and watch it until it ends. Returns (pinned, ended) - `pinned` true means the
    -- character stayed caught on something after every nudge below, `ended` false means a timeout.
    --
    -- Checks tryErudinGem and the guard proximity watch on every poll while nav is still active - same
    -- shape as halasExitWatch, catches a guard that comes into range mid-walk, not just whatever was
    -- nearby at the start.
    --
    -- STUCK WATCH (v2.25). Nav can leave a character pressed against a counter, a bar or a table it
    -- cannot get past, and before this the wait just sat there until its three-minute timeout. A player
    -- (2026-09-25) found the manual cure: duck a few times, or pause and shuffle them about. So: nav
    -- still running, not paused, and the character has moved under 2 units in 4 seconds -> pause, duck
    -- and stand (and from the second try, step back a pace), resume. Three tries per NPC, then hand over.
    local nudges = 0
    local function walk(timeoutMs)
        mq.cmdf('/nav id %d distance=%d log=off', id, tuning.npcStop)
        mq.delay(500)   -- let pathing engage before we watch Navigation.Active
        local ax, ay, az = mq.TLO.Me.X() or 0, mq.TLO.Me.Y() or 0, mq.TLO.Me.Z() or 0
        local since, lastPoll = mq.gettime(), mq.gettime()
        local pinned = false
        local ended = waitUntil(function()
            if watchErudinGem then tryErudinGem() end
            if watchGuards and guardNearby() then ensureInvisBuff() end
            if not mq.TLO.Navigation.Active() then return true end
            local now = mq.gettime()
            local x, y, z = mq.TLO.Me.X() or 0, mq.TLO.Me.Y() or 0, mq.TLO.Me.Z() or 0
            -- The stuck clock only runs across ordinary back-to-back polls of an unpaused walk. A long gap
            -- between polls means something else held the loop (a cast, the Erudin gem nudge, a stealth
            -- check), and a pause is the player's own - neither is the character being stuck.
            if mq.TLO.Navigation.Paused() or now - lastPoll > 750
                or math.sqrt((x - ax) ^ 2 + (y - ay) ^ 2 + (z - az) ^ 2) > 2 then
                ax, ay, az, since = x, y, z, now
            elseif now - since > 4000 then
                if nudges >= 3 then
                    pinned = true
                    return true
                end
                nudges = nudges + 1
                print(string.format('\ay[Postmaster]\ax caught on something on the way to %s - working free (%d/3)...', name, nudges))
                mq.cmd('/nav pause')   -- safe here: nav is active, which is the only time a pause is accepted
                mq.cmd('/keypress duck')
                mq.delay(500)
                if mq.TLO.Me.Ducking() then mq.cmd('/keypress duck') end
                if nudges > 1 then
                    mq.cmd('/keypress back hold')
                    mq.delay(600)
                    mq.cmd('/keypress back')
                end
                mq.cmd('/nav pause off')
                -- Active can read false around a pause, and the very next poll would take that as "nav
                -- finished" and hand the NPC over from the far side of the counter. Let it come back first.
                mq.delay(1000, function() return mq.TLO.Navigation.Active() == true end)
                ax, ay, az, since = mq.TLO.Me.X() or 0, mq.TLO.Me.Y() or 0, mq.TLO.Me.Z() or 0, mq.gettime()
            end
            lastPoll = mq.gettime()
            return false
        end, timeoutMs, 200)
        return pinned, ended
    end

    ensureMovementBuff()
    -- 180s covers a long run across a huge zone (e.g. West Karana zone-in -> the fishing village).
    local pinned, ended = walk(180000)
    if not ended then
        -- A walk broken off by the combat flee did not "time out" - the flee has already said what happened.
        if not justFledCombat then printIfRunning('\ar[Postmaster]\ax nav to ' .. name .. ' timed out.') end
        return false
    end
    -- Nav reports "done" even when it never found a path (mesh gap - e.g. the Kelethin lifts leave the
    -- treetop NPCs off the ground mesh). Verify we actually arrived; if not, assist: AL rides/walks the
    -- last bit and we resume on proximity. Also fixes the old silent "say from across the zone" failure.
    if not pinned and farFrom(30) then
        -- In Kelethin the gap is usually the ground->platform lift. Try the FELE2 auto-ride, then re-nav.
        if (mq.TLO.Zone.ShortName() or "") == "gfaydark" and rideKelethinLift() then
            pinned = walk(120000)
        end
        -- Nav can silently whiff right after a scripted position change (e.g. stepping off the Halas
        -- shuttle) - the mesh isn't "warm" yet and /nav id reports done almost instantly with no real
        -- path, so the character never moves at all. Field-confirmed: a bare re-fire moments later just
        -- works, no genuine gap involved - cheap to try before assuming one and asking AL to close it.
        if not pinned and farFrom(30) then
            mq.delay(1000)
            pinned = walk(180000)
        end
    end
    -- Pinned: re-firing the same nav would walk straight back into the same snag, so go straight to the
    -- hand-over. The bar is the stop distance itself (plus a hair for rounding), not the looser 30 used
    -- for a mesh gap - pinned against a counter can already be inside 30 while still out of reach.
    if pinned then
        mq.cmd('/nav stop')
        print('\ay[Postmaster]\ax stuck on the way to ' .. name .. ' and could not work free. '
            .. 'Walk them up to ' .. name .. '; I will continue when you are close.')
        return waitForPlayer(tuning.npcStop + 1)
    end
    -- Still short (more platforms/bridges, or lift unavailable) -> assist: AL closes the gap.
    if farFrom(30) then
        print('\ay[Postmaster]\ax cannot auto-reach ' .. name .. ' (nav gap - e.g. a Kelethin lift). '
            .. 'Ride/walk up to them; I will continue when you are close.')
        return waitForPlayer(30)
    end
    return true
end

local function sayPhrase(name, phrase)
    local id = mq.TLO.Spawn("npc " .. name).ID() or 0
    if id == 0 then
        print('\ar[Postmaster]\ax cannot speak to (not found): ' .. name)
        return false
    end
    mq.cmdf('/target id %d', id)
    mq.delay(300)
    if (mq.TLO.Target.ID() or 0) ~= id then
        print('\ar[Postmaster]\ax could not target ' .. name)
        return false
    end
    local droppedInvis = dropInvisForInteraction()
    mq.cmd('/say ' .. phrase)   -- concat (not cmdf) so a stray % in a phrase can't break formatting
    if droppedInvis then ensureInvisBuff() end
    return true
end

-- Class-specific CWTN combat-automation plugins (MQ2Mage, MQ2War, MQ2Necro, etc.) - the pause command
-- itself is shared across the whole family ("/CWTN pause on/off"), just need to know if ANY is loaded
-- for this class first (pattern adapted from pppoker's cwtnPluginNamesForClass - AL: "we have worked on
-- CWTN/RGMercs/KA before to pause them on other scripts").
-- SHD's plugin is MQ2EsKay - it reads as "S.K." - and no MQ2ShadowKnight.dll exists, so the old
-- spelling left IsLoaded() always false and a Shadowknight was never actually paused.
local CWTN_PLUGIN_NAMES = {
    BRD = "MQ2Bard", BST = "MQ2Bst", BER = "MQ2Berserker", CLR = "MQ2Cleric", DRU = "MQ2Druid",
    ENC = "MQ2Enchanter", MAG = "MQ2Mage", MNK = "MQ2Monk", NEC = "MQ2Necro", PAL = "MQ2Paladin",
    RNG = "MQ2Ranger", ROG = "MQ2Rogue", SHD = "MQ2EsKay", SHM = "MQ2Shaman",
    WAR = "MQ2Warrior", WIZ = "MQ2Wizard",
}

local function cwtnPaused()
    local ok, v = pcall(function() return mq.TLO.CWTN.Paused() end)
    if ok then return v end
    return nil
end

-- Pauses the character's own CWTN plugin if one is loaded and not already paused. Returns the class
-- short name - which is the plugin's command prefix - when THIS call paused it, so the caller can
-- unpause the same way. Never touches a pause the user set themselves. Deliberately narrow (just
-- around one retry attempt, not the whole run) - the High Keep gnoll pack is a real death risk
-- during travel, so CWTN stays active everywhere else for auto-defense.
-- The command is "/<class short name> pause on", NOT "/CWTN pause on". The CWTN plugins install
-- "/cwtn" as an ALIAS for "/dgge /docommand /${Me.Class.ShortName}", written into the [Aliases]
-- section of MacroQuest.ini when the plugin loads, and /dgge is DanNet group execute EXCLUDING
-- yourself. So the old spelling paused every box in the group except the one whose casting was
-- interrupting the give window, and did nothing at all for a character running solo. The plugin's
-- own pause button sends "/<short> pause on", and so does this.
-- nosave: without it the plugin writes "pause=on" into [General] of its per-character config, so a
-- run that ends before the unpause leaves the character starting paused in a later session with
-- nothing on screen to say why.
local function pauseCwtnIfLoaded()
    local short = (mq.TLO.Me.Class.ShortName() or ""):upper()
    local pluginName = CWTN_PLUGIN_NAMES[short]
    if not pluginName or not mq.TLO.Plugin(pluginName).IsLoaded() then return false end
    if cwtnPaused() == true then return false end
    mq.cmdf('/%s pause on nosave', short)
    return short
end

-- Opens the give/trade window after an item is already on the cursor and the NPC is targeted. Retries
-- once, pausing CWTN first, if it doesn't open the first time. Field case (AL, 2026-08-07): a delivery
-- run gave 3 clean successes in a row via this identical sequence, then failed once with "give window
-- did not open" - matches a CWTN class plugin (MQ2Mage/MQ2War/MQ2Necro/etc) interrupting the click with
-- a cast at a bad moment, not a logic bug in the give sequence itself.
-- Also drops/reapplies invis around the click (covers giveItem/giveItemsById/giveItems automatically,
-- one shared touch point instead of three) - opening the window needs the NPC to notice you, same as
-- a hail/say. EXCEPT with `keepHidden` (v2.37): a hidden trade to a hostile NPC must not /makemevisible -
-- Hide very likely counts as invisibility here, and dropping it is what gets the character attacked.
local function openGiveWindow(keepHidden)
    local droppedInvis = not keepHidden and dropInvisForInteraction()
    mq.cmd('/click left target')
    local opened
    if waitUntil(function()
        return mq.TLO.Window("GiveWnd").Open() or mq.TLO.Window("TradeWnd").Open()
    end, 5000) then
        opened = true
    else
        local pausedCwtn = pauseCwtnIfLoaded()
        dbg('give window did not open - retrying' .. (pausedCwtn and ' with CWTN paused' or '') .. '...')
        mq.cmd('/click left target')
        opened = waitUntil(function()
            return mq.TLO.Window("GiveWnd").Open() or mq.TLO.Window("TradeWnd").Open()
        end, 5000)
        if pausedCwtn then mq.cmdf('/%s pause off nosave', pausedCwtn) end
    end
    if droppedInvis then ensureInvisBuff() end
    return opened
end

-- Hand an inventory item to a targeted NPC. NPC hand-ins open GiveWnd (GVW_Give_Button);
-- TradeWnd is a fallback. Window/child names to be confirmed in-field. `keepHidden` passes through to
-- openGiveWindow (v2.37 - the hidden trade, see approachAndInteract).
local function giveItem(itemName, npcName, keepHidden)
    local id = mq.TLO.Spawn("npc " .. npcName).ID() or 0
    if id == 0 then
        print('\ar[Postmaster]\ax cannot give to (not found): ' .. npcName)
        return false
    end
    mq.cmdf('/target id %d', id)
    mq.delay(300)
    mq.cmdf('/shift /itemnotify "%s" leftmouseup', itemName)   -- pick the item up to cursor
    mq.delay(600)
    if mq.TLO.Cursor.Name() ~= itemName then
        print('\ar[Postmaster]\ax could not pick up ' .. itemName)
        return false
    end
    if not openGiveWindow(keepHidden) then
        print('\ar[Postmaster]\ax give window did not open')
        if (mq.TLO.Cursor.ID() or 0) > 0 then mq.cmd('/autoinventory') end
        return false
    end
    mq.delay(500)
    if mq.TLO.Window("GiveWnd").Open() then
        mq.cmd('/notify GiveWnd GVW_Give_Button leftmouseup')
    else
        mq.cmd('/nomodkey /itemnotify trade leftmouseup')
        mq.delay(300)
        mq.cmd('/notify TradeWnd TRDW_Trade_Button leftmouseup')
    end
    mq.delay(1000)
    return true
end

-- Picking up by EXACT item id, not name (was giveItemById, one item a trade, until v2.54): identically named but
-- distinct items (postal letters - confirmed 2026-08-05 by AL: same display name, different item IDs) can be held
-- at once. By inventory slot: field-confirmed (AL) ItemSlot2 == -1 means the item sits directly in a top-level
-- bag slot (bare "/itemnotify <ItemSlot>"); ItemSlot2 >= 0 means it is inside a sub-container at that sub-slot,
-- MQ's "packN" convention (packN = ItemSlot - 22, the main bag slots being 23-32). The Cursor.ID() check after
-- each pickup is the hard safety net: if the slot math is ever wrong, it fails loudly, never gives the wrong item.
-- Several EXACT items (by item id - letters that share a name, e.g. four "Bardic Letter (Qeynos)") to one NPC in
-- ONE trade, up to the give window's four slots (v2.54). Each is picked up by its own inventory slot (above) and
-- must leave the cursor into its give slot before the next is picked up - the slot filling is giveItems'
-- field-proven GVW_MyItemSlotN sequence. Returns true once Give was pressed; the caller judges each item by its own
-- id leaving the bags.
local function giveItemsById(ids, npcName, keepHidden)
    local npcSpawnId = mq.TLO.Spawn("npc " .. npcName).ID() or 0
    if npcSpawnId == 0 then
        print('\ar[Postmaster]\ax cannot give to (not found): ' .. npcName)
        return false
    end
    mq.cmdf('/target id %d', npcSpawnId)
    mq.delay(300)
    local function abandon()
        if mq.TLO.Window("GiveWnd").Open() then mq.cmd('/notify GiveWnd GVW_Cancel_Button leftmouseup') end
        mq.delay(500)
        if (mq.TLO.Cursor.ID() or 0) > 0 then mq.cmd('/autoinventory') end
        return false
    end
    local placed = 0
    for _, itemId in ipairs(ids) do
        if placed >= 4 then break end
        local item = mq.TLO.FindItem(itemId)
        if (item.ID() or 0) > 0 then
            local slot1, slot2 = item.ItemSlot(), item.ItemSlot2()
            if slot2 and slot2 >= 0 then
                mq.cmdf('/shift /itemnotify in pack%d %d leftmouseup', slot1 - 22, slot2 + 1)
            else
                mq.cmdf('/shift /itemnotify %d leftmouseup', slot1)
            end
            mq.delay(600)
            if (mq.TLO.Cursor.ID() or 0) ~= itemId then
                print('\ar[Postmaster]\ax could not pick up the correct item (id ' .. tostring(itemId) .. ', got '
                    .. tostring(mq.TLO.Cursor.ID()) .. ') - cancelling the trade.')
                return abandon()
            end
            if placed == 0 then
                if not openGiveWindow(keepHidden) then
                    print('\ar[Postmaster]\ax give window did not open')
                    return abandon()
                end
            else
                mq.cmdf('/notify GiveWnd GVW_MyItemSlot%d leftmouseup', placed)
            end
            if not waitUntil(function() return (mq.TLO.Cursor.ID() or 0) == 0 end, 2000, 100) then
                print('\ar[Postmaster]\ax item ' .. tostring(itemId) .. ' did not go into the give window - cancelling the trade.')
                return abandon()
            end
            placed = placed + 1
            mq.delay(200)
        end
    end
    if placed == 0 or not mq.TLO.Window("GiveWnd").Open() then return abandon() end
    mq.cmd('/notify GiveWnd GVW_Give_Button leftmouseup')
    mq.delay(1000)
    return true
end

-- Hand MULTIPLE items to a targeted NPC in one give window (e.g. Full box + List of Debtors) - the window
-- has four slots, GVW_MyItemSlot0-3 (the game's EQUI_GiveWnd.xml). Proven in the field on Vicus's two items.
-- The same name may be listed more than once, to hand over several stacks: MQ's name lookup searches the
-- cursor and the bags only, so a stack already in the give window is not found again - the next pickup by
-- name takes the NEXT stack (MQ2Utilities.cpp, FindItemByName). `keepHidden` as in giveItem (v2.43).
-- v2.43: each item must actually LEAVE the cursor into its slot before the next is picked up - a pickup by
-- name looks at the cursor first, so a stack left there would be picked "again" and the window would jam.
local function giveItems(itemNames, npcName, keepHidden)
    local id = mq.TLO.Spawn("npc " .. npcName).ID() or 0
    if id == 0 then
        print('\ar[Postmaster]\ax cannot give to (not found): ' .. npcName)
        return false
    end
    mq.cmdf('/target id %d', id)
    mq.delay(300)
    local placed = 0   -- items actually placed into the give window (silently skips ones we lack)
    for _, itemName in ipairs(itemNames) do
        if (mq.TLO.FindItem("=" .. itemName).ID() or 0) > 0 then
            mq.cmdf('/shift /itemnotify "%s" leftmouseup', itemName)   -- item to cursor
            mq.delay(600)
            if mq.TLO.Cursor.Name() ~= itemName then
                print('\ar[Postmaster]\ax could not pick up ' .. itemName)
                if (mq.TLO.Cursor.ID() or 0) > 0 then mq.cmd('/autoinventory') end
                return false
            end
            if placed == 0 then
                if not openGiveWindow(keepHidden) then
                    print('\ar[Postmaster]\ax give window did not open')
                    if (mq.TLO.Cursor.ID() or 0) > 0 then mq.cmd('/autoinventory') end
                    return false
                end
            else
                mq.cmdf('/notify GiveWnd GVW_MyItemSlot%d leftmouseup', placed)   -- next give slot
            end
            if not waitUntil(function() return (mq.TLO.Cursor.ID() or 0) == 0 end, 2000, 100) then
                print('\ar[Postmaster]\ax ' .. itemName .. ' did not go into the give window - cancelling the trade.')
                if mq.TLO.Window("GiveWnd").Open() then mq.cmd('/notify GiveWnd GVW_Cancel_Button leftmouseup') end
                mq.delay(500)
                if (mq.TLO.Cursor.ID() or 0) > 0 then mq.cmd('/autoinventory') end
                return false
            end
            placed = placed + 1
            mq.delay(200)
        end
    end
    if placed == 0 then
        print('\ar[Postmaster]\ax nothing to give - none of the items are in inventory.')
        return false
    end
    if mq.TLO.Window("GiveWnd").Open() then
        mq.cmd('/notify GiveWnd GVW_Give_Button leftmouseup')
        mq.delay(1000)
        return true
    end
    return false
end

-- The Tax Collection Box is a container - it must sit in a MAIN general slot (23-32), not inside
-- a bag, for the quest to work. These helpers detect that and (like PetGear) move it if they can.
local function boxInBag()
    local box = mq.TLO.FindItem("=" .. items.box)
    if (box.ID() or 0) == 0 then return false end
    return (box.ItemSlot2() or -1) >= 0   -- -1 = loose in a main slot; >=0 = inside a bag
end

local function freeMainPack()
    for i = 1, (mq.TLO.Me.NumBagSlots() or 10) do
        if (mq.TLO.Me.Inventory("pack" .. i).ID() or 0) == 0 then return i end
    end
    return nil
end

local function moveBoxToMainSlot()
    if not boxInBag() then return true end
    local pack = freeMainPack()
    if not pack then
        print('\ar[Postmaster]\ax no free MAIN inventory slot for the box - unbag an item, then retry.')
        return false
    end
    mq.cmdf('/shift /itemnotify "%s" leftmouseup', items.box)   -- box to cursor
    mq.delay(600)
    if mq.TLO.Cursor.Name() ~= items.box then
        print('\ar[Postmaster]\ax could not pick up the box to move it.')
        return false
    end
    mq.cmdf('/itemnotify pack%d leftmouseup', pack)            -- into the free main slot
    mq.delay(600)
    if (mq.TLO.Cursor.ID() or 0) > 0 then mq.cmd('/autoinventory') end
    return not boxInBag()
end

-- THE SCRIPT NEVER CHANGES A PLAYER'S BIND. It used to walk anyone not bound in PoK to Soulbinder Jera and
-- rebind them there - once, silently, and permanently. A player who keeps every character bound in the
-- Guild Lobby (a perfectly good bind for this quest) asked whether the script could at least put the old
-- bind back afterwards. It cannot in general - a bind can be almost anywhere - so the honest fix is to
-- leave the bind alone.
--
-- What changes instead is which Gate tiers fire. Gate AA, the Gate spell, the Philter and the Vial land at
-- the bind, so tryGate() uses them only while zones.boundAtHub(). Drunkard's Stein (PoK), Zueria Slide (a
-- wizard spire) and Throne of Heroes (the Guild Lobby) do not depend on bind, so they still fire. This
-- only SPEAKS, once per run, and only when the bind actually costs this character a tier it owns - a
-- melee with no Gate and no Philter or Vial loses nothing and hears nothing.
checkBind = function()
    if bindNoted or zones.boundAtHub() then return end
    local ownsBindTier = (mq.TLO.Me.AltAbility("Gate").ID() or 0) > 0
        or (mq.TLO.Me.Book("Gate")() or 0) > 0
        or (mq.TLO.FindItem("=Philter of Major Translocation").ID() or 0) > 0
        or (mq.TLO.FindItem("=Vial of Swirling Smoke").ID() or 0) > 0
    if not ownsBindTier then return end
    bindNoted = true
    print('\ay[Postmaster]\ax you are bound in ' .. (mq.TLO.Me.ZoneBound.Name() or 'another zone')
        .. ' - Gate, the Philter and the Vial all land at your bind, so they are skipped. Your bind is'
        .. ' left alone; bind in the Plane of Knowledge or the Guild Lobby to use them.')
end

-- Spirit Shroud Selection window - Shroudkeeper Hyush, PoK (Y=257.00, X=152.00, Z=-129.06, field-
-- captured 2026-08-11). Hailing a Shroudkeeper in normal (non-shrouded) form opens a real window
-- (ProgressionSelectionWnd), not a say-phrase dialogue like every other NPC interaction in this script -
-- a 3-level drill-down: ProgressionList (creature category, e.g. "Goblinoid"), ProgressionBranchList
-- (specific form within it, e.g. "Goblin Rogue"), ProgressionStepList (level tier, capped at the
-- character's real level, hard max 70). Uses the same `List[=name,col]` search-by-text member already
-- proven on FactionWnd instead of a guessed row index.
-- Level tier: FIELD-CORRECTED (AL, 2026-08-11) - a real v1.29 test on a level 52 character landed at
-- level 5, not 50. The original assumption (leave it at whatever the window pre-highlights by default,
-- based on AL's own field-capture screenshot appearing to show a sensible default) was wrong - the
-- window just defaults to the lowest/first tier when nothing in ProgressionStepList is explicitly
-- selected. Tiers run every 5 levels, 5 through 70 (AL, direct confirmation) - now computed and searched
-- by exact value (floor to the nearest 5, capped at 70) instead of trusting a default.
local function getGoblinRogueShroud()
    if mq.TLO.Me.Shrouded() then return true end
    if (mq.TLO.Zone.ShortName() or "") ~= zones.pokShort then
        mq.cmd('/travelto ' .. zones.pokShort)
        if not waitWhileProgressing(function() return (mq.TLO.Zone.ShortName() or "") == zones.pokShort end, 20000, 300000) then
            printIfRunning('\ar[Postmaster]\ax could not reach PoK to get a shroud - travel there manually, then run again.')
            return false
        end
        mq.delay(2000)
    end
    if not navToNpc("Shroudkeeper Hyush") then
        printIfRunning('\ar[Postmaster]\ax could not reach Shroudkeeper Hyush - approach manually, then run again.')
        return false
    end
    mq.cmdf('/target id %d', mq.TLO.Spawn("npc Shroudkeeper Hyush").ID() or 0)
    mq.delay(300)
    mq.cmd('/hail')
    if not waitUntil(function() return mq.TLO.Window('ProgressionSelectionWnd').Open() end, 10000, 200) then
        printIfRunning('\ar[Postmaster]\ax Spirit Shroud window did not open - hail Shroudkeeper Hyush manually.')
        return false
    end

    local categoryRow = mq.TLO.Window('ProgressionSelectionWnd/ProgressionList').List('=Goblinoid', 1)() or 0
    if categoryRow == 0 then
        printIfRunning('\ar[Postmaster]\ax "Goblinoid" not found in the Spirit Shroud category list.')
        return false
    end
    mq.cmdf('/notify ProgressionSelectionWnd ProgressionList listselect %d', categoryRow)
    mq.delay(500)

    local formRow = mq.TLO.Window('ProgressionSelectionWnd/ProgressionBranchList').List('=Goblin Rogue', 1)() or 0
    if formRow == 0 then
        printIfRunning('\ar[Postmaster]\ax "Goblin Rogue" not found in the Spirit Shroud form list.')
        return false
    end
    mq.cmdf('/notify ProgressionSelectionWnd ProgressionBranchList listselect %d', formRow)
    mq.delay(500)

    -- Pick the HIGHEST available tier (AL: "we are supposed to pick whatever max we can"), not whatever
    -- the window defaults to. Every 5 levels, 5-70 - floor the character's real level to the nearest 5.
    -- FIELD-CONFIRMED (AL, 2026-08-11, screenshot): ProgressionStepList is two columns, "Monster"
    -- (always "Goblin Rogue" - col 1) and "Level" (the actual number - col 2), NOT a single-column list
    -- like FactionWnd/ProgressionList/ProgressionBranchList. v1.30's bug searched col 1 for a number
    -- that only ever appears in col 2 - always came back not-found regardless of target level.
    local targetTier = math.min(70, math.floor((mq.TLO.Me.Level() or 5) / 5) * 5)
    local tierRow = mq.TLO.Window('ProgressionSelectionWnd/ProgressionStepList').List('=' .. tostring(targetTier), 2)() or 0
    if tierRow == 0 then
        printIfRunning('\ar[Postmaster]\ax level ' .. targetTier .. ' not found in the Spirit Shroud step list.')
        return false
    end
    mq.cmdf('/notify ProgressionSelectionWnd ProgressionStepList listselect %d', tierRow)
    mq.delay(500)

    mq.cmd('/notify ProgressionSelectionWnd ProgressionTemplateSelectAcceptButton leftmouseup')

    if not waitUntil(function() return mq.TLO.Me.Shrouded() end, 30000, 500) then
        printIfRunning('\ar[Postmaster]\ax Goblin Rogue shroud did not take - verify in-game.')
        return false
    end
    print('\ag[Postmaster]\ax now shrouded as a level ' .. targetTier .. ' Goblin Rogue.')
    return true
end

-- Gate condition for the whole Shroud Strategy - evil race AND below tuning.shroudLevel (reasoning
-- at tuning.shroudLevel) - same "run once early" hook as ensureMovementBuff/checkBind above.
-- `force` (v2.46): the Faction tab's hidden give needs the shroud whatever the Settings box says - it is the
-- only way to hand a hostile NPC anything. Every other caller respects state.autoShroud.
ensureShroud = function(force)
    if not factionRisk then return true end
    if not force and not state.autoShroud then return true end
    if automation.noShroud then return true end   -- the Faction tab is buying/banking as yourself first
    if (mq.TLO.Me.Level() or 0) >= tuning.shroudLevel then return true end
    if mq.TLO.Me.Shrouded() then return true end
    -- v2.29: the shroud tiers start at level 5 (see getGoblinRogueShroud), so a level 1-4 character has
    -- nothing to pick. Before this check it tried anyway on EVERY trip between zones - a detour to PoK, a
    -- hail, "level 0 not found" - and then travelled on unshrouded regardless. Found building the Faction
    -- tab, for a brand-new level 1 Iksar test character.
    if (mq.TLO.Me.Level() or 0) < 5 then
        if not shroudTooLowNoted then
            shroudTooLowNoted = true
            print('\ay[Postmaster]\ax level ' .. (mq.TLO.Me.Level() or 0) .. ' is too low for a Goblin Rogue shroud'
                .. ' (they start at level 5) - travelling as yourself, with no stealth protection.')
        end
        return true
    end
    return getGoblinRogueShroud()
end

-- Gate pipeline (TRAVEL_REFERENCE.md "Gate Pipeline"): AA -> spell -> Drunkard's Stein -> Zueria Slide
-- -> Throne of Heroes AA -> Philter of Major Translocation -> Vial of Swirling Smoke -> give up. One
-- unified chain, not a separate caster/melee branch - a caster's Gate AA/spell almost always resolves at
-- the first two checks; melee (no Gate AA/spell) naturally falls through to the item/Throne tiers, same
-- real-world result as the two documented orders without hardcoding by class.
-- Every method here lands the character AT PoK (Stein) or somewhere CLOSE to it (bind point via Gate AA/
-- spell/Philter/Vial - those four ONLY while the bind is PoK or the Guild Lobby, see zones.boundAtHub() -
-- Guild Lobby via Throne, a wizard spire via Zueria Slide) - callers don't need to
-- know or care which fired, since the existing "/travelto zones.pokShort" step right after any tryGate() call
-- finishes the hop from wherever it landed (AL, 2026-08-08: "Gate gets us to PoK, one way or another").
-- Excludes 5/10-dose Gate potions (TRAVEL_REFERENCE.md: TLP-only, not on Live) and a Mirao purchase step
-- (buying happens during an unrelated PoK visit, not reactively while stuck somewhere that isn't PoK).
-- Best-effort: returns true only if something was actually activated; the caller waits for the zone to
-- change (Zueria Slide's 20s cast and Philter's 10s cast mean this can take a while to even return).
-- v1.54: the AA/spell tiers used to return true the instant the command fired - a flat 1000ms delay,
-- nowhere near a real Gate cast time, with no check that anything actually happened. AL, 2026-08-15
-- (non-shrouded character, leaving Halas): "we tried gate (was a spell)... we did not let the gate
-- finish and started to run to zone... I expected to get back on the shuttle, but instead character
-- jumped in the water." Root cause: `tryGate()` claimed success mid-cast, so travelToZone's Halas-exit
-- block treated Gate as having worked and skipped its shuttle fallback entirely - then immediately moved
-- on to the next travel step, which INTERRUPTS an in-progress cast in EQ. Gate never landed, and with the
-- fallback already disarmed, the character just fell through to plain nav's default lake-crossing
-- behavior (not old retired code coming back - that's just what happens when nothing intervenes to
-- prefer the shuttle). Both tiers now wait for the real effect (cast time for the spell, matching the
-- proven pattern in memorizeAndCastSpell) and verify an ACTUAL ZONE CHANGE before claiming success -
-- Gate's whole point is a zone change, so that's the one confirmation that can't be faked.
-- Can we Gate this instant? AA first, then a memorised spell. ONE definition - this test used to be
-- written out inline at each decision point, and every new travel path that forgot to copy it silently
-- lost Gate. Callers need it separately from tryGate() because it decides ROUTING (skip the long walk
-- entirely), not merely whether an attempt would succeed.
-- Only true while bound in PoK or the Guild Lobby: from any other bind, Gate would send the character
-- somewhere unhelpful, and routing must not skip the walk on the strength of it.
-- The third clause is the fix for casters who own Gate but keep their gems full of combat spells - the
-- normal state. Before it, "Gate is in a gem" was the only spell test, nothing ever memorized it, and such
-- a caster ran every long haul on foot.
gateIsReady = function()
    if not zones.boundAtHub() then return false end
    return ((mq.TLO.Me.AltAbility("Gate").ID() or 0) > 0 and mq.TLO.Me.AltAbilityReady("Gate")())
        or ((mq.TLO.Me.Gem("Gate")() or 0) > 0 and mq.TLO.Me.SpellReady("Gate")())
        or ((mq.TLO.Me.Gem("Gate")() or 0) == 0 and (mq.TLO.Me.Book("Gate")() or 0) > 0)
end

tryGate = function()
    local startZone = mq.TLO.Zone.ID() or 0
    local atHub = zones.boundAtHub()   -- gates the four tiers that land at the bind
    local gateAA = mq.TLO.Me.AltAbility("Gate")
    if atHub and (gateAA.ID() or 0) > 0 and mq.TLO.Me.AltAbilityReady("Gate")() then
        mq.cmdf('/alt activate %d', gateAA.ID())
        waitUntil(function() return (mq.TLO.Zone.ID() or 0) ~= startZone end, 10000, 200)
        return (mq.TLO.Zone.ID() or 0) ~= startZone
    end
    if atHub and (mq.TLO.Me.Gem("Gate")() or 0) > 0 and mq.TLO.Me.SpellReady("Gate")() then
        mq.cmd('/cast "Gate"')
        local castTime = (mq.TLO.Spell("Gate").CastTime() or 5000) + 3000
        waitUntil(function() return not mq.TLO.Me.Casting() end, castTime, 100)
        waitUntil(function() return (mq.TLO.Zone.ID() or 0) ~= startZone end, 5000, 200)
        return (mq.TLO.Zone.ID() or 0) ~= startZone
    end
    -- In the spellbook but not in a gem: memorize it, then cast. The Book check is the gate that matters -
    -- Spell("Gate") alone only proves the spell exists in the GAME, which is true for a warrior too, and
    -- memorizeAndCastSpell's own guard is that game-level check. Success is the zone changing, the one
    -- confirmation a Gate cannot fake.
    if atHub and (mq.TLO.Me.Gem("Gate")() or 0) == 0 and (mq.TLO.Me.Book("Gate")() or 0) > 0 then
        if memorizeAndCastSpell("Gate", function()
            return waitUntil(function() return (mq.TLO.Zone.ID() or 0) ~= startZone end, 10000, 200)
        end) then
            return true
        end
    end
    local stein = mq.TLO.FindItem("=Drunkard's Stein")
    if (stein.ID() or 0) > 0 and (mq.TLO.Me.Level() or 0) >= 21 and (stein.TimerReady() or 0) == 0 then
        mq.cmdf('/useitem "%s"', stein.Name())
        mq.delay(1000)
        return true
    end
    local slide = mq.TLO.FindItem("Zueria Slide")   -- no "=" - partial match finds any destination variant
    if (slide.ID() or 0) > 0 and (mq.TLO.Me.Level() or 0) >= 105 then
        mq.cmd('/nav pause')
        mq.cmdf('/useitem "%s"', slide.Name())
        mq.delay(21000)   -- 20s cast + margin
        mq.cmd('/nav pause off')
        return true
    end
    local throneAA = mq.TLO.Me.AltAbility("Throne of Heroes")
    if (throneAA.ID() or 0) > 0 and mq.TLO.Me.AltAbilityReady("Throne of Heroes")() then
        mq.cmdf('/alt activate %d', throneAA.ID())
        mq.delay(1000)
        return true
    end
    local philter = mq.TLO.FindItem("=Philter of Major Translocation")
    if atHub and (philter.ID() or 0) > 0 then
        mq.cmd('/nav pause')
        mq.cmdf('/useitem "%s"', philter.Name())
        mq.delay(11000)   -- 10s cast + margin
        mq.cmd('/nav pause off')
        return true
    end
    local vial = mq.TLO.FindItem("=Vial of Swirling Smoke")
    if atHub and (vial.ID() or 0) > 0 then
        mq.cmdf('/useitem "%s"', vial.Name())
        mq.delay(1000)
        return true
    end
    return false
end

-- Generic zone travel, routed through PoK. Escape the neighborhood -> reach PoK -> /travelto dest.
-- Going via the PoK hub uses its books (which reach every city) and avoids boat/island routes that
-- nav can't cross (e.g. Erudin -> Erud's Crossing). Anchored on the target NPC's presence.
local function travelToZone(traveltoArg, anchorNpc)
    if (mq.TLO.Spawn("npc " .. anchorNpc).ID() or 0) > 0 then return true end
    -- No "traveling to <shortname>..." line: EasyFind announces the same trip on the very next
    -- line AND uses the zone's real name, while ours printed the raw shortname - strictly worse
    -- and duplicated. Kept as debug because the SHORTNAME is the useful bit when routing misfires.
    dbg('travelto ' .. traveltoArg)
    ensureMovementBuff()   -- before the /travelto leg starts, not just the last-mile navToNpc walk -
                            -- confirmed both pppoker and Astone apply their movement buff here too
                            -- (2026-08-09), not only during the final NPC approach.
    ensureShroud()   -- AL, 2026-08-11: "Run next batch" went straight to Erudin without shrouding first -
                      -- travelToSunriseHills was the ONLY hook point, but pickupOnly/deliverOnly/Vicus/
                      -- Flynn/tax-merchant travel all go through travelToZone directly and never touch
                      -- travelToSunriseHills. Same fix shape as ensureMovementBuff right above.
    ensureHealed()   -- same multi-hook-point reasoning - heal up here too if this leg happens to start
                      -- from a safe hub zone, not only when travelToSunriseHills was the entry point.
    checkBind()   -- same reasoning again: a delivery batch never passes through travelToSunriseHills,
                   -- so without this a caster bound elsewhere would run every leg with no word why.

    -- 0. leaving Kelethin from up on the platform? Ride the lift DOWN ourselves first so EasyFind's
    --    /travelto doesn't run us onto a moving platform and off the side (field: it clicked mid-run).
    if (mq.TLO.Zone.ShortName() or "") == "gfaydark" and (mq.TLO.Me.Z() or 0) > kelethin.topZ - 20 then
        descendKelethinLift()
    end

    -- Leaving Halas (not just navving to Marton within it)? Try riding the shuttle back first (AL:
    -- "same routing in reverse to leave Halas"). If that fails for any reason, watchHalasExit's
    -- halasExitWatch (hooked into both the direct-travel and PoK-hub waits below) is still the
    -- fallback - unaffected either way since it only ever does anything if Me.FeetWet is genuinely
    -- true. Deliberately allowed to re-fire on every poll (v0.72's one-shot guard was REMOVED - it
    -- broke a working v0.71: a single climb attempt doesn't always fully clear the ledge, and
    -- re-polling gave it another push on the next second. Me.FeetWet already guards against
    -- re-running once genuinely out of the water.)
    -- Gate-ready character? Try Gate BEFORE bothering with the shuttle/swim - Gate bypasses the whole
    -- lake crossing outright, so there's no reason to ride it first. (AL, 2026-08-10: "we did not gate,
    -- we did attempt to gate on the shuttle though, odd" - the v1.21 gate-before-direct-travel fix only
    -- touched step 2 below; this Halas-specific exit block never got the same treatment.)
    local watchHalasExit = (mq.TLO.Zone.ShortName() or "") == "halas" and traveltoArg ~= "halas"
    if watchHalasExit then
        if gateIsReady() and tryGate() then
            watchHalasExit = false
        elseif (mq.TLO.Me.Y() or 0) > -200 then
            rideHalasShuttleOut()
        end
    end

    -- 1. escape the neighborhood if we're in it (gate, else /travelto routes out). 25s (not the old
    -- 12s) - tryGate() can now internally take up to ~21s on its own (Zueria Slide's 20s cast) before
    -- even returning, so the old 12s window would time out on a successful gate that just needed a
    -- little more time to actually land.
    if mq.TLO.Zone.ID() == zones.neighborhood then
        if tryGate() then
            waitUntil(function() return mq.TLO.Zone.ID() ~= zones.neighborhood end, 25000, 500)
        end
        if mq.TLO.Zone.ID() == zones.neighborhood then
            mq.cmd('/travelto ' .. zones.pokShort)
            if not waitUntil(function() return mq.TLO.Zone.ID() ~= zones.neighborhood end, 180000, 2000) then
                printIfRunning('\ar[Postmaster]\ax could not leave the neighborhood - travel out manually, then run again.')
                return false
            end
        end
    end

    -- 1.5. some destinations have a known-bad FULL-path connection (see zoneRule.preferPok) but a short,
    -- targeted 2-hop route sidesteps it without paying the full PoK detour (see zoneRule.viaDirect above).
    -- Tried before falling through to the normal PoK route below; either hop stalling just falls
    -- through to that same proven fallback.
    local viaDirect = zoneRule.viaDirect[traveltoArg]
    if viaDirect and (mq.TLO.Zone.ShortName() or "") ~= zones.pokShort then
        mq.cmd('/travelto ' .. viaDirect)
        local reachedVia = waitWhileProgressing(function()
            if watchHalasExit then halasExitWatch() end
            return (mq.TLO.Zone.ShortName() or "") == viaDirect
        end, 20000, 300000)
        if reachedVia then
            mq.delay(2000)
            -- Second leg: force the exact connection via /easyfind (pppoker's Neriak technique) instead
            -- of a bare /travelto, which picks whichever connection it wants - confirmed broken here
            -- even when computed fresh from this exact zone (v1.02 field test). Wait for the ZONE, not
            -- the anchor NPC - this only needs to get us across the zone line; the caller's own
            -- navToNpc (already invoked right after travelToZone returns) handles the rest, same as
            -- every other destination.
            local forceConn = zoneRule.forceConnection[traveltoArg]
            if forceConn then
                mq.cmd('/squelch /easyfind ' .. forceConn)
            else
                mq.cmd('/travelto ' .. traveltoArg)
            end
            local arrived = waitWhileProgressing(function()
                if watchHalasExit then halasExitWatch() end
                return (mq.TLO.Zone.ShortName() or "") == traveltoArg
            end, 20000, 300000)
            if arrived then return true end
        end
        -- v2.50: a combat flee's own /easyfind is running now - stopping "travel" would cancel THAT.
        if justFledCombat then return false end
        mq.cmd('/easyfind stop')
        mq.cmd('/travelto stop')
        -- A Stop click fails every wait at once - it must end the trip here, never fall through into the
        -- PoK fallback below, which starts by trying Gate.
        if automation.stop then return false end
        dbg('via ' .. viaDirect .. ' to ' .. traveltoArg .. ' didn\'t pan out - falling back to Plane of Knowledge.')
    end

    -- 2. try a DIRECT /travelto first, using progress-based detection instead of a fixed timeout - if
    -- we're already close to the destination (e.g. an adjacent zone, like Everfrost right next to
    -- Halas), this reaches it without ever backtracking through PoK (AL: "might as well go to Halas,
    -- not PoK to start the whole trip back"). Falls through to the proven PoK-hub route below only if
    -- this genuinely stalls - not just because it's a slow multi-hop route. Replaces the narrower
    -- ZONE_SKIP_POK_FROM whitelist approach entirely - this generalizes to any zone, not just Halas.
    -- Destinations in zoneRule.preferPok skip this step outright - direct "succeeds" there too, just via a
    -- known-bad long overland route that progress-detection can't catch (it's real movement, not stuck).
    --
    -- AL, 2026-08-09: "the goal is ALMOST every time PoK to get to the next place... if character is a
    -- caster with Gate, that substantially makes traveling faster... we ran not gated" (Erudin->Halas -
    -- not in zoneRule.preferPok, so direct was tried and "succeeded," just via a slow multi-hop EasyFind
    -- route that never gave Gate a chance to fire - Gate only lived in step 3, the "direct stalled"
    -- fallback). Fix: a Gate-capable character skips straight to step 3 (which already tries Gate before
    -- /travelto zones.pokShort) UNLESS the destination is a confirmed-short adjacent hop (zoneRule.adjacent,
    -- already used for pickup reprioritization - a real confirmed-direct list, not a guess) - keeps the
    -- Halas/Everfrost-style short-hop optimization intact while skipping the slow walk for long hauls.
    local isKnownAdjacent = false
    for _, adj in ipairs(zoneRule.adjacent[mq.TLO.Zone.ShortName() or ""] or {}) do
        if adj == traveltoArg then isKnownAdjacent = true; break end
    end
    if (mq.TLO.Zone.ShortName() or "") ~= zones.pokShort and not zoneRule.preferPok[traveltoArg]
        and (isKnownAdjacent or not gateIsReady()) then
        mq.cmd('/travelto ' .. traveltoArg)
        local arrived = waitWhileProgressing(function()
            if watchHalasExit then halasExitWatch() end
            return (mq.TLO.Spawn("npc " .. anchorNpc).ID() or 0) > 0
        end, 20000, 300000)
        if arrived then return true end
        -- v2.50: a combat flee took over - retryStep brings us back; no stall fallback (it starts with Gate).
        if justFledCombat then return false end
        -- v1.50: don't stop travel if the wait aborted because fleeIfInCombat() just fired - that call
        -- already issued its OWN /travelto zones.pokShort a moment earlier, and stopping "travel" here
        -- actually cancels THAT in-flight flee, not the original (already-abandoned) direct attempt.
        -- Field-confirmed (AL, 2026-08-14): the log showed "[EasyFind] Traveling to: The Plane of
        -- Knowledge" immediately followed by "[EasyFind] /travelto stopped" - this exact line canceling
        -- the flee that had JUST started, forcing a wasted restart via step 3 below.
        if not justFledCombat then
            mq.cmd('/travelto stop')
        end
        if automation.stop then return false end   -- the user's Stop, not a stall: no Gate, no PoK fallback
        dbg('direct travel to ' .. traveltoArg .. ' stalled - routing via Plane of Knowledge instead.')
    end

    -- 3. reach the PoK hub (fallback route). Gate tried first (AL, 2026-08-08: "Gate gets us to PoK,
    -- one way or another" - a single cast/AA/item click is usually faster than a computed /travelto
    -- route). Whatever it lands on - PoK directly (Stein) or close to it (bind/Guild Lobby/a spire) -
    -- the /travelto zones.pokShort block right after finishes the hop if needed; its own guard condition
    -- just skips itself if gate already got us there, so no new fallback logic is needed here.
    -- Wait to LEAVE this zone, not to reach PoK. Throne of Heroes lands in the Guild Lobby, the Slide at a
    -- wizard spire, and a Lobby bind sends Gate to the Lobby - none of them ever becomes PoK, so the old
    -- "== PoK" wait sat out its full 25 seconds after every one of them before the hop below moved on.
    local gatedFrom = mq.TLO.Zone.ID() or 0
    if (mq.TLO.Zone.ShortName() or "") ~= zones.pokShort and tryGate() then
        waitUntil(function() return (mq.TLO.Zone.ID() or 0) ~= gatedFrom end, 25000, 500)
    end
    if (mq.TLO.Zone.ShortName() or "") ~= zones.pokShort then
        -- v1.50: don't re-fire /travelto if we're already mid-flee toward zones.pokShort - fleeIfInCombat()
        -- already issued it. Re-issuing the SAME destination still resets EasyFind's routing progress
        -- from scratch (field-confirmed via repeated "Traveling to: The Plane of Knowledge" restarts in
        -- the same log), so every repeat combat ping was quietly sabotaging a travel that was actually
        -- working.
        if not justFledCombat then
            mq.cmd('/travelto ' .. zones.pokShort)
        end
        if not waitWhileProgressing(function()
            if watchHalasExit then halasExitWatch() end
            return (mq.TLO.Zone.ShortName() or "") == zones.pokShort
        end, 20000, 300000) then
            if justFledCombat then return false end   -- v2.50: the flee took over; retryStep brings us back
            printIfRunning('\ar[Postmaster]\ax could not reach PoK - travel manually, then run again.')
            return false
        end
        -- Reached PoK - any flee-in-progress is now genuinely over (crossing the zone line already reset
        -- aggro), so clear the flag here rather than leaving it stuck true for the rest of the batch.
        -- Without this, fleeIfInCombat's new idempotency (above) would silently ignore a completely
        -- unrelated, later combat encounter elsewhere in the same run.
        justFledCombat = false
        mq.delay(2000)
    end

    -- 4. some destinations aren't PoK-routable directly (East Freeport) - hop via an intermediate zone
    local via = zoneRule.via[traveltoArg]
    if via then
        mq.cmd('/travelto ' .. via)
        if not waitUntil(function() return (mq.TLO.Zone.ShortName() or "") == via end, 180000, 2000) then
            if justFledCombat then return false end   -- v2.50: the flee took over; retryStep brings us back
            printIfRunning('\ar[Postmaster]\ax could not reach ' .. via .. ' (on the way to ' .. traveltoArg .. ') - travel manually.')
            return false
        end
        mq.delay(2000)
    end

    -- 5. travelto the destination (uses that city's PoK book / a zone hop), anchored on the NPC
    mq.cmd('/travelto ' .. traveltoArg)
    if not waitUntil(function()
        return (mq.TLO.Spawn("npc " .. anchorNpc).ID() or 0) > 0
    end, 240000, 2000) then
        if justFledCombat then return false end   -- v2.50: the flee took over; retryStep brings us back
        printIfRunning('\ar[Postmaster]\ax did not reach ' .. anchorNpc .. ' via /travelto ' .. traveltoArg .. ' - travel manually, then run again.')
        return false
    end
    return true
end

local function travelToQeynos()
    return travelToZone(nonad.qeynosTravelto, nonad.vicus)
end

-- Warn BEFORE attempting to receive an item if there isn't room. Field bug (AL, fresh character):
-- getTonic's old success check fired the instant the tonic touched the cursor, before /autoinventory
-- even ran - so a full inventory (item stuck on cursor, no space to stow) was silently reported as
-- success. Same risk applies anywhere else we're about to receive an item into general inventory
-- (the Postmaster's Challenge batching already has its own space precheck - this covers Nonad's).
local function checkInventorySpace(need, itemDesc)
    local free = mq.TLO.Me.FreeInventory() or 0
    if free < need then
        print(string.format('\ar[Postmaster]\ax need %d free inventory slot(s) for %s, only %d free - clear space and try again.', need, itemDesc, free))
        return false
    end
    return true
end

-- GET_TONIC: hail Pagus, ask about his brother, receive the Cough Tonic.
local function getTonic()
    if (mq.TLO.FindItem("=" .. items.tonic).ID() or 0) > 0 then
        print('\ay[Postmaster]\ax you already have the ' .. items.tonic .. '.')
        return true
    end
    if not checkInventorySpace(1, items.tonic) then return false end

    nonadBusy = true

    if mq.TLO.Zone.ID() ~= zones.neighborhood then
        travelToSunriseHills()
    end
    if mq.TLO.Zone.ID() ~= zones.neighborhood then
        print('\ar[Postmaster]\ax could not reach Sunrise Hills - travel there and run again.')
        nonadBusy = false
        return false
    end
    if (mq.TLO.Spawn("npc " .. nonad.pagus).ID() or 0) == 0 then
        print('\ar[Postmaster]\ax in Sunrise Hills but ' .. nonad.pagus .. ' not found - check VoA / instance.')
        nonadBusy = false
        return false
    end

    if not navToNpc(nonad.pagus) then nonadBusy = false; return false end

    mq.cmdf('/target id %d', mq.TLO.Spawn("npc " .. nonad.pagus).ID() or 0)
    mq.delay(300)
    local droppedInvis = dropInvisForInteraction()
    mq.cmd('/hail')
    mq.delay(1200)
    if droppedInvis then ensureInvisBuff() end
    sayPhrase(nonad.pagus, nonad.brotherPhrase)

    -- The tonic may land on the cursor or straight in inventory; accept either, then stow it.
    local got = waitUntil(function()
        return (mq.TLO.FindItem("=" .. items.tonic).ID() or 0) > 0
            or (mq.TLO.Cursor.Name() == items.tonic)
    end, 8000)
    if mq.TLO.Cursor.Name() == items.tonic then
        mq.cmd('/autoinventory')
        mq.delay(500)
    end

    -- "got" only means the tonic touched the cursor - verify it actually left it (stowed), not just
    -- that it briefly appeared, before calling this a success (the bug AL hit: no space -> stuck on
    -- cursor -> old code still reported success).
    if got and mq.TLO.Cursor.Name() == items.tonic then
        print('\ar[Postmaster]\ax received the ' .. itemLink(items.tonic) .. ' but could not stow it - no inventory space. Clear a slot; it is on your cursor.')
        nonadBusy = false
        return false
    end
    if got then
        print('\ag[Postmaster]\ax received the ' .. itemLink(items.tonic) .. ' - next: take it to Vicus in South Qeynos.')
        nonadBusy = false
        return true
    end
    print('\ar[Postmaster]\ax did not receive the ' .. items.tonic .. ' - verify the phrase / faction / Pagus name.')
    nonadBusy = false
    return false
end

-- GIVE_TONIC: hand the Cough Tonic to Vicus in South Qeynos, ask about collections, get the box.
-- Shared: the "ask Vicus for the box + list, stow both, move the box to a main slot" dialogue - used by
-- both giveTonic() (right after handing him a fresh tonic) and the manual "Go to Vicus" shortcut button.
-- AL, 2026-08-14: "As long as Tonic is turned in, Vicus will give both items on the keywords. Since this
-- is an old quest, there is no TLO check to know what step or even a Tonic turn in verify with Vicus. But
-- if we have not finished the quest, the server flag is not made with Vicus, so he will give us what we
-- need, box and list." A fresh tonic in hand is NOT actually required once the one-time turn-in already
-- happened server-side - caller is responsible for travel/nav/inventory-space and being close to Vicus
-- before calling this.
local function requestTaxBoxFromVicus()
    sayPhrase(nonad.vicus, nonad.helpPhrase)

    -- Wait for the box, stow it.
    waitUntil(function()
        return (mq.TLO.FindItem("=" .. items.box).ID() or 0) > 0 or (mq.TLO.Cursor.Name() == items.box)
    end, 8000)
    for _ = 1, 4 do
        if (mq.TLO.Cursor.ID() or 0) == 0 then break end
        mq.cmd('/autoinventory')
        mq.delay(400)
    end
    if mq.TLO.Cursor.Name() == items.box then
        print('\ar[Postmaster]\ax received the ' .. itemLink(items.box) .. ' but could not stow it - no inventory space. Clear a slot; it is on your cursor.')
        return false
    end

    -- Vicus forgets the List of Debtors unless you ask - "What list?" (keyword [list]).
    sayPhrase(nonad.vicus, nonad.listPhrase)
    waitUntil(function()
        return (mq.TLO.FindItem("=" .. items.list).ID() or 0) > 0 or (mq.TLO.Cursor.Name() == items.list)
    end, 5000)
    for _ = 1, 4 do
        if (mq.TLO.Cursor.ID() or 0) == 0 then break end
        mq.cmd('/autoinventory')
        mq.delay(400)
    end
    if mq.TLO.Cursor.Name() == items.list then
        print('\ar[Postmaster]\ax received the ' .. itemLink(items.list) .. ' but could not stow it - no inventory space. Clear a slot; it is on your cursor.')
        return false
    end

    local got = (mq.TLO.FindItem("=" .. items.box).ID() or 0) > 0
    if got then
        moveBoxToMainSlot()   -- the box is a container; the quest needs it in a MAIN slot
        local haveList = (mq.TLO.FindItem("=" .. items.list).ID() or 0) > 0
        print('\ag[Postmaster]\ax got the ' .. items.box .. (haveList and ' + ' .. items.list or ' (no list yet)') .. ' - next: collect taxes.')
        return true
    end
    print('\ar[Postmaster]\ax no tax box yet - verify the help phrase / box name.')
    return false
end

local function giveTonic()
    if (mq.TLO.FindItem("=" .. items.tonic).ID() or 0) == 0 then
        print('\ay[Postmaster]\ax no ' .. items.tonic .. ' - run GET_TONIC first.')
        return false
    end
    -- box + list both land in general inventory before the box gets moved to a main slot
    if not checkInventorySpace(2, items.box .. " + " .. items.list) then return false end

    nonadBusy = true
    if (mq.TLO.Spawn("npc " .. nonad.vicus).ID() or 0) == 0 then
        if not travelToQeynos() then nonadBusy = false; return false end
    end
    -- The tonic goes over, then a say asks for the box. Vicus faces us (faceOk, v2.56): the quest only reaches him
    -- once Antonius Bayle is at least Apprehensive, so he never attacks.
    local ok = approachAndInteract(nonad.vicus, function()
        if not giveItem(items.tonic, nonad.vicus) then return false end
        mq.delay(1000)
        return requestTaxBoxFromVicus()
    end, nil, true)
    nonadBusy = false
    return ok == true
end

-- Manual shortcut (AL's "Go to Vicus" button, 2026-08-14) - skips the tonic entirely, straight to asking
-- for a box + list. Only works if a tonic was already turned in to Vicus at SOME point (server-side flag,
-- no TLO to verify it) - if never turned in, the keyword just won't get a box, same as it always has.
local function getTaxBoxDirect()
    if not checkInventorySpace(2, items.box .. " + " .. items.list) then return false end
    nonadBusy = true
    if (mq.TLO.Spawn("npc " .. nonad.vicus).ID() or 0) == 0 then
        if not travelToQeynos() then nonadBusy = false; return false end
    end
    local ok = approachAndInteract(nonad.vicus, requestTaxBoxFromVicus, nil, true)   -- faces Vicus (v2.56)
    nonadBusy = false
    return ok == true
end

-- COLLECT_TAXES: for each merchant, say "tax collection", take the tax coin off the cursor and
-- store it in the box; check them off as we go. Combine is the next step once all 10 are boxed.
local function boxFull()
    return (mq.TLO.FindItem("=" .. items.fullbox).ID() or 0) > 0
end

local function taxCount()
    local n = 0
    for _, m in ipairs(tax.merchants) do
        if state.taxes[m] then n = n + 1 end
    end
    return n
end

-- Sync the checklist to the box's ACTUAL contents (the box is the source of truth). A merchant is
-- checked iff their tax is currently in the box - so deleting/losing a tax unchecks it, live and on
-- restart. Matches a box item to a merchant by full name / last-name substring (per-merchant tax
-- names, field-confirmed). Only runs while the (uncombined) box exists.
local function syncTaxesFromBox()
    local box = mq.TLO.FindItem("=" .. items.box)
    if (box.ID() or 0) == 0 then return end
    local boxPack = (box.ItemSlot() or 0) - 22
    if boxPack < 1 then return end
    local container = mq.TLO.Me.Inventory("pack" .. boxPack)

    local present = {}
    for j = 1, (container.Container() or 0) do
        local nm = container.Item(j).Name()
        if nm then
            for _, m in ipairs(tax.merchants) do
                local last = m:match("(%S+)$") or ""
                if nm:find(m, 1, true) or (last ~= "" and nm:find(last, 1, true)) then
                    present[m] = true
                    break
                end
            end
        end
    end

    local changed = false
    for _, m in ipairs(tax.merchants) do
        local nowIn = present[m] or false
        if (state.taxes[m] or false) ~= nowIn then
            state.taxes[m] = nowIn
            changed = true
        end
    end
    if changed then saveState() end
end

-- Store the item on the cursor (a tax coin) in the Tax Collection Box's first free slot.
local function putCursorInBox()
    if (mq.TLO.Cursor.ID() or 0) == 0 then return false end
    local boxPack = (mq.TLO.FindItem("=" .. items.box).ItemSlot() or 0) - 22
    if boxPack < 1 then
        print('\ar[Postmaster]\ax box is not in a main slot - cannot store the tax.')
        return false
    end
    -- drop the cursor item into the box's first free slot (if this needs the box OPEN, we add a
    -- rightmouseup here after field-testing).
    for j = 1, (mq.TLO.Me.Inventory("pack" .. boxPack).Container() or 0) do
        if (mq.TLO.Me.Inventory("pack" .. boxPack).Item(j).ID() or 0) == 0 then
            mq.cmdf('/itemnotify in pack%d %d leftmouseup', boxPack, j)
            mq.delay(500)
            break
        end
    end
    return (mq.TLO.Cursor.ID() or 0) == 0
end

-- Collect Sayer's tax straight from Flynn Merrington (North Qeynos) - Mira is skipped.
local function collectViaFlynn()
    dbg('collecting Sayer\'s tax from ' .. tax.flynn .. ' (skipping Mira)...')
    travelToZone(tax.flynnZone, tax.flynn)
    if (mq.TLO.Spawn("npc " .. tax.flynn).ID() or 0) == 0 then
        print('\ar[Postmaster]\ax ' .. tax.flynn .. ' not found - verify name / zone shortname.')
        return false
    end
    -- v2.51: from behind when in invis (AL) - through approachAndInteract.
    local got = approachAndInteract(tax.flynn, function()
        sayPhrase(tax.flynn, tax.flynnPhrase)
        return waitUntil(function() return (mq.TLO.Cursor.ID() or 0) > 0 end, 5000)
    end)
    if got == nil then return false end   -- could not reach him - already said
    if got then return putCursorInBox() end
    print('\ar[Postmaster]\ax no tax from ' .. tax.flynn .. ' - verify the exact phrase.')
    return false
end

-- COMBINE: with all 10 taxes in the box, open it and click Combine -> Full Tax Collection Box.
-- The Full box lands on the CURSOR, so we auto-inventory it (else the later hand-in can't grab it).
local function combineBox()
    local boxPack = (mq.TLO.FindItem("=" .. items.box).ItemSlot() or 0) - 22
    if boxPack < 1 then return false end
    mq.cmdf('/itemnotify pack%d rightmouseup', boxPack)   -- open the box -> ContainerWindow
    if not waitUntil(function() return mq.TLO.Window("ContainerWindow").Open() end, 5000) then
        printIfRunning('\ar[Postmaster]\ax the box did not open for combine.')
        return false
    end
    mq.delay(500)
    mq.cmd('/notify ContainerWindow Container_Combine leftmouseup')
    mq.delay(1500)   -- let the combine resolve
    if (mq.TLO.Cursor.ID() or 0) > 0 then
        mq.cmd('/autoinventory')
        mq.delay(500)
    end
    return waitUntil(boxFull, 5000)
end

local function collectTaxes()
    if boxFull() then
        print('\ay[Postmaster]\ax box already full - return it to Vicus.')
        return true
    end
    if (mq.TLO.FindItem("=" .. items.box).ID() or 0) == 0 then
        print('\ay[Postmaster]\ax no ' .. items.box .. ' - do GIVE_TONIC first.')
        return false
    end

    nonadBusy = true
    if boxInBag() and not moveBoxToMainSlot() then
        print('\ar[Postmaster]\ax the box must sit in a MAIN inventory slot before collecting - fix and retry.')
        nonadBusy = false
        return false
    end
    if (mq.TLO.Spawn("npc " .. nonad.vicus).ID() or 0) == 0 then   -- Vicus = "am I in South Qeynos"
        if not travelToQeynos() then nonadBusy = false; return false end
    end

    for _, m in ipairs(tax.merchants) do
        -- v2.49: stop the moment the flee fires. Before, a tax landed, the room attacked, the flee set off
        -- for PoK - and this loop walked on to the NEXT merchant, whose /nav overrode the flee's /travelto.
        -- The flee fires only once, so nothing sent him away again (AL, a shrouded Xanley, died at Fish).
        if not running or justFledCombat then break end
        if not state.taxes[m] then
            if m == tax.mira then
                -- Mira is skipped - collect Sayer's tax straight from Flynn (North Qeynos)
                if collectViaFlynn() then
                    state.taxes[m] = true
                    saveState()
                    print(string.format('\ag[Postmaster]\ax boxed Sayer\'s tax via Flynn (%d/%d).', taxCount(), #tax.merchants))
                else
                    print('\ay[Postmaster]\ax could not collect Sayer\'s tax via Flynn - verify Flynn name / phrase.')
                end
            else
                -- travel to the merchant's home zone if they're not in the current one
                if tax.merchantZone[m] then
                    travelToZone(tax.merchantZone[m], m)
                end
                if (mq.TLO.Spawn("npc " .. m).ID() or 0) == 0 then
                    print('\ay[Postmaster]\ax merchant not found: ' .. m .. ' (verify name / zone shortname)')
                else
                    -- v2.51: through approachAndInteract, so in invis it comes from BEHIND the merchant (AL).
                    -- Nil = could not reach or approach (already said); false = reached, but no tax came.
                    local got = approachAndInteract(m, function()
                        sayPhrase(m, tax.phrase)
                        return waitUntil(function() return (mq.TLO.Cursor.ID() or 0) > 0 end, 5000)
                    end)
                    if got then
                        if putCursorInBox() then
                            state.taxes[m] = true
                            saveState()
                            print(string.format('\ag[Postmaster]\ax boxed tax from %s (%d/%d).', m, taxCount(), #tax.merchants))
                        else
                            print('\ar[Postmaster]\ax could not box the tax from ' .. m .. ' - check box slot / cursor.')
                        end
                    elseif got == false and not justFledCombat then
                        print('\ay[Postmaster]\ax no tax received from ' .. m .. ' - verify phrase / faction.')
                    end
                end
            end
        end
    end

    if justFledCombat then
        print(string.format('\ay[Postmaster]\ax attacked while collecting taxes (%d/%d boxed) - getting clear, then'
            .. ' carrying on with the rest.', taxCount(), #tax.merchants))
        nonadBusy = false
        return false
    end
    local n = taxCount()
    if n >= #tax.merchants then
        print('\ag[Postmaster]\ax all ' .. n .. ' taxes boxed - combining...')
        local combined = combineBox()
        if combined then
            print('\ag[Postmaster]\ax combined into the Full Tax Collection Box - next: return it to Vicus.')
        else
            print('\ar[Postmaster]\ax combine failed - verify ContainerWindow / Container_Combine.')
        end
        nonadBusy = false
        return combined
    end
    -- Not all 10 collected this pass (a merchant was unreachable/didn't respond) - stop here rather
    -- than loop on the same failure; AL can retry once the field issue (name/zone/faction) is fixed.
    print(string.format('\ay[Postmaster]\ax %d/%d taxes boxed so far.', n, #tax.merchants))
    nonadBusy = false
    return false
end

-- RETURN_VICUS: hand the Full box + List of Debtors to Vicus in South Qeynos.
local function returnToVicus()
    if not boxFull() then
        print('\ay[Postmaster]\ax no ' .. items.fullbox .. ' yet - collect + combine first.')
        return false
    end
    nonadBusy = true
    if (mq.TLO.Spawn("npc " .. nonad.vicus).ID() or 0) == 0 then
        if not travelToQeynos() then nonadBusy = false; return false end
    end
    -- HIDDEN through it - a hand-over needs no visibility (v2.37) - and facing Vicus (faceOk, v2.56: he never attacks
    -- by the time the quest reaches him, and his kneeling pose made the behind maneuver hard - AL).
    if not approachAndInteract(nonad.vicus, function()
        return giveItems({ items.fullbox, items.list }, nonad.vicus, true)
    end, true, true) then
        nonadBusy = false
        return false
    end
    mq.delay(1000)
    if (mq.TLO.FindItem("=" .. items.fullbox).ID() or 0) == 0 then   -- box gone = accepted
        state.taxesInVicus = true
        saveState()
        print('\ag[Postmaster]\ax turned the taxes in to Vicus - next: report to Pagus in Sunrise Hills.')
        nonadBusy = false
        return true
    end
    print('\ar[Postmaster]\ax Vicus did not take the turn-in - he may want only the box, or a say-phrase.')
    nonadBusy = false
    return false
end

-- RETURN_PAGUS: report to Pagus in Sunrise Hills to finish The Nonad Brothers.
local function returnToPagus()
    if not checkInventorySpace(1, nonad.reward) then return false end
    nonadBusy = true
    if mq.TLO.Zone.ID() ~= zones.neighborhood then
        travelToSunriseHills()
    end
    if mq.TLO.Zone.ID() ~= zones.neighborhood then
        print('\ar[Postmaster]\ax could not reach Sunrise Hills - travel there and run again.')
        nonadBusy = false
        return false
    end
    if (mq.TLO.Spawn("npc " .. nonad.pagus).ID() or 0) == 0 then
        print('\ar[Postmaster]\ax in Sunrise Hills but ' .. nonad.pagus .. ' not found - check VoA / instance.')
        nonadBusy = false
        return false
    end
    if not navToNpc(nonad.pagus) then nonadBusy = false; return false end
    mq.cmdf('/target id %d', mq.TLO.Spawn("npc " .. nonad.pagus).ID() or 0)
    mq.delay(300)
    local droppedInvis = dropInvisForInteraction()
    mq.cmd('/hail')
    if droppedInvis then ensureInvisBuff() end
    -- Pagus hands over the reward figure - wait for it, stow it, use it as the completion flag
    local rewarded = waitUntil(function()
        return (mq.TLO.FindItem("=" .. nonad.reward).ID() or 0) > 0 or (mq.TLO.Cursor.Name() == nonad.reward)
    end, 6000)
    for _ = 1, 4 do
        if (mq.TLO.Cursor.ID() or 0) == 0 then break end
        mq.cmd('/autoinventory')
        mq.delay(400)
    end
    state.nonadDone = true
    state.taxesInVicus = false
    saveState()
    print(rewarded and '\ag[Postmaster]\ax received the reward - The Nonad Brothers complete!'
        or '\ay[Postmaster]\ax reported to Pagus - marked complete (reward figure not detected; verify its name).')
    nonadBusy = false
    return true
end

-- Auto-detect Nonad completion by Pagus's reward figure (inventory OR bank). NOTE: the figure is
-- placeable (house/yard/guild) - once placed it's hidden from find, so this only catches a still-held
-- figure. That's fine: its only job is to flip the PERSISTED nonadDone once; persistence is the real
-- permanent flag and survives placing the figure later.
-- v2.29: this character's inventory and PERSONAL bank only. A figure in the account-wide shared bank may
-- be another character's, and counting it would persist a false nonadDone - after which Lysric withholds
-- the satchel for a quest the script says is finished. (See countsOf for how the two banks are told apart.)
local function detectNonadReward()
    if state.nonadDone then return end
    local carried, banked = countsOf(nonad.reward)
    if carried + banked > 0 then
        state.nonadDone = true
        saveState()
        print('\ag[Postmaster]\ax Nonad reward figure detected - The Nonad Brothers marked complete.')
    end
end

-- Light retry wrapper (AL chose this over a full step-engine rewrite - see POSTMASTER_PIPELINE.md
-- Phase 5, dropped: our dispatchers already re-derive "where am I" from real inventory/box state on
-- every call, which is the crash-recovery property that mattered; a step-index wasn't actually needed).
-- Our step functions are already state-aware (each checks "do I already have X" before acting), so
-- retrying the SAME call is safe - it just re-checks reality and continues, never repeats a completed
-- action. Kept to 2 attempts: not every failure is transient (no inventory space won't fix itself in
-- 3 seconds), so this fails fast and reports clearly rather than looping.
local function retryStep(label, fn, ...)
    local args = { ... }
    -- A flee's return trip is not a failed attempt, so `attempt` only counts genuine failures (v2.50).
    local attempt, flees, fleeTotal = 1, {}, 0
    while attempt <= 2 do
        justFledCombat = false
        local ok = fn(unpack(args))   -- LuaJIT/5.1 global unpack, NOT table.unpack (that's 5.2+)
        if ok then return true end

        -- THREE outcomes arrive here identically as `not ok`, and only one of them is a failure.
        -- Distinguishing them is the whole point of the next few lines (SCRIPT_SELFCHECK cat 8: distinct
        -- real-world outcomes collapsed into one branch).
        --
        -- 1. The USER CLOSED THE SCRIPT. Both wait primitives return false the instant `running` drops,
        --    so an abort is indistinguishable from a failure at this level. Without this check, clicking
        --    X mid-run printed "failed - retrying once", burned 3s, printed "failed twice", and fired
        --    alert.wav at somebody who had just closed the window. Closing a script must be SILENT -
        --    no print, no chime, no speech. A Stop click (v2.29) is the same thing.
        if not running or automation.stop then return false end

        -- 2. THE CHARACTER DIED. `diedWhileWaiting()` has already said so. The step cannot possibly
        --    succeed until a human clicks respawn, so retrying 3s later is guaranteed to fail and only
        --    prints the death message a second time. Stop, and say why without repeating it.
        if mq.TLO.Me.Hovering() then
            print('\ar[Postmaster]\ax ' .. label .. ' stopped because you died. Respawn, then run again.')
            return false
        end

        -- 3. A FLEE - carry on (v2.50, AL: *"carry on automatically after a flee, skip what's done"*).
        -- Until 2.49 this stopped: in August the automatic retry ran straight back at an already-attacking
        -- Ticar and circled him while getting hit. The answer now is the zone line in between - crossing it
        -- drops the aggro - then a wait and stealth re-armed before going back in (recoverFromFlee). A fight
        -- near the same NPC again waits 30 s instead of 10 (AL); a sixth flee in one step stops the run, so a
        -- spot that attacks every time cannot loop flee-return-flee for ever with nobody watching.
        if justFledCombat then
            local npc = automation.lastNpc or ""
            flees[npc] = (flees[npc] or 0) + 1
            fleeTotal = fleeTotal + 1
            if fleeTotal > 5 then
                ui.announce("alert.wav", label .. " keeps drawing fights.<silence msec='250'/> Postmaster has stopped.", true)
                print('\ar[Postmaster]\ax ' .. label .. ' drew a fight 5 times - stopping. Something here attacks'
                    .. ' every time; take a look, then run again.')
                return false
            end
            if not automation.recoverFromFlee(flees[npc] > 1) then
                if mq.TLO.Me.Hovering() then
                    print('\ar[Postmaster]\ax ' .. label .. ' stopped because you died. Respawn, then run again.')
                end
                return false
            end
        else
            -- 4. A genuine failure - retry once.
            if attempt < 2 then
                print('\ay[Postmaster]\ax ' .. label .. ' failed - retrying once...')
                mq.delay(3000)
            end
            attempt = attempt + 1
        end
    end
    -- Every automated step funnels through retryStep, so this one hook covers all of them: whatever
    -- stopped, the run is now waiting on a human.
    ui.announce("alert.wav", label .. " failed.<silence msec='250'/> Postmaster has stopped, and is waiting for you.", true)
    print('\ar[Postmaster]\ax ' .. label .. ' failed twice - stopping. Fix the issue above, then run again.')
    return false
end

-- Dispatcher: item/flag-derived state routes to the right step.
-- Full automation (AL): chain every remaining Nonad step in one click instead of one step per click,
-- matching the Postmaster's Challenge batching. Stops immediately after a step fails twice (retryStep)
-- so a field issue surfaces right away instead of the chain plowing forward on bad state.
local function runNonadStep()
    if state.nonadDone then
        print('\ay[Postmaster]\ax Nonad Brothers already marked done.')
        return
    end
    for _ = 1, 10 do   -- generous cap vs. the 5 real steps; guards against a logic-bug infinite loop
        if state.nonadDone then return end
        local ok
        if state.taxesInVicus then
            ok = retryStep("Report to Pagus", returnToPagus)
        elseif boxFull() then
            ok = retryStep("Return Taxes to Vicus", returnToVicus)
        elseif (mq.TLO.FindItem("=" .. items.box).ID() or 0) > 0 then
            ok = retryStep("Collect Taxes", collectTaxes)
        elseif (mq.TLO.FindItem("=" .. items.tonic).ID() or 0) > 0 then
            ok = retryStep("Give Tonic to Vicus", giveTonic)
        else
            ok = retryStep("Get Cough Tonic", getTonic)
        end
        if not ok then
            return   -- retryStep already printed the final failure message
        end
    end
end

-- Postmaster's Challenge (Phase 3): accept from Aric, run 18 deliveries, return to Aric.
-- PLACEHOLDERS - verify Aric name + phrases in-field.
-- ONE table for everything Aric. This was three separate locals plus, from v2.09, three more for the
-- performance detection - and that tipped the main chunk over Lua's 200-local ceiling, so the file
-- stopped compiling outright ("too many local variables"). Folding them here frees two slots AND adds
-- the new state for free. This is exactly the mitigation REFACTOR_NOTES.md #1 prescribes, and the same
-- pattern every UI helper already follows by hanging off `ui`. **Put anything new about Aric here.**
local aric = {
    name         = "Postmaster Aric Songfairer",
    leaguePhrase = "League of Antonican Bards",
    challenge    = "challenge",
    home         = { y = -2720.50, x = 2110.62, z = 3.42 },
    performing   = false,   -- set by the chat event while hailing; see finishChallenge
}

-- Aric's home spot, field-captured by AL 2026-08-24: "-2720.50, 2110.62, 3.42 (Heading: ESE) his
-- normal loc spot". EQ's own /loc order, so Y then X then Z. He stands here except when he walks off
-- to the stage to perform.
--
-- WHY THIS EXISTS: a hail mid-performance is just an emote - it does NOT complete the quest - and
-- there is no TLO that reports server-side completion for this quest. Before v2.11 the code hailed
-- three times over ~45 seconds and then declared success UNCONDITIONALLY, which meant a performance
-- longer than 45s produced a FALSE, PERSISTED `state.postmasterDone` and then a doomed auto-chain to
-- Lysric (who cannot do anything until Aric has actually flagged you). AL, 2026-08-24, watched exactly
-- that ping-pong: Aric -> "may be performing" -> Lysric -> fails -> back to Aric -> still performing.
--
-- AL clocked ONE performance at roughly THIRTY MINUTES, having previously estimated 10-15, so the
-- duration is genuinely unpredictable. Do NOT tune a timeout to a guessed length - wait for a real
-- signal instead. There are two, and they are independent:
--   LOC  - he is away from this spot => he is on stage. Cheap, and works BEFORE spending a hail.
--   CHAT - he answers a hail with "remains focused on his performance". Definitive, but needs a hail.

-- SHARED stage handling. BOTH quest-givers are bards who walk off to perform, both brush off a hail
-- with the SAME wording, and both need identical treatment - so this lives in one place rather than
-- being written twice. Defined here (after the invis helpers around 1131/1164) so it closes over the
-- real locals; declared any earlier, those calls would resolve to globals and silently be nil.
local stage = { performing = false }

-- Away from their usual spot => on stage. XY only: the stage and their spot barely differ in Z, so
-- including it would add noise without adding certainty.
function stage.atHome(npcName, home)
    local sp = mq.TLO.Spawn("npc " .. npcName)
    if (sp.ID() or 0) == 0 then return false end
    local dy, dx = (sp.Y() or 0) - home.y, (sp.X() or 0) - home.x
    return math.sqrt(dy * dy + dx * dx) <= 30
end

-- Block until they are back at their spot. The ceiling is deliberately generous (45 min) rather than
-- tuned: AL has clocked performances at roughly 15 AND 30 minutes, so the length is unpredictable.
-- waitUntil checks `running` and death on every poll, so the X button still aborts this cleanly.
function stage.waitForReturn(npcName, home)
    if stage.atHome(npcName, home) then return true end
    print('\ay[Postmaster]\ax ' .. npcName .. ' is away from their usual spot - performing on stage. Waiting for them to come back. Performances have run 15-30 minutes; the script will keep waiting, and hailing mid-performance does nothing.')

    -- A silent half-hour wait is indistinguishable from a hang, so give some sign of life - but AL is
    -- also trying to REDUCE console noise, so this is deliberately split:
    --   UI      - a live counter, updated every frame. Continuous status belongs on screen where it
    --             costs nothing and nobody has to read scrollback.
    --   CONSOLE - once every 5 minutes. Six lines across a 30-minute performance is a heartbeat, not
    --             spam. (AL suggested 4; 5 is the same idea with one fewer line, and neither is wrong.)
    local startedAt = mq.gettime()
    stage.waitingFor, stage.waitingSince = npcName, startedAt
    local nextNudge = startedAt + 300000
    local arrived = waitUntil(function()
        if mq.gettime() >= nextNudge then
            nextNudge = mq.gettime() + 300000
            print(string.format('\ay[Postmaster]\ax still waiting on %s - %d minutes so far. Nothing is stuck; they are on stage.',
                npcName, math.floor((mq.gettime() - startedAt) / 60000)))
        end
        return stage.atHome(npcName, home)
    end, 2700000, 5000)
    stage.waitingFor, stage.waitingSince = nil, nil

    if not arrived then
        print('\ar[Postmaster]\ax gave up waiting for ' .. npcName .. ' to finish performing. Nothing was lost - run this again when they are back at their spot.')
        return false
    end
    print(string.format('\ag[Postmaster]\ax %s is back at their spot after %d minutes - hailing.',
        npcName, math.floor((mq.gettime() - startedAt) / 60000)))
    return true
end

-- Hail and LISTEN. Returns true if the hail actually LANDED (they did not brush us off).
--
-- CONFIRMED wording, captured in game by AL 2026-08-24 from Lysric:
--   "Lysric Loresinger remains focused on their performance. Perhaps you should wait until they are
--    off stage to talk to them."
-- Note "THEIR", not "his"/"her" - EQ uses the gender-neutral form here. An earlier cut of this matched
-- 'his performance', built from a paraphrase rather than the real line, and would therefore have NEVER
-- FIRED - silently defeating the whole check and re-creating the false-completion bug it exists to
-- prevent. The wildcard between "on" and "performance" makes it robust to the pronoun either way, and
-- anchoring on the NPC's own name stops one bard's emote being read as the other's.
function stage.hailListening(npcName)
    stage.performing = false
    pcall(mq.unevent, 'PostmasterOnStage')
    mq.event('PostmasterOnStage', npcName .. ' remains focused on#*#performance#*#',
        function() stage.performing = true end)
    mq.cmdf('/target id %d', mq.TLO.Spawn("npc " .. npcName).ID() or 0)
    mq.delay(300)
    local droppedInvis = dropInvisForInteraction()
    mq.cmd('/hail')
    local waited = 0
    while waited < 3000 do
        mq.doevents()
        if stage.performing then break end
        mq.delay(100)
        waited = waited + 100
    end
    pcall(mq.unevent, 'PostmasterOnStage')
    if droppedInvis then ensureInvisBuff() end
    return not stage.performing
end

local function startChallenge()
    pmBusy = true
    if mq.TLO.Zone.ID() ~= zones.neighborhood then travelToSunriseHills() end
    if mq.TLO.Zone.ID() ~= zones.neighborhood then
        print('\ar[Postmaster]\ax could not reach Sunrise Hills - travel there and run again.')
        pmBusy = false
        return false
    end
    if (mq.TLO.Spawn("npc " .. aric.name).ID() or 0) == 0 then
        print('\ar[Postmaster]\ax ' .. aric.name .. ' not found in Sunrise Hills.')
        pmBusy = false
        return false
    end
    if not navToNpc(aric.name) then pmBusy = false; return false end
    mq.cmdf('/target id %d', mq.TLO.Spawn("npc " .. aric.name).ID() or 0)
    mq.delay(300)
    local droppedInvis = dropInvisForInteraction()
    mq.cmd('/hail')
    mq.delay(1200)
    if droppedInvis then ensureInvisBuff() end
    sayPhrase(aric.name, aric.leaguePhrase)
    mq.delay(1500)
    sayPhrase(aric.name, aric.challenge)
    mq.delay(1500)
    state.challengeStarted = true
    saveState()
    print('\ag[Postmaster]\ax challenge accepted from Aric - starting deliveries.')
    pmBusy = false
    return true
end

-- One delivery: (pick up if we don't already hold the parcel) travel to the pickup, get the parcel,
-- then travel to the recipient and hand it over. The held-parcel record is always verified against
-- inventory - if it poofed (30-min logout / death) we clear it and pick up a fresh copy.
-- Are we already holding THIS delivery's SPECIFIC letter? ID-based (field-confirmed 2026-08-05, AL):
-- letters that share a display name (e.g. every "Bardic Letter (Qeynos)" in a cluster) each have a
-- DISTINCT item ID - almost certainly a unique item definition per sender/recipient pairing, just
-- given a common display name for flavor. This replaced an earlier name-based FIFO/count guess
-- (v0.64) that could only say "we hold roughly enough of these," never "we hold THIS one specifically."
-- An exact ID check has no such ambiguity.
-- `silent` is for the RENDER THREAD, which calls this once per delivery row on every frame the
-- Deliveries tab is open. In that mode it is strictly READ-ONLY: no print, no saveState, no mutation.
--
-- WHY (AL's log, 2026-08-24): without it the UI RACED THE AUTOMATION on every single pickup. The letter
-- landed in inventory, the very next UI frame "auto-detected" it - printing to console AND writing
-- settings to disk from the render thread - and then pickupOnly's own "picked up" line followed. So a
-- message written for the RARE case (a letter acquired outside the script's own flow, e.g. AL's Ticar
-- sneak trick) fired on every NORMAL pickup, reading as though something unusual had happened.
--
-- The render thread doing disk IO is the worse half of that bug; the duplicate console line is just how
-- it announced itself. SCRIPT_SELFCHECK cat 3: threading violations.
local function heldParcelId(idx, silent)
    local id = state.held[idx]
    if id and (mq.TLO.FindItem(id).ID() or 0) > 0 then return id end
    -- Auto-recover a letter acquired outside the script's own pickup flow (e.g. a KOS sender approached
    -- via a manual sneak/hide trick, AL's Ticar case 2026-08-10) - every delivery's itemId is now
    -- confirmed reference data (v1.22), so the script can just check for it directly instead of relying
    -- on the manual "Sync held" button, which stays as a fallback but shouldn't be needed for this case
    -- anymore.
    local knownId = DELIVERIES[idx].itemId
    if knownId and (mq.TLO.FindItem(knownId).ID() or 0) > 0 then
        if silent then return knownId end   -- render thread: report it, change nothing
        state.held[idx] = knownId
        saveState()
        print('\ag[Postmaster]\ax auto-detected delivery ' .. idx .. '\'s letter already in inventory - synced.')
        return knownId
    end
    return nil
end


-- AL, 2026-08-11: arrived in PoK "beat up a bit" after escaping Erudin, then died to the Halas zone-in
-- guards partly for having gone in already hurt - "should help" to heal up first. Free, risk-free
-- recovery since combat can't happen in a safe hub zone anyway. Bounded wait, not a guarantee of
-- reaching 100% - natural HP regen can be slow for some classes/AAs, best-effort like everything else
-- in this pipeline. Return value is meaningful (unlike the other ensure* functions) - true only if it
-- actually paused to heal, so waitWhileProgressing's caller can reset its stuck-detection timer;
-- otherwise a multi-minute heal would look like a navigation stall the instant polling resumes.

ensureHealed = function()
    if not zones.inSafeHub() then return false end
    if (mq.TLO.Me.PctHPs() or 100) >= 100 then return false end
    print('\ay[Postmaster]\ax healing up before continuing (' .. tostring(mq.TLO.Me.PctHPs()) .. '% HP)...')
    mq.cmd('/sit on')
    waitUntil(function() return (mq.TLO.Me.PctHPs() or 100) >= 100 end, tuning.healWaitMs, 2000)
    mq.cmd('/stand')
    if (mq.TLO.Me.PctHPs() or 100) >= 100 then
        print('\ag[Postmaster]\ax fully healed - continuing.')
    else
        print('\ay[Postmaster]\ax still not fully healed after waiting - continuing anyway.')
    end
    return true
end

-- Consider-reaction capture (POSTMASTER_PIPELINE.md "Shroud Strategy") - outcome verification, not a
-- state flag, since Hide success/failure can't be read directly (AL's own field test, 2026-08-11:
-- "You have hidden yourself from view" fired but the guard still scowled on a second attempt - a real
-- per-check detection chance, not something Me.Invis()/Me.Sneaking() can tell us). Dynamic per-NPC event
-- registration (same technique as Grimmier's MyDPS pet-name events) - the exact NPC
-- name has to be literal text in the pattern since a generic wildcard can't reliably split a multi-word
-- NPC name from a multi-word reaction phrase.
local CONSIDER_EVENT = "PostmasterConsider"
local considerReaction = nil

-- Shared core: runs /consider against a known spawn id+name, returns the captured reaction or nil.
-- considerNpc (name search, existing callers) and radiusWatch (already has id+name straight from a
-- NearestSpawn scan, no need to re-search and risk resolving a different same-named spawn) both funnel
-- through this so the event-pattern/capture logic only exists once (v1.47).
local function considerSpawnId(id, npcName)
    if not id or id == 0 then return nil end
    pcall(mq.unevent, CONSIDER_EVENT)
    considerReaction = nil
    -- v1.34 widened this to `'<name> #1#'` (anything after the name) to work around the "-- looks like"
    -- phrase not being universal - but that was TOO wide: it also matched Ticar's combat taunt ("says,
    -- 'Die, like a motherless gnoll!'") and melee swings ("tries to punch YOU, but misses!"), and one of
    -- those got misread as a safe reading mid-fight (AL, 2026-08-11 field test - sent the script to
    -- unhide into an active attack). Both real confirmed examples (Sentinel Drom "(Lvl 50)", Ticar
    -- "(Lvl: 25)") end with " (Lvl" regardless of the colon inconsistency - a genuine consider response
    -- always has this, combat/speech text never does. Requiring it excludes the false positives without
    -- reintroducing the old "-- looks like" assumption that broke on Ticar in the first place.
    mq.event(CONSIDER_EVENT, npcName .. ' #1# (Lvl#*#', function(_, reaction)
        considerReaction = reaction
        dbg('raw consider capture: "' .. tostring(reaction) .. '"')   -- v2.63: debug only - it was console noise
    end)
    mq.cmdf('/target id %d', id)
    mq.delay(300)
    -- Full command, not the "/con" shorthand (AL, 2026-08-11: every automated attempt came back nil,
    -- but a manual /con worked - EQ chat showed "You congratulate Ticar Lorestring on a job well done"
    -- once per attempt, unexplained but suspicious given how closely it lines up. Using the full name
    -- removes any possible abbreviation ambiguity regardless of the exact cause.)
    mq.cmd('/consider')
    local elapsed = 0
    while elapsed < 3000 do
        mq.doevents()
        if considerReaction then return considerReaction end
        mq.delay(100)
        elapsed = elapsed + 100
    end
    return nil
end

local function considerNpc(npcName)
    local id = mq.TLO.Spawn("npc " .. npcName).ID() or 0
    return considerSpawnId(id, npcName)
end

-- Bottom-tier EQ consider reactions - the ones that mean genuinely dangerous, not just unfriendly
-- (TRAVEL_REFERENCE.md faction tier order: ...Dubiously -> Threateningly -> Scowls -> Ready to Attack).
-- Anything that doesn't match one of these is treated as safe enough to attempt the interaction.
local HOSTILE_REACTION_WORDS = { "threat", "scowl", "attack" }

-- Reactions friendly enough to walk up to openly. **PROVISIONAL** - deliberately not treated as a
-- complete list. Anything matching NEITHER list is treated as hostile and logged once (see below), so
-- this gets completed from real field readings instead of from a guess about EQ's exact wording.
--
-- "dubious" was in NEITHER list until v2.63, on purpose: whether Dubious means "will attack" had never been
-- checked. Now it has: Lady Shae read Dubious to a VISIBLE Xanley (no Sneak, no Hide) and never attacked (AL,
-- 2026-09-28), and the Faction tab's Dubious goal is where guards stop attacking on sight. Left out, it latched
-- stealth over all of West Freeport for one glowering NPC (AL's 2.62 run). Dubious still blocks some QUESTS
-- (Vicus) - that is a quest's own check, not an attack.
local SAFE_REACTION_WORDS = { "indifferent", "amiabl", "kindly", "warmly", "ally", "apprehensiv", "dubious" }

-- Reaction wordings already reported, so an unfamiliar one warns ONCE rather than on every consider.
-- (SCRIPT_SELFCHECK cat 11: announcements that repeat every cycle instead of once.)
local reactionUnknownSeen = {}

local function reactionIsSafe(reaction)
    if not reaction then return false end
    local lower = reaction:lower()
    for _, word in ipairs(HOSTILE_REACTION_WORDS) do
        if lower:find(word, 1, true) then return false end
    end
    for _, word in ipairs(SAFE_REACTION_WORDS) do
        if lower:find(word, 1, true) then return true end
    end
    -- UNRECOGNISED -> FAIL CLOSED (changed 2026-08-23; it used to return true here).
    -- Failing open meant any wording we did not anticipate was treated as friendly, and the character
    -- walked up to it un-stealthed. The cost of being wrong is asymmetric: a needless stealth approach
    -- is slow, while a missed hostile reading is a death. Cheap insurance in the correct direction.
    -- The print is the POINT of the change, not a debug leftover - it is how the two lists above get
    -- completed from real data. If this ever fires, paste the line back so the word can be sorted into
    -- HOSTILE_REACTION_WORDS or SAFE_REACTION_WORDS for good.
    if not reactionUnknownSeen[lower] then
        reactionUnknownSeen[lower] = true
        print('\ay[Postmaster]\ax unrecognised consider reaction: "' .. tostring(reaction) .. '"'
            .. ' - treating it as hostile to be safe. Please report this line so it can be classified.')
    end
    return false
end

-- Sneak and Hide, set to a WANTED state - never pressed blind (v2.48; replaces engageRadiusWatchStealth).
-- Treated as ONE unit, "invis" (v2.51, AL): both on, or both off - see the end of the function.
-- Both are TOGGLES, and the game changes them behind a script's back - zoning drops Hide, a step taken
-- without a working Sneak drops it ("You have moved and are no longer hidden!"), a trade drops it. So each is
-- pressed only while its state reads the opposite of what is wanted: Me.Sneaking is the spawn's sneak flag,
-- bare Me.Invis its HideMode (MQ2SpawnType.cpp) - for a character with no invis spell on, that is Hide.
-- AL, 2.47, a shrouded Xanley entering South Qeynos: the blind presses turned Hide ON while "dropping" the
-- last zone's stealth (zoning had already dropped it), scanned hidden, then turned it OFF while "engaging" -
-- he walked visible past two scowling Marsingers with only Sneak on.
-- Hide only takes STANDING STILL - the client's own "You must stand perfectly still to hide!" - which is why
-- a latch fired mid-walk never hid him. So a walk is paused first - but only an ACTIVE one: /nav pause is
-- refused otherwise ("Navigation must be active to pause"), which is what took the pause out in v1.53.
-- Hide goes on only over a working Sneak - moving hidden without one drops it at the first step.
-- `tries` (turning on only): press again as each ability comes back ready, that many rounds. The waits are
-- mq.delay, not waitUntil, because waitUntil runs Radius Watch, which calls this - but each still ends on
-- Stop or a closed script. Returns whether the wanted state holds at the end.
-- `keepSneak` - the ONE allowed half-state, Sneak without Hide. Turning OFF (v2.52): drop Hide and leave Sneak,
-- for a say from behind an NPC. Turning ON (v2.58): put Sneak back ALONE - the Faction tab's coin give re-arms a
-- dropped Sneak standing behind Fabian, where Hide is off on purpose (AL's decision 3).
local function setStealth(on, tries, keepSneak)
    local function isHidden() return mq.TLO.Me.Invis() == true end
    local function inCombat() return (mq.TLO.Me.CombatState() or ""):upper() == "COMBAT" end
    -- A wait ends on Stop, a closed script or COMBAT too - never stand still waiting on a cooldown while hit.
    local function readyOrStop(ability)
        return automation.stop or not running or inCombat() or mq.TLO.Me.AbilityReady(ability)() == true
    end
    -- v2.55 - TURNING ON WAITS FOR THE GAME'S VERDICT, not a clock. "You begin to hide..." takes a moment before
    -- "You have hidden yourself from view." or "You failed to hide yourself." (the client's own strings, 346/345),
    -- and 2.54 judged it 1.5 s after the press - it could read "failed" too soon. The other refusals count as a
    -- verdict too: 12424 "You must stand perfectly still to hide!", 12423 "You can't try to hide while attacking.",
    -- 342 "You must wait longer before you can hide or evade."; for Sneak 347 "...quiet as a cat stalking its
    -- prey." / 348 "...quiet as a herd of running elephants.", 12420 while attacking, 12421 only on dry land.
    local function pressAndJudge(ability, okLines, failLines)
        local verdict = nil
        local names = {}
        for i, line in ipairs(okLines) do
            names[#names + 1] = 'PMStealthOk' .. i
            mq.event(names[#names], line, function() verdict = true end)
        end
        for i, line in ipairs(failLines) do
            names[#names + 1] = 'PMStealthFail' .. i
            mq.event(names[#names], line, function() verdict = false end)
        end
        mq.cmd('/doability "' .. ability .. '"')
        mq.delay(8000, function()
            for _, n in ipairs(names) do mq.doevents(n) end
            return verdict ~= nil or automation.stop or not running
        end)
        for _, n in ipairs(names) do mq.unevent(n) end
    end
    -- v2.49: never turn stealth ON in a fight - the client refuses Hide then ("You can't try to hide while
    -- attacking"), and Sneak only slows the escape.
    if on and inCombat() then return false end
    local paused = false
    if on and mq.TLO.Navigation.Active() and not mq.TLO.Navigation.Paused() then
        mq.cmd('/nav pause')
        paused = true
    end
    if on then mq.delay(2000, function() return not mq.TLO.Me.Moving() end) end
    local ok = false
    for _ = 1, (on and (tries or 1)) or 1 do
        if mq.TLO.Me.Sneaking() ~= on and not (keepSneak and not on) then
            if on then
                mq.delay(15000, function() return readyOrStop("Sneak") end)
                pressAndJudge("Sneak", { "You are as quiet as a cat stalking its prey." },
                    { "You are as quiet as a herd of running elephants.", "You can't start sneaking while attacking.",
                      "You can only sneak on dry land." })
            else
                mq.cmd('/doability "Sneak"')
                mq.delay(1500, function() return mq.TLO.Me.Sneaking() == on end)
            end
        end
        if isHidden() ~= on and (not on or mq.TLO.Me.Sneaking()) and not (on and keepSneak) then
            if on then
                mq.delay(15000, function() return readyOrStop("Hide") end)
                pressAndJudge("Hide", { "You have hidden yourself from view." },
                    { "You failed to hide yourself.", "You must stand perfectly still to hide!",
                      "You can't try to hide while attacking.", "You must wait longer before you can hide or evade." })
            else
                mq.cmd('/doability "Hide"')
                mq.delay(1500, function() return isHidden() == on end)
            end
        end
        if on and keepSneak then
            ok = mq.TLO.Me.Sneaking() == true
        else
            ok = (keepSneak or mq.TLO.Me.Sneaking() == on) and isHidden() == on
        end
        dbg(string.format('stealth %s: sneaking %s, hidden %s', on and 'on' or 'off', tostring(mq.TLO.Me.Sneaking()),
            tostring(isHidden())))
        if ok or automation.stop or not running or inCombat() then break end
    end
    -- v2.51 - ONE UNIT (AL: *"view it as a whole as its 'invis' together"*): turning on either gets both, or
    -- ends with both OFF. Half is the worst of both - Sneak alone is slow and still seen.
    if on and not ok then
        if mq.TLO.Me.Sneaking() then
            mq.cmd('/doability "Sneak"')
            mq.delay(1500, function() return not mq.TLO.Me.Sneaking() end)
        end
        if isHidden() then
            mq.cmd('/doability "Hide"')
            mq.delay(1500, function() return not isHidden() end)
        end
    end
    if paused then mq.cmd('/nav pause off') end
    return ok
end

-- Combat detected, anywhere a shrouded character is waiting on something - not just mid-approach.
-- Sneak/Hide is meaningless once aggro lands, and this is deliberately NOT a combat script - killing a
-- KOS-faction NPC would only make the faction problem worse, not solve it. AL, 2026-08-11: "I would
-- rather just run and try to survive the run... this entire segment of script is for lower levels anyways
-- so death would not mean much." Best-effort flee via /travelto (EasyFind's own pathing to the nearest
-- zone connection - crossing ANY zone line resets aggro), not a guaranteed-safe extraction - no
-- health/threat monitoring, no pathing-away-from-danger logic. Same accepted-risk shape as the
-- still-unsolved High Keep gnoll pack danger elsewhere in this project: reduce it, don't pretend to
-- eliminate it.
-- Assigned to the upvalue forward-declared near waitUntil/waitWhileProgressing (v1.46) so BOTH of those
-- shared wait primitives can check it on every poll, not just the few explicit checkpoints inside
-- approachAndInteract's own retry loop. AL, 2026-08-13: a shrouded character got attacked by Erudin zone
-- guards during PLAIN TRAVEL (not the approach-a-KOS-NPC sequence at all) and died before ever reaching
-- the point where approachAndInteract's checks would have run - Sneak reduces detection chance, it was
-- never a guarantee, and nothing was watching for the moment it failed until now.
-- Get OUT of this zone and leave the rest to retryStep's recovery (v2.55 - shared by the combat flee and by
-- "invis will not go on here"). v2.50 (AL): run BACK THE WAY WE CAME - "a simple run back one zone where we just
-- came from" - not all the way to PoK. `/easyfind <shortname>` walks to this zone's closest connection to that
-- zone (EasyFind's own docs), and crossing any zone line drops the aggro. The PoK run stays as the fallback when
-- where we came from is not known. Sets justFledCombat, which every wait, travel leg and batch loop treats as
-- "stand aside", and which keeps a repeat trigger from re-firing the run (below).
function automation.retreat(why, spoken)
    local here = mq.TLO.Zone.ShortName() or ""
    local back = automation.zoneFrom
    automation.fledFrom = here
    if back and back ~= "" and back ~= here then
        print('\ar[Postmaster]\ax ' .. why .. ' - running back to ' .. back .. ' to shake it off...')
    else
        back = nil
        print('\ar[Postmaster]\ax ' .. why .. ' - running for a zone line...')
    end
    ui.announce("alert.wav", spoken, true)
    justFledCombat = true
    mq.cmd('/stick off')
    -- v2.52: ALWAYS drop invis, latched or not (AL: *"have to THEN turn off sneak and RUN"*) - a say from behind
    -- leaves Sneak on, and a Sneak left on turns the run into a crawl. By state: harmless when already off.
    setStealth(false)
    radiusWatchLatched = false
    if back then
        mq.cmd('/squelch /easyfind ' .. back)
    else
        mq.cmd('/travelto ' .. zones.pokShort)
    end
end

fleeIfInCombat = function()
    if (mq.TLO.Me.CombatState() or ""):upper() ~= "COMBAT" then return false end
    -- v1.50: idempotent - only react on the FIRST combat detection this attempt, not every repeat ping.
    -- AL, 2026-08-14 field log: a real flee-in-progress kept getting re-triggered by every subsequent
    -- combat tick, each one re-firing /travelto zones.pokShort - which resets EasyFind's routing progress
    -- from scratch every time (confirmed: each call produced a fresh "Traveling to: X" + restarted the
    -- first hop), so a travel that was actually working never got the chance to finish. Once already
    -- fleeing, the existing run is still the right response - a repeat hit doesn't need a NEW reaction, it
    -- just means keep letting the current one run. Returning false here (not true) also means the calling
    -- wait no longer aborts on a repeat hit - it just keeps polling normally, which is what actually let
    -- the already-working travel finish in the retest.
    if justFledCombat then return false end
    -- Safe from spam: idempotent per attempt (justFledCombat), so a long fight alerts once, not every poll.
    automation.retreat("in combat", "In combat.<silence msec='250'/> Breaking off, and running for the zone line.")
    return true
end

-- v2.55 - IN A HOSTILE ZONE, NEVER WALK ON VISIBLE. 2.54: "You failed to hide yourself." - and the walk resumed
-- anyway, straight past Sentinel Flavius (level 50), who killed level 10 Xanley in Toxxulia (AL). So: put invis
-- on standing still, a few tries as Hide comes back ready; if it still will not take, back off the way we came,
-- like the combat flee - retryStep's recovery rests, waits and re-hides standing still on the way back in. The
-- five-flee cap in retryStep bounds it: a Hide skill that never lands stops the run with an alert.
-- Called by Radius Watch with its latch ALREADY set, so setStealth's own waits cannot re-enter it.
function automation.hideOrBackOff()
    if setStealth(true, 4) or justFledCombat or automation.stop or not running then return end
    if (mq.TLO.Me.CombatState() or ""):upper() == "COMBAT" then
        fleeIfInCombat()
    else
        automation.retreat("could not get hidden here",
            "Could not hide.<silence msec='250'/> Backing off to the zone line.")
    end
end

-- Carry on after a flee (v2.50, AL: *"just run to the zone then we can turn around zone back ... and attempt
-- the next step"*, skipping what is done). Waits until the flee has really crossed out of the zone it left -
-- the crossing drops the aggro - re-arms Sneak+Hide standing at the line if this zone is known hostile, says
-- so, waits 10 s (30 s when the same NPC drew a fight before - AL's two numbers), and hands back to
-- retryStep, which reruns the step: every step skips what is done and walks itself back in. Returns false on
-- a death, a Stop, or no way clear. On `automation` because retryStep sits above setStealth in the file.
function automation.recoverFromFlee(again)
    local from = automation.fledFrom or ""
    -- /easyfind can find no connection and leave us standing in the fight - then the old run for PoK.
    mq.delay(1500)
    if (mq.TLO.Zone.ShortName() or "") == from and not mq.TLO.Navigation.Active() then
        dbg('the flee found no way back - running for PoK instead.')
        mq.cmd('/travelto ' .. zones.pokShort)
    end
    if not waitWhileProgressing(function() return (mq.TLO.Zone.ShortName() or "") ~= from end, 20000, 180000) then
        if running and not automation.stop and not mq.TLO.Me.Hovering() then
            print('\ar[Postmaster]\ax could not get clear of the fight - stopping. Get clear, then run again.')
        end
        return false
    end
    local clearAt = mq.gettime()
    mq.delay(2000)   -- settle after the zone-in
    local secs = again and 30 or 10
    -- v2.53 - HEAL TO 80% BEFORE GOING BACK (AL): the Flynn run made the line on 5.6% health, and until now the
    -- run went back in after 10 s whatever the health. Sit until 80% - the safe-hub heal-up (ensureHealed) never
    -- runs out here. The 10 s / 30 s wait runs ALONGSIDE the heal, not after it. A new fight ends the sit at once.
    if (mq.TLO.Me.PctHPs() or 100) < 80 then
        print(string.format('\ay[Postmaster]\ax clear of the fight at %d%% health - resting to 80%% before going back'
            .. ' into %s...', mq.TLO.Me.PctHPs() or 0, from))
        mq.cmd('/sit on')
        waitUntil(function()
            return (mq.TLO.Me.PctHPs() or 100) >= 80 or (mq.TLO.Me.CombatState() or ""):upper() == "COMBAT"
        end, 600000, 1000)
        mq.cmd('/stand')
        if not running or automation.stop or mq.TLO.Me.Hovering() then return false end
    end
    if radiusWatchKnownHostileZones[mq.TLO.Zone.ID() or 0] then setStealth(true, 3) end
    local left = math.max(0, secs * 1000 - (mq.gettime() - clearAt))
    print(string.format('\ay[Postmaster]\ax clear of the fight (%d%% health). Going back into %s in %d seconds%s...',
        mq.TLO.Me.PctHPs() or 0, from, math.ceil(left / 1000), again and ' - this spot drew a fight before' or ''))
    if left > 0 then waitUntil(function() return false end, left, 500) end
    if not running or automation.stop or mq.TLO.Me.Hovering() then return false end
    justFledCombat = false
    return true
end

-- Approaches an NPC and performs the interaction, deciding whether stealth is needed via a LIVE
-- /consider check once close enough to ask - NOT a static per-delivery flag. AL, 2026-08-11: "this is
-- why I wanted a check on the npc upon zone in... If we know the consider, we know we have to do
-- hide/sneak/get behind them for either pickup or delivery." Marton (Halas) got zero protection under
-- the old design because nothing had pre-flagged him hostile - this makes the live reading itself the
-- trigger, for ANY shrouded character approaching ANY NPC (pickup sender OR delivery recipient), instead
-- of requiring AL to discover and flag every dangerous NPC one death at a time.
-- Navs all the way there first (navToNpc - handles zone-specific quirks like the Erudin teleport gem).
-- If not shrouded at all, or the NPC reads non-hostile, skips straight to the interaction - no wasted
-- stealth for the common safe case. If hostile, uses MQ2MoveUtils' /stick for fine positioning
-- (confirmed loaded - RGMercs' own rog_class_config.lua
-- uses the identical "behind" arg for Backstab positioning), engages Sneak+Hide, and retries via
-- considerNpc/reactionIsSafe since a successful Hide message doesn't guarantee the NPC's own perception
-- check also passed. interactFn is called once positioned (and unhidden, if stealth was used) - its
-- return value becomes this function's return value. Handles re-hiding after and combat-flee around the
-- exposed moment; interactFn only needs to do the actual say/give.

-- Position behind an NPC via /stick (MQ2MoveUtils, confirmed loaded - RGMercs' own
-- rog_class_config.lua uses the identical "behind" arg for Backstab
-- positioning). Shared by approachAndInteract's two branches (already latched-protected from
-- radiusWatch vs. its own baseline-hostile-this-visit check, v1.47) - same positioning need either way,
-- only the reason for needing it differs. Returns false if the caller should abort (plugin missing, or
-- combat started mid-attempt - v1.45's fix, checking combat INSIDE the wait, not just after it).
local function stickBehind(npcName)
    if not mq.TLO.Plugin("MQ2MoveUtils").IsLoaded() then
        print('\ar[Postmaster]\ax MQ2MoveUtils is not loaded - cannot stick behind ' .. npcName .. '.')
        return false
    end
    local id = mq.TLO.Spawn("npc " .. npcName).ID() or 0
    mq.cmdf('/stick %d id %d behind', tuning.stickDistance, id)
    local gotBehind = false
    local stickElapsed = 0
    while stickElapsed < 15000 do
        if fleeIfInCombat() then return false end
        if mq.TLO.Stick.Behind() then gotBehind = true break end
        mq.delay(200)
        stickElapsed = stickElapsed + 200
    end
    if not gotBehind then
        dbg('could not confirm behind ' .. npcName .. ' - proceeding anyway.')
    end
    mq.cmd('/stick off')
    mq.delay(300)
    return true
end

-- Radius Watch pipeline (v1.47) - replaces sneakForTravel()'s old "wear Sneak the whole trip" design.
-- AL, 2026-08-14, field death crossing Tox Forest: "guards kill me because we are sneak (super slow
-- walk)." Sneak's movement-speed penalty was itself the danger, not detection - moving at a crawl means
-- far more total exposure time to every hostile NPC in a zone. Full design/flowcharts in
-- POSTMASTER_PIPELINE.md "Radius Watch pipeline".
--
-- Deliberately a ONE-WAY LATCH per zone, not continuous re-evaluation: full speed and un-stealthed until
-- the FIRST confirmed hostile NPC anywhere nearby (SpawnCount/NearestSpawn radius scan, /consider each
-- new spawn id seen), then Sneak+Hide stays on for the REST of this zone - no more considering, no more
-- toggling, until a real zone-line change resets it. AL: "once we find a hostile NPC, we kinda know most
-- around will be (city travel for evil guys) so we just stay hidden and sneak to our goal." This
-- deliberately sidesteps an unresolved question rather than depend on its answer: whether Hide/Sneak
-- itself can skew a /consider reading (existing field data - Sentinel Drom, 2026-08-11, HANDOFF.md - is
-- inconsistent on this). A /consider is NEVER taken while already stealthed under this design, so it
-- can't matter either way.
--
-- v1.49: remembers which zones already read hostile at least once this run (radiusWatchKnownHostileZones,
-- in-memory only - see its own comment for why not persisted). AL, 2026-08-14: leaving Erudin back into
-- Tox, the same Sentinel guards already confirmed hostile on the way IN sit right at the zone line - the
-- old design dropped stealth unconditionally on every zone change and started scanning from zero, leaving
-- the character briefly exposed at the worst possible moment (a random stun proc landed in that gap,
-- "practically death for a low level"). A zone already on the known-hostile list now re-latches
-- IMMEDIATELY as part of the same zone-change reset - no exposed scan-first gap on a repeat visit.
radiusWatch = function()
    if not mq.TLO.Me.Shrouded() then return end
    -- v2.50: remember the zone we came from - the combat flee runs back into it. Kept here because this runs
    -- on every wait poll while shrouded, and a flee only happens shrouded; before the flee check below, so it
    -- keeps counting through one.
    local nowZone = mq.TLO.Zone.ShortName() or ""
    if nowZone ~= "" and nowZone ~= automation.zoneNow then
        automation.zoneFrom, automation.zoneNow = automation.zoneNow, nowZone
    end
    -- v2.49: sit a flee out entirely. The flee clears the latch, and on the next poll this scanned, found the
    -- room still hostile and put Sneak back ON mid-fight - a crawl out while being hit (AL). Nor may a zone
    -- line on the way out re-latch. recoverFromFlee re-arms stealth once over the line, then clears the flag.
    if justFledCombat then return end
    local zoneId = mq.TLO.Zone.ID() or 0
    if zoneId ~= radiusWatchZoneId then
        -- Real zone-line transition, not an in-zone teleport (the Erudin gem doesn't change Zone.ID) -
        -- decide fresh for this new zone. v2.48: a known-hostile zone KEEPS what is still on (zoning drops
        -- Hide, so setStealth puts it back); any other zone drops the previous zone's stealth, by state.
        local wasLatched = radiusWatchLatched
        radiusWatchZoneId = zoneId
        radiusWatchLatched = false
        radiusWatchConsidered = {}

        if radiusWatchKnownHostileZones[zoneId] then
            print('\ay[Postmaster]\ax this zone read hostile earlier this run - going Sneak+Hide immediately.')
            radiusWatchLatched = true   -- before hideOrBackOff: it must not be re-entered from its own waits
            automation.hideOrBackOff()   -- v2.55: invis on standing still, or back off - never walk on visible
            return
        end
        if wasLatched then setStealth(false) end
    end

    if radiusWatchLatched then
        -- v2.51 - KEEP THE UNIT UP (AL: Sneak and Hide "not always both on or off"). The latch means invis ON
        -- for this zone, and the game knocks halves off behind us: a step on a failed Sneak roll ("You have
        -- moved and are no longer hidden!"), a trade, a skill that did not take. So when either half is off,
        -- stop and put both back - but only once Hide is off cooldown, or a low-skill character would stand and
        -- try on every poll. Never in the middle of an NPC interaction (it unhides on purpose for a say).
        if not automation.interacting and not (mq.TLO.Me.Sneaking() and mq.TLO.Me.Invis())
            and mq.TLO.Me.AbilityReady("Hide")() then
            dbg('invis dropped - putting it back.')
            automation.hideOrBackOff()   -- v2.55: or back off - 2.54 walked on visible after a failed Hide
        end
        return
    end
    if zones.inSafeHub() then return end   -- PoK/Guild Lobby/the neighborhood are never dangerous - don't
                                          -- bother scanning at all, same reasoning ensureHealed already
                                          -- uses these zones for (see zones.inSafeHub's own comment)

    local count = mq.TLO.SpawnCount("npc radius " .. tuning.guardRadius)() or 0
    for i = 1, count do
        local spawn = mq.TLO.NearestSpawn(i, "npc radius " .. tuning.guardRadius)
        local id = spawn.ID() or 0
        if id > 0 and not radiusWatchConsidered[id] then
            radiusWatchConsidered[id] = true
            local name = spawn.CleanName()
            if name then
                local reaction = considerSpawnId(id, name)
                if reaction and not reactionIsSafe(reaction) then
                    print('\ay[Postmaster]\ax ' .. name .. ' reads hostile nearby (' .. reaction
                        .. ') - going Sneak+Hide for the rest of this zone.')
                    radiusWatchLatched = true   -- before hideOrBackOff: it must not be re-entered from its own waits
                    radiusWatchKnownHostileZones[zoneId] = true
                    -- Stops the walk, hides standing still, walks on (v2.48) - or backs off (v2.55).
                    automation.hideOrBackOff()
                    return
                end
            end
        end
    end
end

-- `keepHidden` (v2.37): for an ITEM GIVE to a hostile NPC, stay hidden through the interaction. A hail or a
-- say does not register while hidden, which is why the stealth path below unhides first - but a trade does:
-- AL's August Iksar handed Lashun Novashine 1000 Bone Chips at a time while still hidden, at Scowls. Unhiding
-- for a trade is exactly the moment a scowling NPC attacks.
-- `faceOk` (v2.56): this NPC is known by QUEST LOGIC never to attack, so in invis we deal with them from where we
-- stand, no behind maneuver. Only Vicus Nonad: the script deals with him only once Antonius Bayle is at least
-- Apprehensive - the Taxes quest itself refuses anything less - and his kneeling-on-a-bed pose made the maneuver
-- hard (AL). Never judged by a con: see the v2.56 note below.
-- `sneakAnyway` (v2.58): take the invis path below WITHOUT a shroud - a Rogue on the Faction tab's coin give,
-- who has Sneak and Hide of their own (AL's decision 1). Everything else about the path is the same.
-- `spot` (v2.60): walk to THIS loc ({ y, x, z }) instead of the NPC, and no stick - AL's own standing spot behind
-- Palatos Kynarn, from which the bartender's shop opens too, so the gives and the restocks need no step.
approachAndInteract = function(npcName, interactFn, keepHidden, faceOk, sneakAnyway, spot)
    -- v2.57 - IN A SHROUD, EVERY QUEST NPC FROM BEHIND, IN INVIS (AL: *"every quest NPC from behind in a shroud...
    -- the Mail NPCs will not [give a pass]. Most are in good cities and are on League of Antonican Bard faction or
    -- similar."*). Only `faceOk` - quest logic, Vicus - is dealt with from where we stand. Invis goes on BEFORE the
    -- walk, standing still, and the zone is latched so Radius Watch keeps the unit up on the way: the August path
    -- walked up to ~14 units VISIBLE, then let a shrouded con decide - and a shrouded con can read a KOS NPC as safe
    -- (Ticar, 2.55/2.56). Will not take → back off (automation.hideOrBackOff), never walk up visible.
    local shrouded = mq.TLO.Me.Shrouded() or sneakAnyway == true
    if shrouded and not faceOk then
        radiusWatchZoneId = mq.TLO.Zone.ID() or 0   -- latch FIRST (this zone), so its waits cannot re-enter it
        radiusWatchLatched = true
        if not (mq.TLO.Me.Sneaking() and mq.TLO.Me.Invis()) then
            automation.hideOrBackOff()
            if justFledCombat or automation.stop or not running then return nil end
        end
    end
    local reached
    if spot then
        mq.cmdf('/nav loc %.2f %.2f %.2f log=off', spot.y, spot.x, spot.z)
        waitUntil(function() return mq.TLO.Navigation.Active() end, 5000, 100)
        waitUntil(function() return not mq.TLO.Navigation.Active() end, 180000, 200)
        local dy, dx = (mq.TLO.Me.Y() or 0) - spot.y, (mq.TLO.Me.X() or 0) - spot.x
        reached = math.sqrt(dy * dy + dx * dx) <= 6
    else
        reached = navToNpc(npcName)
    end
    if not reached then
        if not justFledCombat then print('\ar[Postmaster]\ax could not reach ' .. npcName .. ' to approach.') end
        return nil
    end
    -- `usedStealth`: we are in invis for this NPC, so it drops for a say and comes back after. For a faceOk NPC,
    -- only if we happened to be in invis already (a latched zone) - never switched on just for them.
    local usedStealth = false
    if shrouded then
        if faceOk then
            usedStealth = mq.TLO.Me.Sneaking() or mq.TLO.Me.Invis()
        else
            -- v2.51 (AL): *"when in sneak mode PC must interact an NPC from behind them. The point of being invis
            -- in this form is because we are in danger, sometimes from the NPC we are dealing with."*
            -- A `spot` IS behind him (AL chose it there), so no stick.
            if not spot and not stickBehind(npcName) then return nil end
            usedStealth = true
        end
    end

    -- Radius Watch keeps invis up in a latched zone; tell it an interaction is under way, so it does not put
    -- invis back in the middle of a say (v2.51). Cleared on every way out below.
    automation.interacting = true
    if usedStealth and not keepHidden then
        -- A hail/say won't register while hidden. Drop HIDE ONLY and keep Sneak for the say (v2.52, AL's trial -
        -- CONFIRMED at Flynn's back, 2026-09-28: the say landed, the tax came, he turned KOS, the flee dropped Sneak
        -- and ran - a level 10 shrouded Iksar made the zone line on 5.6% health). The one half-state the unit rule
        -- (v2.51) allows; the flee drops Sneak too.
        setStealth(false, nil, true)
        if fleeIfInCombat() then   -- the NPC can react the instant it sees us unhide
            automation.interacting = false
            return nil
        end
    end

    local result = interactFn()

    -- A fight straight after the interaction sends the flee off AT ONCE - after a hidden hand-over too (v2.54: a
    -- trade breaks Hide, and a KOS recipient turns on us; before, the check sat behind `not keepHidden` and the
    -- flee waited for the next walk's first poll). Shrouded only, like every other flee check. And invis is never
    -- put back on while a flee is under way (v2.52: a flee fired INSIDE interactFn reports only once).
    local fled = justFledCombat or (shrouded and fleeIfInCombat())
    if usedStealth and not keepHidden and not fled then
        setStealth(true, 2)
    end
    automation.interacting = false

    return result
end

-- Pickup half only (Phase 3.5 batching - see POSTMASTER_PIPELINE.md). Returns the item id held, or
-- nil on failure - or true with the row marked Delivered when the sender says it was delivered already (v2.66). Caller (runClusterBatch) has already decided this idx needs a real pickup via
-- heldParcelId - no existence re-check here.
local function pickupOnly(idx)
    local d = DELIVERIES[idx]
    -- Field test 2026-08-04 v2 (AL): superseded the /look 90 test - found Denethor's Explore.mac
    -- (RedGuides community macro, "hundreds of hours" tested) forces first-person camera ONCE at
    -- startup specifically for liquid navigation ("we swim better through lava this way"), then
    -- crosses Halas both directions with a plain /nav loc - no per-zone water hack at all. Testing
    -- the same: first-person before the Halas leg, left ON (not reset) since the swim-OUT happens
    -- later in a separate travel call (whatever leg follows this pickup) and needs it too.
    if d.fromZoneShort == "halas" then mq.cmd('/keypress FIRST_PERSON_CAMERA') end

    -- ensureShroud() explicitly (redundant with travelToZone's own call and self-gated internally, cheap
    -- either way - same pattern as ensureMovementBuff) so shrouding has definitely been attempted before
    -- radiusWatch (v1.47, hooked into waitUntil/waitWhileProgressing) has anything to protect.
    ensureShroud()

    if not travelToZone(d.fromZoneShort, d.from) then return nil end
    -- Only attempt the shuttle if we're actually still on the zone-in side (Y < -300) - travelToZone
    -- can return early with no travel at all if Marton's already in range (e.g. resuming mid-flow
    -- already across), and boarding then would be wrong/wasted.
    if d.fromZoneShort == "halas" and (mq.TLO.Me.Y() or 0) < -300 then rideHalasShuttleIn() end

    -- v2.66 - THE SENDER KNOWS (AL, 2026-09-30). Asked again for a letter already delivered, a sender answers "I
    -- applaud your enthusiasm, <name>. I cannot offer you another delivery at this time..." - a per-letter record kept
    -- on the SERVER (a new bard, mid-Challenge, back at Ticar after an Undo). It is the only "already done" signal the
    -- game gives, so the row is marked Delivered and the batch carries on instead of stopping on "no parcel". Heard
    -- only straight after the bare CITY word: Lislia and Ton each hand out two letters, and a reply to "deliver"
    -- alone could be about the other one.
    local refused = false
    local parcelId = approachAndInteract(d.from, function()
        sayPhrase(d.from, "I will deliver to " .. d.city)
        if not waitUntil(function() return (mq.TLO.Cursor.ID() or 0) > 0 end, 5000) then
            -- Multi-destination NPCs (e.g. Lislia: Qeynos AND Freeport) branch on two keywords:
            -- "deliver" opens the choice, then the city keyword selects it. Say them as separate
            -- lines. Single-destination NPCs already answered the one-liner above.
            sayPhrase(d.from, "deliver")
            mq.delay(700)
            pcall(mq.unevent, 'PostmasterRefused')
            mq.event('PostmasterRefused', d.from .. " says, 'I applaud your enthusiasm#*#cannot offer you another delivery#*#",
                function() refused = true end)
            mq.flushevents('PostmasterRefused')   -- anything matched before the city word is not about this letter
            sayPhrase(d.from, d.city)
            waitUntil(function()
                mq.doevents('PostmasterRefused')
                return (mq.TLO.Cursor.ID() or 0) > 0 or refused
            end, 5000)
            pcall(mq.unevent, 'PostmasterRefused')
            if (mq.TLO.Cursor.ID() or 0) == 0 then   -- a letter on the cursor wins over any refusal
                if refused then return 'delivered' end
                print('\ay[Postmaster]\ax no parcel from ' .. d.from .. ' - if you already hold this letter, tell me its name; otherwise verify the "deliver / ' .. d.city .. '" keywords.')
                return nil
            end
        end
        local pid = mq.TLO.Cursor.ID()   -- capture before stowing - the source of truth from here on
        -- Linked off the CURSOR, not by name: FindItem cannot see an item still on the cursor, so
        -- itemLink() would silently fall back to plain text here.
        print('\ag[Postmaster]\ax picked up: '
            .. (mq.TLO.Cursor.ItemLink('CLICKABLE')() or tostring(mq.TLO.Cursor.Name())))
        return pid
    end)
    if not parcelId then return nil end
    if parcelId == 'delivered' then
        state.deliveries[idx] = true
        state.held[idx] = nil
        saveState()
        print(string.format('\ay[Postmaster]\ax %s says your letter for %s was delivered already - marked Delivered (Undo on the Deliveries tab if that is wrong).', d.from, d.to))
        return true
    end

    for _ = 1, 4 do
        if (mq.TLO.Cursor.ID() or 0) == 0 then break end
        mq.cmd('/autoinventory')
        mq.delay(400)
    end
    -- Verify the stow actually succeeded (same check getTonic/giveTonic/returnToPagus already do) -
    -- without this, a full inventory mid-batch would still report "picked up" success with the letter
    -- stuck on the cursor, and the failure would only surface later, confusingly, in deliverOnly's
    -- slot-math safety net instead of here where the real cause is.
    if (mq.TLO.Cursor.ID() or 0) > 0 then
        print('\ar[Postmaster]\ax picked up ' .. tostring(mq.TLO.Cursor.Name()) .. ' but could not stow it - no inventory space. Clear a slot; it is on your cursor.')
        return nil
    end
    state.held[idx] = parcelId   -- remember what we carry (for resume + poof handling)
    saveState()
    return parcelId
end

-- Deliver half only (Phase 3.5 batching). Requires the parcels already be held (heldParcelId finds them);
-- does NOT pick them up. `idxs` are deliveries that all go to the SAME recipient.
-- v2.54 - ONE TRADE PER RECIPIENT (AL): every held letter for one NPC goes over in a single trade - up to the give
-- window's four slots - instead of one trade each. A trade breaks Hide (AL, the Bone Chips runs), so each trade at
-- a KOS Marsinger was a fight, and Tralyn Marsinger alone takes FOUR letters. Letters are matched by ITEM ID
-- (several are called "Bardic Letter (Qeynos)"), and each is still confirmed by ITS OWN id leaving the bags - the
-- old "no blind back-to-back hand-offs" rule (AL) now holds per letter within the trade. A letter handed back (an
-- NPC that takes one per trade) goes over again in a following trade, as long as each trade lands something.
-- v2.51: a hand-over, so in invis it stays HIDDEN (keepHidden) - a trade needs no visibility (v2.37). Same live
-- hostility check as pickupOnly (approachAndInteract) - a recipient can be as hostile as a sender.
local function deliverOnly(idxs)
    local d = DELIVERIES[idxs[1]]
    local pending = {}
    for _, idx in ipairs(idxs) do
        local pid = heldParcelId(idx)
        if pid then
            pending[#pending + 1] = { idx = idx, id = pid }
        else
            print('\ar[Postmaster]\ax not holding a parcel for delivery ' .. idx .. ' - pick it up first.')
        end
    end
    if #pending == 0 then return false end
    ensureShroud()   -- self-gated internally, cheap to call redundantly - same pattern as pickupOnly
    if not travelToZone(d.toZoneShort, d.to) then return false end

    while #pending > 0 do
        local ids = {}
        for i = 1, math.min(#pending, 4) do ids[i] = pending[i].id end
        approachAndInteract(d.to, function() return giveItemsById(ids, d.to, true) end, true)
        local still = {}
        for _, e in ipairs(pending) do
            if (mq.TLO.FindItem(e.id).ID() or 0) == 0 then   -- this EXACT letter gone = delivered
                state.deliveries[e.idx] = true
                state.held[e.idx] = nil
                local de = DELIVERIES[e.idx]
                print(string.format('\ag[Postmaster]\ax delivered %d/18: %s (%s) -> %s (%s).', deliveredCount(), de.from,
                    de.fromZone, de.to, de.toZone))
            else
                still[#still + 1] = e
            end
        end
        saveState()
        if #still == #pending then   -- nothing went over in this trade
            if not justFledCombat then
                print('\ar[Postmaster]\ax delivery to ' .. d.to .. ' not confirmed (parcel still held) - verify recipient / give.')
            end
            return false
        end
        pending = still
        if justFledCombat or not running or automation.stop then return #pending == 0 end
    end
    return true
end

-- Destination clusters (Phase 3.5): group deliveries sharing the same drop-off zone so a batch run
-- makes ONE trip to the destination instead of one per letter. Built from DELIVERIES, not hardcoded,
-- so it can't drift out of sync with the table.
local CLUSTERS = {}
do
    local byZone = {}
    for i = 1, #DELIVERIES do
        local zone = DELIVERIES[i].toZoneShort
        if not byZone[zone] then
            byZone[zone] = { toZoneShort = zone, indices = {} }
            CLUSTERS[#CLUSTERS + 1] = byZone[zone]
        end
        table.insert(byZone[zone].indices, i)
    end
end

-- Run one destination cluster fully unattended: pick up every not-yet-held letter in it (checking
-- free inventory space first - AL: needs enough room for the whole cluster, e.g. 6 for E.Freeport),
-- then make ONE trip to the shared destination and hand off each held letter one at a time.
-- ID-based tracking (2026-08-05) means this is now a plain per-index check - no more grouping/counting
-- needed, since heldParcelId can tell exactly which delivery a given letter belongs to.
local function runClusterBatch(cluster)
    pmBusy = true
    pmSpaceNeeded = nil   -- clear any prior block; re-evaluated fresh below

    local needPickup, held = {}, {}
    for _, idx in ipairs(cluster.indices) do
        if not state.deliveries[idx] then
            if heldParcelId(idx) then
                held[#held + 1] = idx
            else
                if state.held[idx] then
                    print('\ay[Postmaster]\ax the letter for delivery ' .. idx .. ' poofed - will re-pick-up.')
                    state.held[idx] = nil
                    saveState()
                end
                needPickup[#needPickup + 1] = idx
            end
        end
    end

    if #needPickup > 0 then
        local free = mq.TLO.Me.FreeInventory() or 0
        if free < #needPickup then
            print(string.format('\ar[Postmaster]\ax need %d free inventory slot(s) for this run, only %d free - clear space and try again.', #needPickup, free))
            pmSpaceNeeded = { need = #needPickup, free = free }
            pmBusy = false
            return false
        end
    end

    -- Continuously re-prioritize: anything in our CURRENT zone, or a zone known to be right next door
    -- to it, jumps to the front of the remaining queue - bundles a "passing right by" pickup into this
    -- same local leg instead of a separate PoK round trip later. Re-checked after EVERY pickup (not just
    -- once at the start), since the current zone changes as we go. travelToZone already short-circuits
    -- to instant when the target NPC is already nearby (its first line) - this just gets it a chance to
    -- fire before we travel away. Field cases: Lislia/High Keep (same-zone: the very next cluster's
    -- pickup list used to run Feerrott before Highkeep/Lislia, a wasted round trip when it was free for
    -- the taking) and Kilam/S.Kaladim while at Butcherblock for Siltria (adjacent-zone: AL, "we pass
    -- right by South Kaladim, may as well pick it up").
    while #needPickup > 0 do
        local hereZone = mq.TLO.Zone.ShortName() or ""
        local adjacent = zoneRule.adjacent[hereZone]
        local nextPos = 1
        for i, idx in ipairs(needPickup) do
            local fromZoneShort = DELIVERIES[idx].fromZoneShort
            if fromZoneShort == hereZone then
                nextPos = i
                break
            end
            if adjacent then
                for _, adj in ipairs(adjacent) do
                    if fromZoneShort == adj then nextPos = i end
                end
            end
        end
        local idx = table.remove(needPickup, nextPos)
        if not pickupOnly(idx) then pmBusy = false; return false end
        -- v2.66: the sender may have said this letter was delivered already - then there is nothing to carry.
        if not state.deliveries[idx] then held[#held + 1] = idx end
        -- v2.54: a fight right AFTER a good pickup has set the flee off - stop here, or the next pickup's walk
        -- overrides the flee's route (the tax loop's v2.49 bug, in this loop). retryStep carries on after it.
        if justFledCombat then pmBusy = false; return false end
    end

    -- v2.54: one trade per recipient - group the held letters by who they go to, in the order first met.
    local byRecipient, order = {}, {}
    for _, idx in ipairs(held) do
        local to = DELIVERIES[idx].to
        if not byRecipient[to] then
            byRecipient[to] = {}
            order[#order + 1] = to
        end
        table.insert(byRecipient[to], idx)
    end
    for _, to in ipairs(order) do
        -- ...and stop on a flee even after a GOOD trade (Tralyn takes the letters, then turns on us).
        if not deliverOnly(byRecipient[to]) or justFledCombat then pmBusy = false; return false end
    end

    -- Cluster finished: speak the city (AL, 2026-08-23 - "Qeynos mail is complete"). Deliberately
    -- speech-only (nil wav, so no chime) - a chime per cluster would erode the standing rule that a
    -- SOUND means the run needs you, while a spoken checkpoint is informational. Four clusters across
    -- a whole run is milestone cadence, not chatter, which is why this is the one progress event that
    -- gets a voice while individual deliveries stay silent.
    -- Checks the whole cluster, not just what this call delivered: a cluster part-finished by an
    -- earlier click still announces exactly once, on the click that actually completes it.
    local clusterDone = true
    for _, idx in ipairs(cluster.indices) do
        if not state.deliveries[idx] then clusterDone = false break end
    end
    if clusterDone then
        ui.announce(nil, DELIVERIES[cluster.indices[1]].city .. " mail is complete.")
    end

    pmBusy = false
    return true
end

finishChallenge = function()
    pmBusy = true
    if mq.TLO.Zone.ID() ~= zones.neighborhood then travelToSunriseHills() end
    if mq.TLO.Zone.ID() ~= zones.neighborhood then
        print('\ar[Postmaster]\ax could not reach Sunrise Hills - travel there and run again.')
        pmBusy = false
        return false
    end
    if (mq.TLO.Spawn("npc " .. aric.name).ID() or 0) == 0 then
        print('\ar[Postmaster]\ax ' .. aric.name .. ' not found in Sunrise Hills.')
        pmBusy = false
        return false
    end
    -- WAIT FOR HIM, rather than hailing into a performance and guessing (AL, 2026-08-24). Two
    -- independent signals, both via the shared `stage` helper Lysric uses too: come back only when he
    -- is home, then confirm by listening to what he actually says.
    -- "Did NOT brush us off" is the best success signal available - there is no completion TLO for this
    -- quest - it is not in the Task window and no TLO reports it - and it is far better than the
    -- old approach of assuming success after a fixed number of hails.
    local hailLanded = false
    for _ = 1, 3 do
        if not stage.waitForReturn(aric.name, aric.home) then pmBusy = false; return false end
        if not navToNpc(aric.name) then pmBusy = false; return false end
        if stage.hailListening(aric.name) then hailLanded = true break end
        print('\ay[Postmaster]\ax he is still focused on his performance - waiting for him rather than moving on.')
        mq.delay(5000)
    end

    -- NEVER flag the quest done on a hail we could not confirm. The old code set this unconditionally,
    -- which persisted a wrong `postmasterDone` and then sent the run to Lysric, who cannot help until
    -- Aric has actually flagged you server-side.
    if not hailLanded then
        print('\ar[Postmaster]\ax ' .. aric.name .. ' is still performing. Stopping WITHOUT marking the Challenge complete - nothing is lost, just run this again when he is done.')
        pmBusy = false
        return false
    end

    state.postmasterDone = true
    saveState()
    print('\ag[Postmaster]\ax Postmaster\'s Challenge complete - the title "Courier" is yours!')
    pmBusy = false
    -- Continue straight into Lysric (per Allakhazam: hailing Aric flags her, and AL wants no extra
    -- click here) if she isn't already handled. Only reachable once the hail is CONFIRMED, so this can
    -- no longer ping-pong to her while Aric is still on stage.
    if not state.lysricDone then runLysricStep() end
    return true
end

-- Phase 4: Lysric Loresinger - final turn-in for the Featherweight Satchel + Hyredel Swiftstride.
-- Requires Postmaster's Challenge done (Aric hailed) - confirmed via Allakhazam quest 5522: hailing
-- her afterward grants Hyredel Swiftstride, and ALSO the Featherweight Satchel if The Nonad Brothers
-- is done too (both AL's prereqs already are). If she's performing on stage, hailing gets only an
-- emote/no reward - retry with a longer wait rather than treat that as a failure.
-- One table, matching `aric` - keeps her home loc beside her name and costs no extra local slot
-- (the main chunk sits near Lua's 200 ceiling; see REFACTOR_NOTES.md #1).
-- Home spot field-captured by AL 2026-08-24: "-2695.75, 2087.12, 5.58 (Heading: SSE)". Y, X, Z.
-- She performs on the same stage rotation as Aric, with the same brush-off line - see `stage`.
local lysric = { name = "Lysric Loresinger", home = { y = -2695.75, x = 2087.12, z = 5.58 } }
local LYSRIC_NAME = lysric.name

local function hasHyredel()
    return (mq.TLO.FindItem("=" .. items.hyredel).ID() or 0) > 0
end

-- CARRIED only, on purpose (v2.29). runLysricStep refuses to hail while one is carried, so after a hail
-- a carried satchel can only mean one just ARRIVED. The old test also counted the bank - including the
-- account-wide shared bank - so on an alt whose shared bank held one it read true before any hail: the
-- loop quit after the first hail whatever Lysric did, and lysricDone was saved as a false completion.
local function carryingSatchel()
    return (mq.TLO.FindItem("=" .. items.satchel).ID() or 0) > 0
end

-- Lysric drops each reward on the CURSOR rather than auto-inventorying it (AL, field-confirmed) - both
-- Hyredel and the Satchel land here, one at a time, since the cursor only ever holds one item. Without
-- this, hasHyredel/carryingSatchel never see it (they check FindItem, not the cursor) and the
-- retry loop below just burns through its attempts thinking nothing arrived.
-- Put the cursor item into a free BAG slot, deliberately, instead of letting /autoinventory choose.
--
-- WHY (AL, 2026-08-24): this quest needs a MAIN inventory slot free for the Tax Collection Box, and the
-- Satchel is Giant-size so it ALSO can only go in a main slot. Lysric hands out Hyredel FIRST and the
-- Satchel SECOND - and /autoinventory happily drops Hyredel into a main slot, which is the one place it
-- did not need to be. The Satchel then arrives with nowhere to go and sits stuck on the cursor, which
-- is the failure v0.96/v0.97 had to add detection for. Putting Hyredel in a bag keeps the main slot
-- free for the item that genuinely requires one.
--
-- Returns false if no bag slot could take it, so the caller can fall back to /autoinventory - a bag
-- slot is a preference, never a requirement.
local function stowInBag()
    if (mq.TLO.Cursor.ID() or 0) == 0 then return true end
    for pack = 1, (mq.TLO.Me.NumBagSlots() or 10) do
        local container = mq.TLO.Me.Inventory("pack" .. pack)
        for slot = 1, (container.Container() or 0) do
            if (container.Item(slot).ID() or 0) == 0 then
                mq.cmdf('/itemnotify in pack%d %d leftmouseup', pack, slot)
                mq.delay(500)
                if (mq.TLO.Cursor.ID() or 0) == 0 then return true end
            end
        end
    end
    return false
end

local function stowCursor()
    if (mq.TLO.Cursor.ID() or 0) == 0 then return true end
    -- Anything that is NOT the Satchel should go in a bag if it can, to keep main slots free for the
    -- things that must have one (the Satchel itself, and the Tax Collection Box). Name captured BEFORE
    -- the async command, per this project's own rule about reading TLOs across a yield.
    local onCursor = mq.TLO.Cursor.Name()
    if onCursor and onCursor ~= items.satchel and stowInBag() then return true end
    mq.cmd('/autoinventory')
    mq.delay(500)
    if (mq.TLO.Cursor.ID() or 0) > 0 then
        -- Field case (AL): the Satchel is a Giant-size item - not every bag slot can hold one, so
        -- /autoinventory can find nothing valid and leave it stuck on the cursor with no explanation.
        print('\ar[Postmaster]\ax could not auto-inventory ' .. (mq.TLO.Cursor.Name() or "an item")
            .. ' - it may need a MAIN inventory slot (large items don\'t fit in every bag). Clear some'
            .. ' space, then check your cursor.')
        return false
    end
    return true
end

runLysricStep = function()
    if not state.postmasterDone then
        print('\ar[Postmaster]\ax hail ' .. aric.name .. ' first - Lysric won\'t give the reward until the Postmaster\'s Challenge is complete.')
        return false
    end
    -- Checks INVENTORY, not state.lysricDone or the bank. Both of those stay true once a satchel exists
    -- anywhere including the bank, which made the documented Lore trick - bank one, hail again for a
    -- second - unreachable from the UI. Lore only blocks a second copy in the SAME pool, so
    -- carrying one is the real blocker; a banked one is not.
    if (mq.TLO.FindItem("=" .. items.satchel).ID() or 0) > 0 then
        ui.lysricMsg = "Already carrying a satchel. Bank it first, then hail again for a second."
        ui.lysricMsgCol = { 0.95, 0.82, 0.35 }
        print('\ay[Postmaster]\ax already carrying the Featherweight Satchel - bank it, then hail again for a second.')
        return false
    end
    -- The Satchel is Giant-size and has already gotten stuck on the cursor in the field (v0.96/v0.97
    -- hardened stowCursor() to detect that after the fact) - precheck space before hailing, same as
    -- getTonic/giveTonic/returnToPagus already do, so the stuck state doesn't happen in the first place.
    if not checkInventorySpace(1, items.satchel) then return false end
    ui.lysricMsg = nil
    lysricBusy = true
    if mq.TLO.Zone.ID() ~= zones.neighborhood then travelToSunriseHills() end
    if mq.TLO.Zone.ID() ~= zones.neighborhood then
        print('\ar[Postmaster]\ax could not reach Sunrise Hills - travel there and run again.')
        lysricBusy = false
        return false
    end
    if (mq.TLO.Spawn("npc " .. LYSRIC_NAME).ID() or 0) == 0 then
        print('\ar[Postmaster]\ax ' .. LYSRIC_NAME .. ' not found in Sunrise Hills.')
        lysricBusy = false
        return false
    end
    local hadHyredel = hasHyredel()
    local stuckOnCursor = false
    -- She performs on the same stage rotation as Aric and brushes off a hail with the SAME wording
    -- (AL captured her exact line 2026-08-24), so she gets the same treatment through the same shared
    -- helper: wait for her to come back rather than burning hails into a performance.
    --
    -- Her loop is less dangerous than Aric's ever was - it verifies REAL item drops
    -- (hasHyredel/carryingSatchel) - but without
    -- this it still spent all three attempts on somebody who was demonstrably not listening, and a
    -- performance can run half an hour.
    for attempt = 1, 3 do
        if not stage.waitForReturn(lysric.name, lysric.home) then lysricBusy = false; return false end
        if not navToNpc(lysric.name) then lysricBusy = false; return false end
        if stage.hailListening(lysric.name) then
            -- The hail LANDED - so anything that goes wrong from here is a real problem, not her being
            -- on stage. Only check for the reward on this branch; checking after a brush-off would just
            -- be asking whether a hail she never heard produced an item.
            if not stowCursor() then
                -- A failed stow means something WAS granted, just couldn't be put away - re-hailing on
                -- top of an already-stuck cursor item won't help, only clearing space will (AL: "can we
                -- do a cursor is 'item' check and then know.. script is done?").
                stuckOnCursor = true
                break
            end
            if hasHyredel() or carryingSatchel() then break end
            if attempt < 3 then
                -- She was listening and still gave nothing. That is NOT a performance - most likely the
                -- Challenge is not actually flagged server-side yet, or she has nothing left to give.
                print('\ay[Postmaster]\ax she answered but gave no reward. If this repeats, hail ' .. aric.name .. ' again - the Challenge may not be flagged yet.')
                mq.delay(5000)
            end
        else
            print('\ay[Postmaster]\ax she is still focused on her performance - waiting for her rather than hailing again.')
            mq.delay(5000)
        end
    end

    if hasHyredel() and not hadHyredel then print('\ag[Postmaster]\ax received ' .. itemLink(items.hyredel) .. '!') end
    if carryingSatchel() then print('\ag[Postmaster]\ax received the ' .. itemLink(items.satchel) .. '!') end

    if carryingSatchel() then
        state.lysricDone = true
        saveState()
        ui.lysricMsg = "Courier of Favor complete - the Featherweight Satchel is yours."
        ui.lysricMsgCol = { 0.45, 0.85, 0.45 }
        ui.announce("milestone.wav", "Courier of Favor complete. The satchel is yours.")
        print('\ag[Postmaster]\ax Courier of Favor complete - the Featherweight Satchel is yours!')
    elseif stuckOnCursor then
        ui.lysricMsg = "A reward is stuck on your cursor. Clear inventory space, stow it, then hail again."
        ui.lysricMsgCol = { 0.95, 0.45, 0.35 }
        print('\ar[Postmaster]\ax a reward is stuck on your cursor - clear inventory space, stow it, then run again to confirm.')
    elseif hasHyredel() and not state.nonadDone then
        ui.lysricMsg = "Hyredel received. The satchel also needs The Nonad Brothers done - finish that, then hail again."
        ui.lysricMsgCol = { 0.95, 0.82, 0.35 }
        print('\ay[Postmaster]\ax Hyredel received, but the satchel needs The Nonad Brothers done too - finish that, then hail Lysric again.')
    elseif hasHyredel() then
        ui.lysricMsg = "Hyredel received, but no satchel yet - hail again."
        ui.lysricMsgCol = { 0.95, 0.82, 0.35 }
        print('\ay[Postmaster]\ax Hyredel received, but no satchel yet - try hailing Lysric again.')
    else
        ui.lysricMsg = "She answered but gave no reward. The Challenge may not be flagged yet - hail Aric again."
        ui.lysricMsgCol = { 0.95, 0.82, 0.35 }
        print('\ay[Postmaster]\ax no reward received - Lysric may still be performing. Try again in a moment, or /hail her manually.')
    end
    lysricBusy = false
    return carryingSatchel()
end

local function nextUndeliveredCluster()
    for _, cluster in ipairs(CLUSTERS) do
        for _, idx in ipairs(cluster.indices) do
            if not state.deliveries[idx] then return cluster end
        end
    end
    return nil
end

-- Dispatcher: start if needed -> next undelivered CLUSTER (Phase 3.5 batching, see
-- POSTMASTER_PIPELINE.md) -> finish at Aric when all 18 done. In checkpoint mode (state.pmFullAuto
-- false, the default) each click runs exactly one destination cluster fully unattended (all its
-- pickups, then one delivery trip), then stops - a natural pause point to glance at bags/HP/faction
-- risk before the next unattended run (AL's own field notes this session: gnoll deaths, lost parcels).
-- In full-auto mode (the checkbox AL asked for) it keeps going: next cluster, next cluster, and once
-- the last one's delivered, straight into Finish at Aric (which already auto-chains into Lysric) -
-- ONE click for the whole rest of the run, stopping only when done or a real failure needs AL. Accepting
-- the challenge from Aric always falls straight through into the first batch in the SAME click either
-- way (AL: getting the quest from Aric should be enough - no separate click needed unless something
-- actually blocks progress, like the inventory-space check inside runClusterBatch).
local function runPostmasterStep()
    repeat
        if state.postmasterDone then
            print('\ay[Postmaster]\ax Postmaster\'s Challenge already done.')
            return
        end
        if deliveredCount() >= #DELIVERIES then
            retryStep("Finish at Aric", finishChallenge)
            return
        end
        if not state.challengeStarted then
            if not retryStep("Start Challenge (Aric)", startChallenge) then return end
            -- fall through into the first batch immediately, no separate click required
        end
        local cluster = nextUndeliveredCluster()
        if not cluster then return end   -- shouldn't happen (deliveredCount check above covers it)
        if not retryStep("Run batch (" .. cluster.toZoneShort .. ")", runClusterBatch, cluster) then return end
    until not state.pmFullAuto
end

-- Faction helper quests (v2.29) - the Faction tab
--
-- Some quest NPCs will not deal with a character whose faction is too low: Vicus Nonad (Taxes) waits for
-- Antonius Bayle at Apprehensive. A HELPER is a quest that raises one faction by handing an NPC something
-- anyone can buy. Each is one row of data run by the same code, so another "buy it, give it" quest is a
-- new row, not new logic.
--
-- WHAT THE GAME LETS A SCRIPT READ (measured on Live, 2026-09-26/27):
--   * the Faction window's Reaction word for any faction - column 2 of FAC_FactionList, found by name. The
--     list holds every faction whichever category is showing, so the name lookup always finds it;
--   * the EARNED standing number - column 3 holds a small gauge window, List[row,3] hands that window
--     back, and its tooltip reads "Standing: 10 / Min: -2000 / Max: 2000";
--   * never the Reaction NUMBER (the one in brackets on hover) - it only exists while the mouse is there.
--     It is always earned standing + the race/class/deity adjustments the game ships in its own faction
--     tables, which was checked against every faction in the window on a test character: all 619 that
--     could be matched landed in the right tier, with no overlaps.
-- Tier edges from that check, run on two characters (a Vah Shir and an Iksar - every tier seen):
-- Apprehensive starts at exactly -100 (the highest Dubious was -101), Indifferent at 0, Amiably at 100.
-- The top three are only BRACKETED so far - Kindly somewhere in 380-500, Warmly 552-750, Ally 1001-1101 -
-- so `starts` holds the TOP of each bracket (v2.30). That is the safe side: a run always STOPS on the
-- word, never the number, so an estimate that is a little high only buys a few spare items; one that is
-- low would never stop a run early either, but would leave it short and send it back to the vendor.
-- A hover on the tier below ("N points to Kindly") pins each one exactly.
local faction = {
    tiers  = { "Scowls", "Threatening", "Dubious", "Apprehensive", "Indifferent", "Amiably", "Kindly", "Warmly", "Ally" },
    -- v2.59: Dubious - where guards stop attacking on sight. EXACT: AL's hover on Xanley's The Freeport Militia,
    -- "150 points to Dubious" at -650 (earned 0, Iksar -600, Cazic-Thule -50), 2026-09-28.
    starts = { Dubious = -500, Apprehensive = -100, Indifferent = 0, Amiably = 100, Kindly = 500, Warmly = 750, Ally = 1101 },
    goals  = { "Dubious", "Apprehensive", "Indifferent", "Amiably", "Kindly", "Warmly", "Ally" },
    helpers = {
        {
            key = "bonechips", title = "Bone Chips", faction = "Antonius Bayle",
            neededFor = "Vicus Nonad (Taxes) will not help below Apprehensive.",
            item = "Bone Chips",
            -- Two chips per point: 200 chips moved a Dark Elf's Antonius Bayle from -166 to -67 in one
            -- trade (Aug 2026), and a whole stack goes into one give with no cap seen up to 1000.
            perPoint = 2,
            vendor = "A Vendor of Reagents", vendorZone = "guildlobby", vendorWhere = "Guild Lobby",
            npc = "Lashun Novashine", npcZone = "qeynos2", npcZoneName = "North Qeynos",
            npcWhere = "North Qeynos - walks a route",
            raises = "Priests of Life, Knights of Thunder, Guards of Qeynos", lowers = "Bloodsabers",
            -- Antonius Bayle's race adjustments, from the game's own faction tables: these four and no
            -- others, and no class or deity ones. Used only for the up-front estimate.
            adjust = { race = { ["Dark Elf"] = -200, Troll = -375, Ogre = -375, Iksar = -375 } },
            -- Read before a run. At Threatening or Scowls the guards between you and the NPC attack on
            -- sight - and for an Iksar or a Troll the game starts Guards of Qeynos at -1000.
            danger = "Guards of Qeynos",
            -- The faction the NPC himself answers to - read before a run, because at Threatening or Scowls
            -- he attacks on sight and cannot be handed anything openly. Priests of Life, confirmed from his
            -- con (faction id 341) on 2026-09-27, the day he killed a level 1 Iksar that walked up to him.
            npcFaction = "Priests of Life",
            -- WHERE TO MEET HIM when those guards are hostile (v2.33, AL's plan - it killed a level 1 Iksar
            -- that walked straight to him). Lashun's route takes him out of the city's NORTH gate - where the
            -- gate guards stand - to the open field north-west of the city: AL's August loc, 1074.56, 450.15,
            -- "wanders within roughly a 200-radius". The PoK book stands just OUTSIDE the city's west wall,
            -- and from it the navmesh walks to that field in one straight line across open ground, never
            -- entering the city. So: arrive by the book, wait there, and walk out only while he is in the field.
            -- The book's spot is AL's own loc standing at it in game, 356, 460 (v2.35). The map file's label
            -- for it (183, 484) is 175 off - the maps date from 2016 - and 2.33/2.34 measured "at the book"
            -- from that label, so a character standing at the real book was told it was not.
            -- THE MEETING LINE (v2.40): Lashun's route does NOT reach the August spot - he stops at 508.87,
            -- 103.00 (heading 360), just north of the north gate by the stream, seen twice on 2026-09-27. AL:
            -- "he stops here clear past the gate guards... anything here or farther is ok." So he counts as out
            -- once he is at Y 500 or more - past the gate, on the field side; the August spot is inside that
            -- too. 2.33-2.39 waited for a circle round the August spot, which his route never entered.
            meet = { waitY = 356, waitX = 460, minY = 500 },
        },
        {
            -- v2.58 - A COIN HELPER: no shop, no items - `coin` and `perGive` instead of `item` and a vendor.
            -- Fabian's Strings, step 1: 2 gold = League of Antonican Bards +2. The quest wants that faction at
            -- Indifferent, but a hostile NPC reads a SNEAKING character as Indifferent and his quest believes it
            -- (AL, in game, 2026-09-28: from Fabian's back, Hide off, Sneak on, a level 10 Iksar at Scowls). Then
            -- ~1,080 gives took Xanley from Scowls to Ally in an afternoon, and the gain landed on the character.
            -- EXACTLY 2 gold a trade - he hands back anything else (80), so one trade is one turn-in.
            key = "fabian", title = "Fabian's Strings", faction = "League of Antonican Bards",
            neededFor = "Every bard in the Postmaster's Challenge - Tralyn and Eve Marsinger attack at Threatening or Scowls.",
            coin = "Gold", perGive = 2, unit = "gold",
            perPoint = 1,   -- gold per point: 2 gold, +2
            goal = "Indifferent",
            npc = "Fabian", npcZone = "freeporteast", npcZoneName = "East Freeport",
            npcWhere = "East Freeport - the Grub 'n Grog",
            raises = "Knights of Truth, Guards of Qeynos", lowers = "Ring of Scale, Mayong Mistmoore",
            -- The bards' adjustments, from the game's own faction tables (faction 284) - race, class AND deity,
            -- unlike Antonius Bayle. Xanley: Iksar -600, Shadow Knight -25, Cazic-Thule -200 = -825, his window
            -- to the point. Names as MQ gives them (Me.Race, Me.Class.Name, Me.Deity); Guktan = Froglok, and the
            -- game's Fizzlethorp is MQ's Bristlebane - both spellings kept.
            adjust = {
                race = { Human = 50, Barbarian = -25, ["Wood Elf"] = 25, ["Dark Elf"] = -50, ["Half Elf"] = 50,
                    Dwarf = -25, Troll = -600, Ogre = -550, Iksar = -600, ["Vah Shir"] = -25, Froglok = 50,
                    Guktan = 50, Drakkin = 50 },
                class = { ["Shadow Knight"] = -25, Bard = 100, Rogue = 25, Necromancer = -25 },
                deity = { Bertoxxulous = -200, ["Cazic-Thule"] = -200, ["Erollisi Marr"] = 50, Fizzlethorp = 50,
                    Bristlebane = 50, Innoruuk = -200, Karana = 50, Prexus = 50, ["Rallos Zek"] = -25, Tunare = 50,
                    Veeshan = -50 },
            },
            -- The guards all round him (AL, as himself, 2026-09-28: Runthar and Guard Tival Threatening while
            -- Fabian said Ally). Hostile → the mask is needed even at bards Ally.
            danger = "The Freeport Militia",
        },
        {
            -- v2.59 - LADY SHAE'S WINE: the Bone Chips shape again - buy, one trade of up to four stacks. Her part of
            -- "The Bayle List": 4 Red Wine = Emerald Warriors +5, and Emerald Warriors ARE Kelethin's guards (23 of
            -- them). She was "changed due to exploits" (AL), so it was measured before building on it (luatools/
            -- itemgive, 2026-09-29): 8 Red Wine as ONE pile, one trade → +10 in two lines, nothing handed back - a
            -- stack still counts per 4. Red, not White: White pays +1 a bottle (Red +1.25) and was only seen singly.
            key = "shaewine", title = "Lady Shae's Wine", faction = "Emerald Warriors",
            neededFor = "Kelethin's guards - on the way to Jakum Webdancer and Idia (Kelethin mail), and Idia's pickup.",
            item = "Red Wine",
            perPoint = 0.8, perSet = 4,   -- 4 bottles = +5; always whole sets of 4
            goal = "Indifferent",
            goalTip = "The reaction to stop at. At Dubious Kelethin's guards stop attacking\non sight;"
                .. " Indifferent (the default) leaves a margin.\n\nOne trade carries up to four stacks, and the wine is"
                .. " cheap -\nthe estimate never plans past the +2,000 earned standing.",
            vendor = "Brewmaster Berina", vendorZone = zones.pokShort, vendorWhere = "Plane of Knowledge",
            npc = "Lady Shae", npcZone = "freeportwest", npcZoneName = "West Freeport",
            npcWhere = "West Freeport - the Hogcaller's Inn",
            raises = "Kelethin Merchants, Merchants of Felwithe", lowers = "Indigo Brotherhood",
            -- Faction 326's adjustments from the game's own tables. Xanley: Iksar -1000, Shadow Knight -200,
            -- Cazic-Thule -200 = -1400; AL's hover "650 points to Threatening" agrees.
            adjust = {
                race = { Human = -50, Barbarian = -50, Erudite = -50, ["Wood Elf"] = 50, ["High Elf"] = 50,
                    ["Dark Elf"] = -750, ["Half Elf"] = 50, Dwarf = -50, Troll = -750, Ogre = -750, Halfling = -10,
                    Gnome = -25, Iksar = -1000, ["Vah Shir"] = -50, Froglok = -50, Guktan = -50, Drakkin = -50 },
                class = { Warrior = 50, ["Shadow Knight"] = -200, Necromancer = -200 },
                deity = { Bertoxxulous = -200, ["Brell Serilis"] = -50, ["Cazic-Thule"] = -200, Fizzlethorp = -25,
                    Bristlebane = -25, Innoruuk = -200, ["Solusek Ro"] = -50, Tunare = 50, Veeshan = -50 },
            },
            -- Lady Shae herself only glowers (Dubious to Xanley, visible) - the danger is the Militia round her inn:
            -- Guard Raflin walked up to a sneaking Xanley after a trade and killed him (AL, 2026-09-28).
            danger = "The Freeport Militia",
        },
        {
            -- v2.60 - PALATOS'S ALE: MANY trades like Fabian, but ITEMS, bought IN PLACE (`loop`). Allakhazam 384
            -- "The Painting": 4 Capt. Orlin's Spiced Ale = High Guard of Erudin +1 - Erudin's gate guards, the level 50
            -- Sentinels in Toxxulia that killed Xanley. Only 4 count per trade whatever the stack, and he hands back a
            -- LORE Beacon Mount, landing in the bags, that blocks the next turn-in until destroyed. AL ran it by hand
            -- and with luatools/itemgive (2026-09-29): 25 turn-ins, 3.3 s each, 25 beacons destroyed, nothing back.
            -- The ale runs out fast (500 turn-ins = 2,000 ale), so it is bought from the bartender beside him.
            key = "palatos", title = "Palatos's Ale", faction = "High Guard of Erudin",
            neededFor = "Erudin's guards - the Toxxulia Forest gate Sentinels (level 50) on the way to Ticar Lorestring.",
            item = "Capt. Orlin's Spiced Ale", loop = true,
            perTrade = 4, perPoint = 4, perSet = 4,   -- 4 ale = +1, one set a trade
            destroy = "Beacon Mount",
            goal = "Dubious",
            goalTip = "The reaction to stop at. At Dubious the gate guards in Toxxulia and\nErudin stop attacking on"
                .. " sight - the default.\n\nIt is slow: +1 for every 4 ale, one trade each. The ale is bought\nfrom"
                .. " the bartender beside him as you go.",
            -- The ale is bought from `shop`, beside him - AL: from his back, Nesin's shop opens without a step.
            -- Berina (PoK) sells it too - shown on the tab only; since v2.64 nothing walks there.
            vendor = "Brewmaster Berina", vendorZone = zones.pokShort, vendorWhere = "Plane of Knowledge",
            shop = "Nesin Tapper",
            npc = "Palatos Kynarn", npcZone = "freeporteast", npcZoneName = "East Freeport",
            npcWhere = "East Freeport - the Chops 'n Hops, in the slums (no Militia patrols there)",
            spot = { y = -1257.55, x = 377.01, z = -51.81 },   -- AL's spot behind him, heading NNE
            raises = "Craftkeepers, High Council of Erudin", lowers = "Heretics",
            -- Faction 267's adjustments from the game's own tables. Xanley: Iksar -725, Shadow Knight -200,
            -- Cazic-Thule -100 = -1025.
            adjust = {
                race = { Human = -25, Barbarian = -50, Erudite = 50, ["Wood Elf"] = -25, ["High Elf"] = -25,
                    ["Dark Elf"] = -500, ["Half Elf"] = -25, Dwarf = -200, Troll = -625, Ogre = -625, Halfling = -50,
                    Gnome = -25, Iksar = -725, ["Vah Shir"] = -50, Froglok = -25, Guktan = -25, Drakkin = -25 },
                class = { ["Shadow Knight"] = -200, Rogue = -50, Necromancer = -200 },
                deity = { Bertoxxulous = -100, ["Cazic-Thule"] = -100, Innoruuk = -200 },
            },
            -- His own faction: Craftkeepers (Allakhazam npc 881 - killing him costs it 20). Deep Scowls to Xanley.
            npcFaction = "Craftkeepers",
            -- IN THE ROOM with him: Canlan Talespinner, League of Antonican Bards (Allakhazam npc 870). Hostile, he is
            -- close enough to see through Sneak - so this helper waits for Fabian's Strings instead of masking (AL).
            danger = "League of Antonican Bards", dangerNpc = "Canlan Talespinner", dangerFix = "Fabian's Strings",
        },
    },
    request = nil,   -- helper index the Run button asked for; the main loop runs it
    check = nil,     -- helper index the Check button asked to re-read
    unshroud = nil,  -- helper index the Unshroud button asked for (v2.41)
    -- v2.63: the coin/loop run in progress - { key, need = what is LEFT, word, danger, npcWord } - sized as yourself,
    -- so a Run pressed in a SHROUD (where the Faction window is empty) carries on with it. Memory only.
    plan = nil,
    active = nil,    -- helper index running right now
    last = nil,      -- helper index the status line belongs to
    status = "",
    given = 0,       -- items handed over this run
    banked = 0,      -- items put in the bank for the shroud to take back out (v2.41)
    empty = false,   -- the last read found the Faction window's list EMPTY - a shroud does that (v2.41)
    reads = {},      -- [key] = { word =, standing =, danger = } - the last reading, for the tab
    -- The con message for every tier, exactly as the client's own string file has them (eqstr_us.txt, ids
    -- 12212-12220). A con is the one faction read that still works in a shroud (v2.41).
    conPhrases = {
        { "regards you as an ally", "Ally" }, { "looks upon you warmly", "Warmly" },
        { "kindly considers you", "Kindly" }, { "judges you amiably", "Amiably" },
        { "regards you indifferently", "Indifferent" }, { "looks your way apprehensively", "Apprehensive" },
        { "glowers at you dubiously", "Dubious" }, { "glares at you threateningly", "Threatening" },
        { "scowls at you, ready to attack", "Scowls" },
    },
    -- The PoK banker right beside Shroudkeeper Hyush (AL, 2026-09-27: loc 458.00, 474.00, -124.18). The bank
    -- is the bridge for ITEMS between a character and their shroud: a shroud cannot reach the normal self's bags,
    -- nor the SHARED bank, but it CAN reach the personal bank (AL, in game, shrouded as a Goblin Rogue with 14 free
    -- slots). COINS need no bridge: a PoK monster shroud KEEPS the coins you carry (AL, 2026-09-29 - the game
    -- changed this; long ago money had to be banked too, and mission shrouds are different).
    banker = "Banker Ceridan",
    -- The money slots, IW_Money0-3 in the purse and BNK_Money0-3 in the bank (the game's own EQUI_Inventory.xml
    -- and EQUI_BigBankWnd.xml), by the metal's name as MQ spells it (Me.Gold, Me.CursorGold...). v2.58.
    moneySlot = { Platinum = 0, Gold = 1, Silver = 2, Copper = 3 },
}

function faction.rank(word)
    for i, w in ipairs(faction.tiers) do
        if w == word then return i end
    end
    return nil
end

function faction.hostile(word)
    return word == "Threatening" or word == "Scowls"
end

function faction.coin(copper)
    copper = math.floor(copper or 0)
    return string.format("%dp %dg %ds %dc", math.floor(copper / 1000), math.floor(copper / 100) % 10,
        math.floor(copper / 10) % 10, copper % 10)
end

-- One faction's Reaction word and earned standing, off the Faction window. Tries with the window as it is
-- first; only if that comes back empty does it open the window, and it shuts it again afterwards, so the
-- player's screen is left as it was.
-- A SHROUD EMPTIES THE LIST (AL, in game, 2026-09-27, five rounds of tests): the window opens with nothing
-- in it while shrouded, and it STAYS empty after the shroud is removed, until the player camps to character
-- select and comes back - /reloadui does not cure it, and nor does opening it this way. So `faction.empty`
-- records whether the list held nothing even after this function opened the window itself and waited.
-- It must never be judged cold: straight after a login the list also holds nothing until the window is
-- first opened, and this very open is what fills it then.
-- v2.41: a window found OPEN but empty is closed and opened again this way before giving up - once, after a
-- camp, EQ's own /faction showed it empty while this route read it fine.
function faction.read(name)
    local wnd = mq.TLO.Window('FactionWnd')
    local list = mq.TLO.Window('FactionWnd/FAC_FactionList')
    local word, standing = nil, nil
    local function readRow()
        local row = list.List('=' .. name, 1)() or 0
        if row == 0 then return false end
        word = list.List(row, 2)()
        if word == "" then word = nil end
        standing = tonumber((list.List(row, 3).Tooltip() or ""):match("Standing:%s*(-?%d+)"))
        return word ~= nil
    end
    faction.empty = false
    if not readRow() then
        local wasOpen = wnd.Open()
        if wasOpen then
            wnd.DoClose()
            mq.delay(200)
        end
        wnd.DoOpen()
        waitUntil(readRow, 3000, 200)
        faction.empty = (list.Items() or 0) == 0
        if not wasOpen then wnd.DoClose() end
    end
    return word, standing
end

-- What to tell the player when the list read empty - the cure depends on whether they are still shrouded.
function faction.emptyWhy()
    if mq.TLO.Me.Shrouded() then
        return "your Faction window is empty because you are shrouded - press Unshroud, then camp to character"
            .. " select and come back (EQ keeps it empty after a shroud until you do)"
    end
    return "your Faction window is empty - EQ leaves it that way after a shroud until you camp to character"
        .. " select and come back. Camp, come back, then try again"
end

-- The tier a con message names, from the game's own phrases (see conPhrases above), or nil.
function faction.conTier(text)
    for _, p in ipairs(faction.conPhrases) do
        if text and text:find(p[1], 1, true) then return p[2] end
    end
    return nil
end

function faction.refresh(h)
    local word, standing = faction.read(h.faction)
    local danger, npcWord = nil, nil
    if not faction.empty then   -- an empty list is empty for all three - no need to wait on it twice more
        danger = h.danger and faction.read(h.danger) or nil
        npcWord = h.npcFaction and faction.read(h.npcFaction) or nil
    end
    faction.reads[h.key] = { word = word, standing = standing, danger = danger, npcWord = npcWord }
    return word, standing, danger, npcWord
end

-- This character's race + class + deity adjustment for the helper's faction (v2.58 - Bone Chips needed race
-- only). Read as yourself: in a shroud, Me.Class and Me.Race report the monster.
function faction.adjustFor(h)
    local a = h.adjust
    return (a.race and a.race[myRace] or 0) + (a.class and a.class[mq.TLO.Me.Class.Name() or ""] or 0)
        + (a.deity and a.deity[tostring(mq.TLO.Me.Deity() or "")] or 0)
end

-- Takes what just landed off the run in progress (v2.63) - see `faction.plan`.
function faction.planGave(h, n)
    local p = faction.plan
    if p and p.key == h.key then p.need = math.max(0, p.need - n) end
end

-- The Stop at for one helper (v2.58: each keeps its own). An older save's single goal stays with Bone Chips.
function faction.goalFor(h)
    return state.factionGoals[h.key] or h.goal or state.factionGoal
end

-- Items (or gold) still needed to reach `goal`, or nil when the standing did not read. The Reaction the goal
-- is measured in = earned standing + this character's adjustments (see the table above). v2.58: never more
-- than the EARNED standing can still climb - it stops at +2,000, and Xanley's last ~80 gives past it earned
-- nothing. So a goal the cap cannot reach returns 0 while the word is still below it.
function faction.estimate(h, standing, goal)
    if not standing then return nil end
    local short = math.min(faction.starts[goal] - (standing + faction.adjustFor(h)), 2000 - standing)
    if short <= 0 then return 0 end
    -- v2.59: whole items, and whole sets where the NPC counts in sets (Lady Shae: 4 wine = +5, perPoint 0.8).
    local n = math.ceil(short * h.perPoint)
    if h.perSet then n = math.ceil(n / h.perSet) * h.perSet end
    return n
end

function faction.count(h)
    return mq.TLO.FindItemCount('=' .. h.item)() or 0
end

-- How many sit LOOSE in the personal bank slots (bank1..24) - the ones faction.withdraw can take out. Not
-- the shared bank (a shroud cannot reach it), and not inside bags in the bank. Stack = items in a stack.
function faction.bankCount(h)
    local n = 0
    for i = 1, 24 do
        local it = mq.TLO.Me.Bank(i)
        if it.Name() == h.item then n = n + (it.Stack() or 1) end
    end
    return n
end

-- One line saying what is on hand against what the goal needs, BEFORE any buying (v2.39, AL: *"Script did
-- not say if it checked his inv for if he has any on him or needs xxx more"*). Returns the shortfall.
function faction.stockLine(h, want, goal)
    local carried, banked = faction.count(h), faction.bankCount(h)
    local short = math.max(want - carried - banked, 0)
    print(string.format('\ay[Postmaster]\ax %s: %d on you, %d in your bank - about %d wanted for %s. %s', h.item,
        carried, banked, want, goal, short > 0 and string.format("Buying %d.", short)
            or (carried >= want and "Enough on you - nothing to buy." or "Enough with the bank - nothing to buy.")))
    return short
end

-- The bank, for moving items between a character and their shroud (v2.38). Personal slots only: bank1..24
-- (MQ's own names, BNK_BankSlot0-23 in the game's window; 24 on Live - MQ's GetAvailableBankSlots gives 24
-- with the PoR expansion). Never the shared bank - the shroud cannot reach it.
function faction.openBank()
    if mq.TLO.Window('BigBankWnd').Open() then return true end
    if not travelToZone(zones.pokShort, faction.banker) then return false end
    if not navToNpc(faction.banker) then return false end
    mq.cmdf('/target id %d', mq.TLO.Spawn("npc " .. faction.banker).ID() or 0)
    mq.delay(300)
    mq.cmd('/click right target')
    return waitUntil(function() return mq.TLO.Window('BigBankWnd').Open() == true end, 10000, 250)
end

function faction.closeBank()
    if mq.TLO.Window('BigBankWnd').Open() then mq.cmd('/notify BigBankWnd BNK_DoneButton leftmouseup') end
    waitUntil(function() return not mq.TLO.Window('BigBankWnd').Open() end, 3000, 200)
end

-- Every stack carried goes into an empty personal bank slot. Counted by the stacks LEAVING the bags.
function faction.deposit(h)
    local before = faction.count(h)
    while faction.count(h) > 0 and running and not automation.stop do
        local slot = 0
        for n = 1, 24 do
            if (mq.TLO.Me.Bank(n).ID() or 0) == 0 then slot = n; break end
        end
        if slot == 0 then
            print('\ar[Postmaster]\ax your bank has no empty slot left for the ' .. h.item .. '.')
            break
        end
        local carried = faction.count(h)
        mq.cmdf('/shift /itemnotify "%s" leftmouseup', h.item)
        if not waitUntil(function() return mq.TLO.Cursor.Name() == h.item end, 3000, 100) then break end
        mq.cmdf('/itemnotify bank%d leftmouseup', slot)
        if not waitUntil(function() return (mq.TLO.Cursor.ID() or 0) == 0 end, 3000, 100) then
            mq.cmd('/autoinventory')   -- never strand a stack on the cursor
            break
        end
        -- The bags must actually have gone down, or this would loop forever - e.g. if the pickup ever took a
        -- stack from the open bank instead of the bags and put it straight back.
        if faction.count(h) >= carried then break end
    end
    return before - faction.count(h)
end

-- Stacks from the personal bank come out into the bags (the shroud's, once shrouded) - every one, or with
-- `upTo`, whole stacks until at least that many have come out. Counted by the stacks ARRIVING.
function faction.withdraw(h, upTo)
    local before = faction.count(h)
    dbg(string.format('withdraw: %d free bag slots, taking up to %s %s', mq.TLO.Me.FreeInventory() or 0,
        tostring(upTo or "all"), h.item))
    for n = 1, 24 do
        if not running or automation.stop then break end
        if upTo and faction.count(h) - before >= upTo then break end
        if mq.TLO.Me.Bank(n).Name() == h.item then
            if (mq.TLO.Me.FreeInventory() or 0) < 1 then
                print('\ay[Postmaster]\ax bags full - leaving the rest of the ' .. h.item .. ' in the bank.')
                break
            end
            mq.cmdf('/shift /itemnotify bank%d leftmouseup', n)
            if waitUntil(function() return mq.TLO.Cursor.Name() == h.item end, 3000, 100) then
                -- v2.42: a stack must LAND in the bags before the next is touched. On 2.41's first run (AL, a
                -- fresh Goblin Rogue shroud) the second stack stayed on the cursor, the next bank click
                -- swapped it for the third, and the run walked off holding one. Try a few times; if it still
                -- will not go in, put it back in the slot it came from and take no more.
                for _ = 1, 3 do
                    mq.cmd('/autoinventory')
                    if waitUntil(function() return (mq.TLO.Cursor.ID() or 0) == 0 end, 2000, 100) then break end
                end
                dbg(string.format('bank%d: cursor now %s, %d free bag slots', n, tostring(mq.TLO.Cursor.Name()),
                    mq.TLO.Me.FreeInventory() or 0))
                if (mq.TLO.Cursor.ID() or 0) > 0 then
                    mq.cmdf('/itemnotify bank%d leftmouseup', n)
                    waitUntil(function() return (mq.TLO.Cursor.ID() or 0) == 0 end, 3000, 100)
                    print(string.format('\ay[Postmaster]\ax a stack of %s would not go into your bags (%d free slots'
                        .. ' showing) - left it in the bank.', h.item, mq.TLO.Me.FreeInventory() or 0))
                    break
                end
            end
        end
    end
    return faction.count(h) - before
end

-- Buy as yourself, bank, shroud, and take the items back out as the shroud (v2.38, AL: *"all items on self
-- are inaccessible while shrouded"*). Returns true with the items in the shroud's bags, or false and why.
-- v2.41 (AL): `want` is the WHOLE amount for the Stop at goal - there is one trip, because nothing can be
-- bought or read once shrouded - and the number banked for it is remembered (`faction.banked`), so the
-- shroud takes back exactly that, not every stack that happens to be in the bank.
function faction.bankAndShroud(h, want, goal)
    automation.noShroud = true   -- travel must not shroud us before the buying and banking
    -- Counts the bags AND the bank first (v2.39): chips already banked are exactly what the shroud needs.
    local short = faction.stockLine(h, want, goal)
    if short > 0 then
        faction.status = string.format("Buying %d %s as yourself, before the shroud...", short, h.item)
        faction.buy(h, short)
    end
    if faction.count(h) + faction.bankCount(h) == 0 then
        automation.noShroud = false
        return false, "could not buy " .. h.item
    end
    if faction.count(h) > 0 then
        faction.status = string.format("Banking the %s before the shroud...", h.item)
        local banked = faction.openBank() and faction.deposit(h) or 0
        faction.closeBank()
        if banked > 0 then
            print(string.format('\ag[Postmaster]\ax banked %d %s.', banked, h.item))
        end
        if faction.count(h) > 0 then
            print(string.format('\ay[Postmaster]\ax %d %s could not be banked - they stay with you, out of the'
                .. ' shroud\'s reach.', faction.count(h), h.item))
        end
    end
    automation.noShroud = false
    if faction.bankCount(h) == 0 then return false, "could not bank the " .. h.item .. " - the shroud could not reach them" end
    faction.banked = math.min(faction.bankCount(h), want)
    print(string.format('\ay[Postmaster]\ax %d %s in your bank for this run%s - the shroud takes them back out next.',
        faction.banked, h.item, faction.banked < want and string.format(" (short of the %d wanted - going with those)", want) or ""))

    ensureShroud(true)
    if not mq.TLO.Me.Shrouded() then return false, "could not take the Goblin Rogue shroud" end

    faction.status = string.format("Taking %d %s back out of the bank as the shroud...", faction.banked, h.item)
    local got = faction.openBank() and faction.withdraw(h, faction.banked) or 0
    -- Never walk away from the bank holding a stack (2.41 did). withdraw puts a stuck one back; if even
    -- that failed, stop here rather than carry it to North Qeynos.
    if (mq.TLO.Cursor.ID() or 0) > 0 then
        faction.closeBank()
        return false, string.format("a stack of %s is stuck on your cursor - put it away (bank or bags)", h.item)
    end
    faction.closeBank()
    if got == 0 then return false, "could not take the " .. h.item .. " back out of the bank" end
    print(string.format('\ag[Postmaster]\ax the shroud is carrying %d %s%s.', got, h.item, got < faction.banked
        and string.format(" - %d fewer than the %d banked for this run", faction.banked - got, faction.banked) or ""))
    return true
end

-- Buys up to `want`, in as many stacks as that takes (one bag slot each), and returns how many actually
-- arrived. The fleet's proven merchant sequence (turnipbuy, pppoker): select by exact name, Buy at most one
-- stack at a time, and confirm by the count going up - never by the click. The PRICE and the STACK SIZE are
-- both read off the merchant, never assumed: price varies with charisma and faction, and the stack size is
-- whatever this server says it is.
-- v2.32: WAITS FOR THE MERCHANT'S LIST before selecting. v2.29 selected 600 ms after the window opened; a
-- big shop like a reagent vendor had not sent its list yet, so SelectItem found nothing and the run said
-- "does not sell Bone Chips" at a vendor that does (AL, level 1 Iksar). Merchant.ItemsReceived is MQ's own
-- "the list has been filled in" flag.
function faction.buy(h, want)
    if not checkInventorySpace(1, h.item) then return 0 end
    if not travelToZone(h.vendorZone, h.vendor) then return 0 end
    if not navToNpc(h.vendor) then return 0 end
    mq.cmdf('/target id %d', mq.TLO.Spawn("npc " .. h.vendor).ID() or 0)
    mq.delay(300)
    mq.cmd('/click right target')
    if not waitUntil(function() return mq.TLO.Merchant.Open() == true end, 10000, 300) then
        printIfRunning('\ar[Postmaster]\ax ' .. h.vendor .. '\'s shop did not open.')
        return 0
    end
    waitUntil(function() return mq.TLO.Merchant.ItemsReceived() == true end, 10000, 250)
    mq.cmd('/notify MerchantWnd MW_MerchantSubwindows tabselect 1')
    mq.delay(300)
    -- A few tries: a miss costs a second here, where giving up costs the whole trip.
    for _ = 1, 3 do
        mq.TLO.Merchant.SelectItem('=' .. h.item)()
        if waitUntil(function() return mq.TLO.Merchant.SelectedItem.Name() == h.item end, 1500, 250) then break end
    end
    local bought = 0
    if mq.TLO.Merchant.SelectedItem.Name() ~= h.item then
        print('\ar[Postmaster]\ax could not find ' .. h.item .. ' in ' .. h.vendor .. '\'s list.')
    else
        local price = mq.TLO.Merchant.SelectedItem.BuyPrice() or 0
        local stack = math.max(mq.TLO.Merchant.SelectedItem.StackSize() or 1, 1)
        local total = want
        if price > 0 then total = math.min(total, math.floor((mq.TLO.Me.Cash() or 0) / price)) end
        if total < 1 then
            print(string.format('\ar[Postmaster]\ax not enough money for %s - they cost %s each here.', h.item, faction.coin(price)))
        end
        local before = faction.count(h)
        while bought < total and running and not automation.stop do
            if (mq.TLO.Me.FreeInventory() or 0) < 1 then
                print(string.format('\ay[Postmaster]\ax bags full after %d %s - carrying on with those.', bought, h.item))
                break
            end
            local batch = math.min(stack, total - bought)
            mq.TLO.Merchant.Buy(batch)()
            waitUntil(function() return faction.count(h) >= before + bought + batch end, 8000, 250)
            local now = faction.count(h) - before
            if now <= bought then break end   -- nothing arrived: stop rather than keep spending blind
            bought = now
        end
        if bought > 0 then
            print(string.format('\ag[Postmaster]\ax bought %d %s for %s (stacks of %d here).', bought, h.item,
                faction.coin(bought * price), stack))
        end
    end
    mq.cmd('/notify MerchantWnd MW_Done_Button leftmouseup')
    mq.delay(300)
    return bought
end

-- Safe-meeting helpers (v2.33) - see the `meet` field above for the why.
function faction.distTo(y, x)
    local dy, dx = (mq.TLO.Me.Y() or 0) - y, (mq.TLO.Me.X() or 0) - x
    return math.sqrt(dy * dy + dx * dx)
end

function faction.inMeetArea(h)
    local sp = mq.TLO.Spawn("npc " .. h.npc)
    if (sp.ID() or 0) == 0 then return false end
    return (sp.Y() or 0) >= h.meet.minY
end

-- Walk back to the waiting spot (no-op when already there). The way back is the same west-side field.
function faction.backToWait(h)
    if faction.distTo(h.meet.waitY, h.meet.waitX) <= 15 then return true end
    mq.cmdf('/nav locyx %.2f %.2f log=off', h.meet.waitY, h.meet.waitX)
    waitUntil(function() return mq.TLO.Navigation.Active() == true end, 3000, 100)
    return waitUntil(function()
        return faction.distTo(h.meet.waitY, h.meet.waitX) <= 15 or not mq.TLO.Navigation.Active()
    end, 120000, 250)
end

-- Stand at the waiting spot until he is out in the field. Shaped like the bards' stage wait in Sunrise
-- Hills, on purpose (v2.34, AL): one line to say why we are waiting, a heartbeat every 5 minutes so a long
-- wait never reads as a hang, one line when he shows, and the same generous 45-minute ceiling - his route
-- has no known timing. The tab's status line counts the minutes too; Pause and Stop work throughout.
function faction.waitForMeet(h)
    if faction.inMeetArea(h) then return true end
    local since = mq.gettime()
    local nextNudge = since + 300000
    print(string.format('\ay[Postmaster]\ax Waiting safely by the PoK book since you are KOS here, until %s comes out of the gates.', h.npc))
    local came = waitUntil(function()
        local mins = math.floor((mq.gettime() - since) / 60000)
        faction.status = string.format("Waiting safely by the PoK book for %s to come out of the gates (%d min)...", h.npc, mins)
        if mq.gettime() >= nextNudge then
            nextNudge = mq.gettime() + 300000
            print(string.format('\ay[Postmaster]\ax still waiting on %s - %d minutes so far. Nothing is stuck; they are still inside the gates.',
                h.npc, mins))
        end
        return faction.inMeetArea(h)
    end, 2700000, 1000)
    if came then
        print(string.format('\ag[Postmaster]\ax %s is out past the gates after %d minutes - heading out to meet them.',
            h.npc, math.floor((mq.gettime() - since) / 60000)))
    end
    return came
end

-- Hands over EVERY stack carried, one trade each, in ONE visit (v2.32 - before, one stack per round meant a
-- fresh walk to him for each). Counted, not assumed: a trade only counts if the items actually left the
-- bags, because an NPC that refuses one hands them back. He walks a route, so a trade that misses him is
-- tried again from wherever he is by then; three misses in a row ends the visit. Returns true if at least
-- one trade landed.
-- `careful` (v2.33): the guards on the way are hostile, so meet him only out in the field - arrive by the
-- PoK book, wait there, walk out while he is in the field, and walk back to the book afterwards.
-- `stealthGive` (v2.37): he himself is hostile, so the trade happens while shrouded and hidden - approach with
-- Sneak+Hide and never unhide or /makemevisible for it (see approachAndInteract's keepHidden).
-- v2.41 (AL's design): shrouded, there is no waiting at the book - straight to him wherever he is, Sneak+Hide
-- on from the moment we arrive (we already KNOW this city is hostile, so it does not wait for the Radius
-- Watch scan to find a guard first). The give itself breaks Hide, and the first stack should end the danger
-- anyway, so each stack after it just goes over. After every stack he is conned: the Faction window is
-- empty in a shroud, but a con still reads, and it says whether he is still hostile.
function faction.give(h, careful, stealthGive)
    local m = careful and h.meet
    -- Careful mode goes THROUGH PoK (v2.34): PoK's book is what lands you by the PoK book here, outside the
    -- wall. Any other way in can land inside the city - it did, twice, on 2026-09-27, after a respawn.
    -- (Shroudkeeper Hyush is just a PoK spawn to confirm arrival by; getGoblinRogueShroud uses him too.)
    local here = mq.TLO.Zone.ShortName() or ""
    if m and here ~= h.npcZone and here ~= zones.pokShort then
        if not travelToZone(zones.pokShort, "Shroudkeeper Hyush") then return false end
    end
    if not travelToZone(h.npcZone, h.npc) then return false end
    if stealthGive then
        -- Latch Radius Watch for this zone FIRST, so it neither resets on a "zone change" nor scans and changes
        -- the abilities behind setStealth's back. Then Sneak and Hide CONFIRMED, five tries, standing still
        -- (v2.44 - 2.43 pressed them unchecked and level 10 Xanley died walking into North Qeynos).
        radiusWatchZoneId = mq.TLO.Zone.ID() or 0
        radiusWatchLatched = true
        radiusWatchKnownHostileZones[radiusWatchZoneId] = true
        if not setStealth(true, 5) then
            if running and not automation.stop and not mq.TLO.Me.Hovering() then
                print(string.format('\ar[Postmaster]\ax could not get sneaking and hidden where you arrived in %s after'
                    .. ' 5 tries - a level %d Goblin Rogue\'s Hide and Sneak fail often. Not walking in visible.',
                    h.npcZoneName, mq.TLO.Me.Level() or 0))
            end
            return false
        end
        print('\ag[Postmaster]\ax sneaking and hidden - going to ' .. h.npc .. '.')
    end
    if m and faction.distTo(m.waitY, m.waitX) > 150 then   -- 150: a landing spot varies a little
        -- The route still came in somewhere else. Walking from there could go straight through the city,
        -- past the very guards this mode exists to avoid - stop, and let the player move. The loc is printed
        -- so a miss teaches us where the route really came in.
        print(string.format('\ar[Postmaster]\ax arrived in %s %d away from the PoK book (you are at %.0f, %.0f) -'
            .. ' not walking through the city past the guards. Get to the book, then Run again.', h.npcZoneName,
            math.floor(faction.distTo(m.waitY, m.waitX)), mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0))
        return false
    end
    local landed, misses = false, 0
    while faction.count(h) > 0 and misses < 3 do
        if automation.stop or not running or mq.TLO.Me.Hovering() then break end
        if m and not faction.inMeetArea(h) then
            faction.backToWait(h)
            if not faction.waitForMeet(h) then
                if running and not automation.stop and not mq.TLO.Me.Hovering() then
                    print('\ar[Postmaster]\ax gave up waiting for ' .. h.npc .. ' to come out of the gates after 45 minutes.'
                        .. ' Nothing was lost - Run again later.')
                end
                break
            end
            faction.status = string.format("Taking %s to %s...", h.item, h.npc)
        end
        local before = faction.count(h)
        -- Up to four stacks in ONE trade (v2.43, AL: *"It should be a very fast inv pickup and turn in"*). One
        -- stack per trade meant a fresh approach per stack, and a run that gave a 250 stack - the buy's last,
        -- part-full batch, which the name lookup found first - then never got back for the 1000 beside it.
        approachAndInteract(h.npc, function()
            return giveItems({ h.item, h.item, h.item, h.item }, h.npc, stealthGive)
        end, stealthGive)
        waitUntil(function() return faction.count(h) < before end, 3000, 200)
        if faction.count(h) < before then
            faction.given = faction.given + (before - faction.count(h))
            landed, misses = true, 0
            if stealthGive then
                -- Only a sign of whether he is still hostile: a con made in a shroud does not show the character's
                -- real standing (v2.45 - see faction.run).
                local tier = faction.conTier(considerNpc(h.npc))
                print(string.format('\ay[Postmaster]\ax %d %s handed over - %s cons %s to the shroud (not your real'
                    .. ' standing - Check shows that after the camp).', faction.given, h.item, h.npc, tier or "?"))
            end
        else
            misses = misses + 1
            if mq.TLO.Window('GiveWnd').Open() then mq.cmd('/notify GiveWnd GVW_Cancel_Button leftmouseup') end
            if (mq.TLO.Cursor.ID() or 0) > 0 then mq.cmd('/autoinventory') end
            mq.delay(500)
        end
    end
    if misses >= 3 then
        printIfRunning('\ar[Postmaster]\ax ' .. h.npc .. ' did not take the ' .. h.item .. ' after 3 tries.')
    end
    -- Finish somewhere safe: back to the book, not standing in the field waiting for him to lead the next
    -- guard patrol over. Not after a death or a Stop - the player has the controls then.
    if m and running and not automation.stop and not mq.TLO.Me.Hovering() then
        faction.status = "Walking back to the PoK book..."
        faction.backToWait(h)
    end
    return landed
end

-- COIN HELPERS (v2.58) - money instead of items. MQ can READ money but has no command that moves it (its docs,
-- definitions and source all checked), so coins move the way a player moves them: click a money slot, type
-- how many, click where they go - and every move is judged by the COUNTS afterwards, never by the click.

-- Exactly n coins of one metal ("Platinum", "Gold"...) onto the cursor from a money slot, or none. The
-- quantity box is typed and must READ n before Accept: once in 255 gives (luatools/coingive, 2026-09-28) it
-- still held its default - the WHOLE purse - and 1,588 gold came up. The window has no Cancel; DoClose it.
function faction.coinPickUp(wnd, child, n, metal)
    local qty = mq.TLO.Window('QuantityWnd')
    local function onCursor() return mq.TLO.Me['Cursor' .. metal]() or 0 end
    mq.TLO.Window(wnd).Child(child).LeftMouseUp()
    mq.delay(2000, function() return qty.Open() == true or onCursor() > 0 end)
    if qty.Open() then
        local want, box = tostring(n), qty.Child('QTYW_SliderInput')
        for _ = 1, 3 do
            box.SetText(want)
            mq.delay(1000, function() return box.Text() == want end)
            if box.Text() == want then break end
        end
        if box.Text() == want then
            qty.Child('QTYW_Accept_Button').LeftMouseUp()
            mq.delay(2000, function() return onCursor() > 0 end)
        else
            qty.DoClose()
            mq.delay(1000, function() return not qty.Open() end)
        end
    end
    if onCursor() == n then return true end
    if onCursor() > 0 then
        mq.cmd('/autoinventory')   -- a wrong pile goes back in the purse - and is WAITED for
        mq.delay(3000, function() return onCursor() == 0 end)
    end
    return false
end

-- n coins from one money slot to another: purse and bank, either way. With the BANK window open, platinum
-- dropped on the purse's GOLD slot comes out as gold, 1 pp = 10 gp (AL, Live, 2026-09-28 - it works nowhere
-- else, and the bank's Change button goes the other way). The caller checks the counts.
function faction.coinMove(fromWnd, fromChild, toWnd, toChild, n, metal)
    n = math.floor(n)
    if n < 1 then return false end
    if not faction.coinPickUp(fromWnd, fromChild, n, metal) then return false end
    local function onCursor() return mq.TLO.Me['Cursor' .. metal]() or 0 end
    mq.TLO.Window(toWnd).Child(toChild).LeftMouseUp()
    mq.delay(3000, function() return onCursor() == 0 end)
    if onCursor() > 0 then
        mq.cmd('/autoinventory')
        mq.delay(3000, function() return onCursor() == 0 end)
        return false
    end
    return true
end

-- Gold in the purse up to `want`, at the OPEN bank (AL, 2026-09-28: fetched 2,000 platinum, reached Fabian with
-- no gold - "if I did this simple mistake users sure will"). The bank's gold first, then platinum broken into
-- gold, the purse's platinum before the bank's. Returns the purse's gold.
function faction.makeGold(want)
    local me = mq.TLO.Me
    local short = want - (me.Gold() or 0)
    if short > 0 and (me.GoldBank() or 0) >= 1 then
        faction.coinMove('BigBankWnd', 'BNK_Money1', 'InventoryWindow', 'IW_Money1', math.min(short, me.GoldBank() or 0), 'Gold')
        short = want - (me.Gold() or 0)
    end
    if short > 0 then
        local pp = math.ceil(short / 10)
        if (me.Platinum() or 0) < pp and (me.PlatinumBank() or 0) >= 1 then
            faction.coinMove('BigBankWnd', 'BNK_Money0', 'InventoryWindow', 'IW_Money0',
                math.min(pp - (me.Platinum() or 0), me.PlatinumBank() or 0), 'Platinum')
        end
        pp = math.floor(math.min(pp, me.Platinum() or 0))
        if pp > 0 then
            local before = me.Gold() or 0
            print(string.format('\ay[Postmaster]\ax you have %d platinum but %d gold - making change: %d platinum into'
                .. ' %d gold.', math.floor(me.Platinum() or 0), math.floor(before), pp, pp * 10))
            faction.coinMove('InventoryWindow', 'IW_Money0', 'InventoryWindow', 'IW_Money1', pp, 'Platinum')
            if (me.Gold() or 0) < before + pp * 10 then
                print('\ar[Postmaster]\ax the bank did not make change - the platinum is back in your purse.')
            end
        end
    end
    return me.Gold() or 0
end

-- The give loop (v2.58), from luatools/coingive - 88 gives a minute over 780 on Xanley. `gives` trades of
-- exactly h.perGive coins each: Fabian hands back anything else (80 gold), so one trade is one turn-in. The
-- give's own faction line is the proof it counted; a hand-back refills the purse and is tried again (Fabian
-- does it now and then). `masked`: the Sneak mask must hold - a dropped Sneak is put back ALONE, standing still
-- behind him (AL's decision 3), and the loop stops if it will not come back. Returns how many were paid, and
-- why it stopped early (nil when every give went over).
function faction.coinGive(h, gives, masked)
    local me = mq.TLO.Me
    local give = mq.TLO.Window('GiveWnd')
    local slot = 'IW_Money' .. faction.moneySlot[h.coin]
    local function purse() return me[h.coin]() or 0 end
    local function onCursor() return me['Cursor' .. h.coin]() or 0 end
    local npcId = mq.TLO.Spawn("npc " .. h.npc).ID() or 0
    local paidLines, done, backInRow, slipInRow, why = 0, 0, 0, 0, nil
    pcall(mq.unevent, 'PMCoinPaid')   -- a run that ended in an error could have left it registered
    mq.event('PMCoinPaid', 'Your faction standing with #*#', function() paidLines = paidLines + 1 end)
    mq.TLO.Window('InventoryWindow').DoOpen()
    mq.delay(2000, function() return mq.TLO.Window('InventoryWindow').Open() == true end)
    while done < gives do
        automation.hold()
        if not running or automation.stop or me.Hovering() or justFledCombat then break end
        if fleeIfInCombat() then why = "a fight started"; break end
        if purse() < h.perGive then why = "out of " .. h.unit; break end
        if masked and not me.Sneaking() then
            setStealth(true, 2, true)
            if not me.Sneaking() then why = "Sneak dropped and would not come back"; break end
        end
        if (mq.TLO.Target.ID() or 0) ~= npcId then
            mq.cmdf('/target id %d', npcId)
            mq.delay(1000, function() return (mq.TLO.Target.ID() or 0) == npcId end)
        end
        if (mq.TLO.Target.Distance() or 999) > 20 then why = h.npc .. " is out of reach"; break end

        local before = purse()
        if not faction.coinPickUp('InventoryWindow', slot, h.perGive, h.coin) then
            slipInRow = slipInRow + 1
            if slipInRow >= 3 then why = "the amount would not go onto the cursor, 3 times in a row"; break end
            mq.delay(1000)
        else
            slipInRow = 0
            mq.flushevents('PMCoinPaid')
            local paidBefore = paidLines
            mq.TLO.Target.LeftClick()
            mq.delay(3000, function() return give.Open() == true end)
            local presses = 0
            while give.Open() and presses < 12 do   -- one press does not always take
                mq.cmd('/notify GiveWnd GVW_Give_Button leftmouseup')
                mq.delay(500, function() return not give.Open() end)
                presses = presses + 1
            end
            if give.Open() or onCursor() > 0 then
                if give.Open() then mq.cmd('/notify GiveWnd GVW_Cancel_Button leftmouseup') end
                mq.delay(2000, function() return not give.Open() end)
                if onCursor() > 0 then mq.cmd('/autoinventory') end
                why = "a give did not complete"
                break
            end
            -- Paid (the faction line), or handed back (the purse refills).
            mq.delay(1500, function()
                mq.doevents('PMCoinPaid')
                return paidLines > paidBefore or purse() ~= before - h.perGive
            end)
            if purse() ~= before - h.perGive then
                backInRow = backInRow + 1
                if onCursor() > 0 then mq.cmd('/autoinventory') end
                if backInRow >= 5 then why = h.npc .. " handed it back 5 times in a row"; break end
                dbg(string.format('%s handed it back (%d in a row) - trying again.', h.npc, backInRow))
                mq.delay(2000)
            else
                backInRow = 0
                done = done + 1
                faction.status = string.format("Giving %s %d %s at a time - %d of %d...", h.npc, h.perGive, h.unit,
                    done, gives)
                mq.delay(100)
            end
        end
    end
    mq.unevent('PMCoinPaid')
    if onCursor() > 0 then mq.cmd('/autoinventory') end
    mq.TLO.Window('InventoryWindow').DoClose()
    return done, why
end

-- Travel to h.npc and run `giveFn(left)` at him - which returns how many gives landed and why it stopped early -
-- until `total` are done. v2.63 - IT CARRIES ON AFTER A FLEE, like every courier step (v2.50, AL: "carry on
-- automatically after a flee"): a fight, or a back-off because invis would not take by a patrol, and it gets clear,
-- rests to 80%, waits, puts invis back on and goes in again for what is left - five times at most. 2.62 stopped
-- instead (AL: a Militia Patrol Member at the zone-in, Hide failed, the run ended) - and in a shroud, where Run
-- could not start again. Returns how many landed, and why it stopped short (nil = all done).
function faction.goAndGive(h, total, giveFn, sneakAnyway)
    local done, why, flees = 0, nil, 0
    while done < total and running and not automation.stop and not mq.TLO.Me.Hovering() do
        why = nil
        local landed = 0
        if travelToZone(h.npcZone, h.npc) then
            approachAndInteract(h.npc, function()
                local w
                landed, w = giveFn(total - done)
                why = w
                return landed > 0
            end, false, false, sneakAnyway, h.spot)
            done = done + landed
        elseif not justFledCombat then
            return done, "could not get to " .. h.npcZoneName
        end
        if not justFledCombat then break end
        flees = flees + 1
        if flees > 5 then
            return done, "backed off 5 times - a fight, or invis would not take - something there catches you every time"
        end
        if not automation.recoverFromFlee(flees > 1) then return done, why or "could not get clear of it" end
    end
    if done == 0 and not why and running and not automation.stop and not mq.TLO.Me.Hovering() then
        why = "could not reach " .. h.npc
    end
    return done, why
end

-- One trip for a coin helper (v2.58). `need` = the coins the goal wants. Returns nil when a trip as yourself
-- landed - faction.run reads the window again and decides - or an outcome: "given" after a shrouded trip
-- (read after Unshroud and a camp, like Bone Chips), or why it stopped.
function faction.coinTrip(h, word, danger, need)
    local me = mq.TLO.Me
    local lvl = me.Level() or 0
    -- WHO GOES HOW. Openly only if his quest will deal with you (Indifferent) AND the guards round him will not
    -- attack. Otherwise the Sneak mask: a Rogue wears their own (AL's decision 1); an evil race from level 5
    -- takes the Goblin Rogue shroud, the one the Bone Chips hidden give uses.
    local mode
    if (faction.rank(word) or 0) >= faction.rank("Indifferent") and not faction.hostile(danger) then
        mode = "open"
    elseif (me.Class.ShortName() or "") == "ROG" then
        mode = "sneak"
    elseif factionRisk and lvl >= 5 and lvl < tuning.shroudLevel then
        mode = "shroud"
    else
        return string.format("%s deals only with %s Indifferent, and %s round him is %s - that needs the Sneak mask:"
            .. " a Rogue's own, or a Goblin Rogue shroud%s", h.npc, h.faction, h.danger, tostring(danger),
            lvl < 5 and " from level 5" or "")
    end
    local coins = math.ceil(need / h.perGive) * h.perGive   -- whole gives
    print(string.format('\ay[Postmaster]\ax %s: about %d %s (%d gives) - %s.', h.title, coins, h.unit,
        coins / h.perGive,
        mode == "open" and "walking up to " .. h.npc .. " openly"
            or mode == "sneak" and "sneaking up behind " .. h.npc .. " as yourself"
            or "taking a Goblin Rogue shroud (your coins go with you) and sneaking up behind " .. h.npc))

    -- THE MONEY, as yourself: short of gold, the bank makes it up. v2.62 - A PoK SHROUD KEEPS THE COINS YOU CARRY
    -- (AL: the game changed this; long ago money had to go through the bank, and mission shrouds differ), so the gold
    -- just travels in the purse - 2.58-2.61 banked it and took it back out as the shroud, for nothing.
    automation.noShroud = true
    if (me[h.coin]() or 0) < coins then
        faction.status = "At the bank, sorting out the gold..."
        if not faction.openBank() then
            automation.noShroud = false
            if automation.stop or not running then return nil end
            return "could not get to " .. faction.banker .. " in PoK to sort out the gold"
        end
        mq.TLO.Window('InventoryWindow').DoOpen()
        mq.delay(2000, function() return mq.TLO.Window('InventoryWindow').Open() == true end)
        faction.makeGold(coins)
        faction.closeBank()
    end
    automation.noShroud = false
    if automation.stop or not running then return nil end
    if mode == "shroud" then
        ensureShroud(true)
        if not me.Shrouded() then return "could not take the Goblin Rogue shroud" end
    end

    local gives = math.floor(math.min(coins, me[h.coin]() or 0) / h.perGive)
    if gives < 1 then
        return string.format("you need %d gold - on you and in the bank there is %d gold and %d platinum", coins,
            math.floor((me.Gold() or 0) + (me.GoldBank() or 0)), math.floor((me.Platinum() or 0) + (me.PlatinumBank() or 0)))
    end
    if gives * h.perGive < coins then
        print(string.format('\ay[Postmaster]\ax only %d %s to hand over - going with that (%d wanted).',
            gives * h.perGive, h.unit, coins))
    end

    faction.status = string.format("Taking %d %s to %s...", gives * h.perGive, h.unit, h.npc)
    -- Not `keepHidden`: in the mask, approachAndInteract drops Hide ONLY at his back and keeps Sneak - exactly
    -- AL's hand-over. A trade would drop Hide anyway. goAndGive carries on after a flee (v2.63).
    local done, why = faction.goAndGive(h, gives, function(left)
        return faction.coinGive(h, left, mode ~= "open")
    end, mode == "sneak")
    faction.given = faction.given + done * h.perGive
    faction.planGave(h, done * h.perGive)
    if mode == "shroud" then
        if done > 0 then
            if why then print('\ay[Postmaster]\ax ' .. h.title .. ' stopped early: ' .. why .. '.') end
            return "given"
        end
        return why
    end
    return why
end

-- LOOP HELPERS (v2.60) - many trades of a few items, bought where the NPC stands (Palatos's Ale). From
-- luatools/itemgive, proven on Xanley: 25 turn-ins, 3.3 s each, 25 Lore beacons destroyed, nothing handed back.

-- Up to 10 stacks of h.item from h.shop, standing where we are (he must be within 20 - `spot` puts us there),
-- keeping three bag slots free. Each stack confirmed by the COUNT. Targets h.npc again after. Returns how many
-- arrived, and why none did.
function faction.restock(h)
    local shop = mq.TLO.Spawn("npc " .. h.shop)
    if (shop.ID() or 0) == 0 then return 0, h.shop .. " is not here" end
    if (shop.Distance() or 999) > 20 then
        return 0, string.format("%s is %d away from here - out of reach for his shop", h.shop, math.floor(shop.Distance() or 0))
    end
    local got, why = 0, nil
    mq.cmdf('/target id %d', shop.ID())
    mq.delay(1000, function() return (mq.TLO.Target.ID() or 0) == shop.ID() end)
    mq.cmd('/click right target')
    mq.delay(5000, function() return mq.TLO.Merchant.Open() == true end)
    if not mq.TLO.Merchant.Open() then
        why = h.shop .. "'s shop did not open"
    else
        mq.delay(5000, function() return mq.TLO.Merchant.ItemsReceived() == true end)
        for _ = 1, 3 do
            mq.TLO.Merchant.SelectItem('=' .. h.item)()
            mq.delay(1500, function() return mq.TLO.Merchant.SelectedItem.Name() == h.item end)
            if mq.TLO.Merchant.SelectedItem.Name() == h.item then break end
        end
        if mq.TLO.Merchant.SelectedItem.Name() ~= h.item then
            why = h.shop .. " does not sell " .. h.item
        else
            local stack = math.max(mq.TLO.Merchant.SelectedItem.StackSize() or 1, 1)
            local before = faction.count(h)
            for _ = 1, 10 do
                if (mq.TLO.Me.FreeInventory() or 0) < 3 then break end
                local want = faction.count(h) + stack
                mq.TLO.Merchant.Buy(stack)()
                mq.delay(4000, function() return faction.count(h) >= want end)
                if faction.count(h) < want then break end   -- nothing arrived (money?) - stop spending blind
            end
            got = faction.count(h) - before
            if got == 0 then why = "could not buy " .. h.item .. " from " .. h.shop .. " - out of money, or bags full" end
        end
        mq.cmd('/notify MerchantWnd MW_Done_Button leftmouseup')
        mq.delay(2000, function() return not mq.TLO.Merchant.Open() end)
    end
    mq.cmdf('/target id %d', mq.TLO.Spawn("npc " .. h.npc).ID() or 0)
    mq.delay(1000)
    if got > 0 then print(string.format('\ag[Postmaster]\ax bought %d %s from %s.', got, h.item, h.shop)) end
    return got, why
end

-- Exactly n of h.item onto the cursor, or none - through the quantity box, typed and READ back before Accept.
function faction.itemPickUp(h, n)
    local qty = mq.TLO.Window('QuantityWnd')
    local function onCursor() return mq.TLO.Cursor.Name() == h.item end
    mq.cmdf('/nomodkey /itemnotify "%s" leftmouseup', h.item)
    mq.delay(2000, function() return qty.Open() == true or onCursor() end)
    if qty.Open() then
        local want, box = tostring(n), qty.Child('QTYW_SliderInput')
        for _ = 1, 3 do
            box.SetText(want)
            mq.delay(1000, function() return box.Text() == want end)
            if box.Text() == want then break end
        end
        if box.Text() ~= want then
            qty.DoClose()
            mq.delay(1000, function() return not qty.Open() end)
            return false
        end
        qty.Child('QTYW_Accept_Button').LeftMouseUp()
        mq.delay(2000, onCursor)
    end
    if onCursor() and (mq.TLO.Cursor.Stack() or 1) == n then return true end
    if (mq.TLO.Cursor.ID() or 0) > 0 then
        mq.cmd('/autoinventory')
        mq.delay(2000, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
    end
    return false
end

-- DESTROYS every h.destroy carried - a LORE reward that blocks the next turn-in (Palatos's Beacon Mount, which
-- lands in the bags). The ONLY item this script destroys, and only with that exact name on the cursor and NO
-- coins held in the instant before: MQ's /destroy is EQDestroyHeldItemOrMoney - it destroys held coins too.
-- Returns false if one is still there.
function faction.destroyReward(h)
    local me = mq.TLO.Me
    local function coins()
        return (me.CursorPlatinum() or 0) + (me.CursorGold() or 0) + (me.CursorSilver() or 0) + (me.CursorCopper() or 0) > 0
    end
    for _ = 1, 5 do
        if mq.TLO.Cursor.Name() ~= h.destroy then
            if (mq.TLO.FindItemCount('=' .. h.destroy)() or 0) == 0 then return true end
            if (mq.TLO.Cursor.ID() or 0) > 0 then
                mq.cmd('/autoinventory')
                mq.delay(2000, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
            end
            mq.cmdf('/nomodkey /itemnotify "%s" leftmouseup', h.destroy)
            mq.delay(2000, function() return mq.TLO.Cursor.Name() == h.destroy end)
        end
        if mq.TLO.Cursor.Name() ~= h.destroy or coins() then return false end
        mq.cmd('/destroy')
        mq.delay(2000, function() return mq.TLO.Cursor.Name() ~= h.destroy end)
    end
    return (mq.TLO.FindItemCount('=' .. h.destroy)() or 0) == 0 and mq.TLO.Cursor.Name() ~= h.destroy
end

-- The give loop: `trades` turn-ins of exactly h.perTrade, the reward destroyed before and after each, restocked
-- from h.shop when fewer than one trade's worth is left. `masked`: Sneak must hold - put back ALONE if it drops
-- (Hide off at his back, as with Fabian). A trade whose items come back stops it. Returns turn-ins, and why it
-- stopped early (nil = all done).
function faction.itemLoop(h, trades, masked)
    local me = mq.TLO.Me
    local give = mq.TLO.Window('GiveWnd')
    local npcId = mq.TLO.Spawn("npc " .. h.npc).ID() or 0
    local done, why = 0, nil
    while done < trades do
        automation.hold()
        if not running or automation.stop or me.Hovering() or justFledCombat then break end
        if fleeIfInCombat() then why = "a fight started"; break end
        if masked and not me.Sneaking() then
            setStealth(true, 2, true)
            if not me.Sneaking() then why = "Sneak dropped and would not come back"; break end
        end
        if faction.count(h) < h.perTrade then
            faction.status = string.format("Buying %s from %s...", h.item, h.shop)
            local _, whyNot = faction.restock(h)
            if faction.count(h) < h.perTrade then why = whyNot or ("out of " .. h.item); break end
        end
        if not faction.destroyReward(h) then why = "could not destroy the " .. h.destroy .. " - it blocks the next turn-in"; break end
        if (mq.TLO.Target.ID() or 0) ~= npcId then
            mq.cmdf('/target id %d', npcId)
            mq.delay(1000, function() return (mq.TLO.Target.ID() or 0) == npcId end)
        end
        if (mq.TLO.Target.Distance() or 999) > 20 then why = h.npc .. " is out of reach"; break end

        local before = faction.count(h)
        if not faction.itemPickUp(h, h.perTrade) then why = "could not put exactly " .. h.perTrade .. " on the cursor"; break end
        mq.TLO.Target.LeftClick()
        mq.delay(3000, function() return give.Open() == true end)
        local presses = 0
        while give.Open() and presses < 12 do   -- one press does not always take
            mq.cmd('/notify GiveWnd GVW_Give_Button leftmouseup')
            mq.delay(500, function() return not give.Open() end)
            presses = presses + 1
        end
        if give.Open() or mq.TLO.Cursor.Name() == h.item then
            if give.Open() then mq.cmd('/notify GiveWnd GVW_Cancel_Button leftmouseup') end
            mq.delay(2000, function() return not give.Open() end)
            if (mq.TLO.Cursor.ID() or 0) > 0 then mq.cmd('/autoinventory') end
            why = "a trade did not complete"
            break
        end
        -- The reward lands a moment after the trade; destroy it, then judge by the count.
        mq.delay(2000, function() return (mq.TLO.FindItemCount('=' .. h.destroy)() or 0) > 0 end)
        faction.destroyReward(h)
        if (mq.TLO.Cursor.ID() or 0) > 0 then mq.cmd('/autoinventory') end
        if faction.count(h) >= before then why = h.npc .. " handed them back"; break end
        done = done + 1
        faction.given = faction.given + h.perTrade
        faction.status = string.format("Giving %s %d %s at a time - %d of %d...", h.npc, h.perTrade, h.item, done, trades)
        mq.delay(200)
    end
    return done, why
end

-- One trip for a loop helper (v2.60). `need` = items the goal wants. Returns nil when a trip as yourself landed
-- (faction.run reads again), or an outcome: "given" after a shrouded trip, or why it stopped.
function faction.loopTrip(h, danger, npcWord, need)
    local me = mq.TLO.Me
    local lvl = me.Level() or 0
    -- AN NPC HOSTILE TO YOU IN THE SAME ROOM SEES THROUGH SNEAK at that range (Guard Raflin killed a sneaking
    -- Xanley). Canlan Talespinner stands beside Palatos - so the helper that fixes his faction goes first.
    if faction.hostile(danger) then
        return string.format("%s (%s) stands in %s's room and reads %s to you - close up, a hostile NPC sees through"
            .. " Sneak. Run %s first", h.dangerNpc, h.danger, h.npc, danger, h.dangerFix)
    end
    local mode
    if not faction.hostile(npcWord) then
        mode = "open"
    elseif (me.Class.ShortName() or "") == "ROG" then
        mode = "sneak"
    elseif factionRisk and lvl >= 5 and lvl < tuning.shroudLevel then
        mode = "shroud"
    else
        return string.format("%s reads %s to you (%s) and attacks on sight - that needs the Sneak mask: a Rogue's own,"
            .. " or a Goblin Rogue shroud%s", h.npc, tostring(npcWord), h.npcFaction, lvl < 5 and " from level 5" or "")
    end
    local trades = math.floor(need / h.perTrade)

    -- THE MONEY - none of it planned ahead any more (v2.64, AL: "why are we running to Berina to check the price of
    -- the Ale? What is the point of this?"). 2.60 read the price in PoK because the shroud had to carry banked
    -- platinum it could not come back for; since 2.62 a PoK shroud keeps your coins, and the ale costs coppers. So
    -- the ale is simply bought from h.shop as it goes, and if the money ever runs out the loop says so - Run then
    -- carries on after a top-up (faction.plan).
    print(string.format('\ay[Postmaster]\ax %s: %d %s (%d turn-ins), bought from %s beside him as it goes.', h.title,
        need, h.item, trades, h.shop))
    if (me.Cash() or 0) == 0 and faction.count(h) < h.perTrade then
        return "no money on you to buy " .. h.item .. " with - take some platinum from your bank, then Run"
    end

    if mode == "shroud" then
        ensureShroud(true)
        if not me.Shrouded() then return "could not take the Goblin Rogue shroud" end
    end

    faction.status = string.format("Going to %s...", h.npc)
    -- Not `keepHidden`: at his back, Hide off and Sneak on for the trades - AL's method, as with Fabian.
    -- goAndGive carries on after a flee or a back-off (v2.63) - 2.62 stopped here, shrouded, at a patrol.
    local done, why = faction.goAndGive(h, trades, function(left)
        return faction.itemLoop(h, left, mode ~= "open")
    end, mode == "sneak")
    faction.planGave(h, done * h.perTrade)
    if mode == "shroud" then
        if done > 0 then
            if why then print('\ay[Postmaster]\ax ' .. h.title .. ' stopped early: ' .. why .. '.') end
            return "given"
        end
        return why
    end
    return why
end

-- The Unshroud button (v2.41, AL): to Shroudkeeper Hyush in PoK and say "remove". Main loop only.
function faction.unshroudNow(i)
    faction.last, faction.active, faction.given = i, i, 0
    automation.stop, automation.paused = false, false
    if not mq.TLO.Me.Shrouded() then
        faction.status = "You are not shrouded."
    else
        faction.status = "Going to Shroudkeeper Hyush to remove the shroud..."
        if travelToZone(zones.pokShort, "Shroudkeeper Hyush") and navToNpc("Shroudkeeper Hyush") then
            mq.cmd('/makemevisible')   -- a say does not register while hidden
            mq.delay(500)
            sayPhrase("Shroudkeeper Hyush", "remove")
            waitUntil(function() return not mq.TLO.Me.Shrouded() end, 15000, 500)
        end
        if automation.stop then
            faction.status = "Stopped."
        elseif mq.TLO.Me.Shrouded() then
            faction.status = "Still shrouded - say \"remove\" to Shroudkeeper Hyush in PoK."
            printIfRunning('\ar[Postmaster]\ax ' .. faction.status)
        else
            faction.status = "Shroud removed. Camp to character select and come back before Run or Check -"
                .. " EQ keeps your Faction window empty after a shroud until you do."
            print('\ag[Postmaster]\ax shroud removed. \ayCamp to character select and come back before Run or Check\ax -'
                .. ' EQ keeps your Faction window empty after a shroud until you do.')
        end
    end
    faction.active = nil
    automation.stop, automation.paused = false, false
end

-- One helper, start to finish: read -> buy if the bags are empty -> give a stack -> read again, until the
-- goal tier is reached, the standing stops moving, or something needs the player. Main loop only.
-- v2.41: when the NPC himself is hostile it is ONE shrouded trip instead (see the hostile branch).
function faction.run(i)
    local h = faction.helpers[i]
    local goal = faction.goalFor(h)
    automation.stop, automation.paused = false, false
    -- v2.58: a run starts with no flee on the books. retryStep clears it for the courier steps, but a faction run
    -- never passes through retryStep - so a fight in one left it set, and the next faction run's fleeIfInCombat
    -- (idempotent: "already fleeing") would have ignored a NEW fight.
    justFledCombat = false
    faction.active, faction.given, faction.banked = i, 0, 0
    local outcome, word, lastStanding = nil, nil, nil
    for round = 1, 12 do   -- a round is one vendor trip + one visit; even Ally from nothing needs one if bags allow
        -- v2.41 (AL): a run starts as YOURSELF. A shroud empties the Faction window, so nothing could be read.
        if mq.TLO.Me.Shrouded() then
            -- v2.63: EXCEPT a coin or loop run already sized as yourself - it carries on with what is left (AL's 2.62
            -- run ended shrouded at a patrol, and Run refused to go on).
            local p = faction.plan
            if round == 1 and (h.coin or h.loop) and p and p.key == h.key and p.need > 0 then
                print(string.format('\ay[Postmaster]\ax %s: carrying on the run you started as yourself - about %d %s'
                    .. ' left.', h.title, p.need, h.item or h.unit))
                if h.coin then
                    outcome = faction.coinTrip(h, p.word, p.danger, p.need)
                else
                    outcome = faction.loopTrip(h, p.danger, p.npcWord, p.need)
                end
                outcome = outcome or "given"
                break
            end
            outcome = "you are shrouded - a run starts as yourself. Press Unshroud, then camp to character select"
                .. " and come back (EQ keeps the Faction window empty after a shroud until you do), then Run"
            break
        end
        faction.status = "Reading " .. h.faction .. "..."
        local standing, danger, npcWord
        word, standing, danger, npcWord = faction.refresh(h)
        if automation.stop or not running then break end
        if not word then
            outcome = faction.empty and faction.emptyWhy() or ("could not read " .. h.faction .. " from the Faction window")
            break
        end
        if not faction.rank(word) then outcome = "does not recognise the reaction \"" .. word .. "\""; break end
        if faction.rank(word) >= faction.rank(goal) then outcome = "done"; break end
        local need = faction.estimate(h, standing, goal)
        -- v2.58: below the goal with nothing left to give = the +2,000 earned cap. More of this quest cannot help.
        if need == 0 then
            outcome = standing >= 2000
                and string.format("%s is %s with the earned standing at its +2,000 cap - this quest cannot take it"
                    .. " to %s", h.faction, word, goal)
                -- v2.61: this said "camp, come back and Check" - wrong advice: the one time it showed, the cause was
                -- the race read from a shroud (fixed in the main loop). Say what the numbers used, so a report can tell.
                or string.format("%s reads %s, short of %s, though its numbers say it should be there (earned %d,"
                    .. " adjustments %d for %s / %s / %s) - press Check; if it stays, please report this line",
                    h.faction, word, goal, standing, faction.adjustFor(h), myRace, mq.TLO.Me.Class.Name() or "?",
                    tostring(mq.TLO.Me.Deity() or "?"))
            break
        end
        local want = need and (math.ceil(need * 1.1) + 10) or 200   -- 10% over: another trip costs far more
        if h.perSet then want = math.ceil(want / h.perSet) * h.perSet end   -- v2.59: whole sets (Lady Shae's 4)
        if round == 1 and need then
            print(string.format('\ag[Postmaster]\ax %s is %s - about %d %s to reach %s.', h.faction, word, need,
                h.item or h.unit, goal))
        end
        -- v2.58 - A COIN HELPER takes its own path (faction.coinTrip): the money, who goes how, the give loop.
        -- As yourself it comes back here to read again; a shrouded trip ends like Bone Chips' ("given").
        -- v2.60: a LOOP helper (many trades of a few items bought beside the NPC - Palatos's Ale) the same way.
        if h.coin or h.loop then
            if not need then outcome = "could not read the earned standing, so the trip cannot be sized"; break end
            if lastStanding and standing <= lastStanding then
                outcome = h.faction .. " did not go up after the last trip - it may be as high as this quest takes it"
                break
            end
            lastStanding = standing
            faction.plan = { key = h.key, need = need, word = word, danger = danger, npcWord = npcWord }   -- v2.63
            if h.coin then
                outcome = faction.coinTrip(h, word, danger, need)
            else
                outcome = faction.loopTrip(h, danger, npcWord, need)
            end
            if outcome or automation.stop or not running then break end
        else
            -- v2.36: the NPC we give to must not want us dead - Lashun (Priests of Life, Scowls) killed a level 1
            -- Iksar that reached him safely past the guards. If he is hostile the items can only go over while
            -- hidden, which needs a shroud: an evil race from level 5 to under tuning.shroudLevel gets one.
            -- v2.41, AL's design - ONE TRIP. In a shroud the Faction window is empty (and stays empty until a camp)
            -- and nothing can be bought, so there is no reading between rounds and no second visit to the vendor.
            -- Everything the Stop at goal needs is bought and banked as yourself, the shroud takes exactly that
            -- back out, goes straight to him and hands it ALL over in one trade, conning him after it. The result is
            -- read by the player's Check after unshrouding and camping - never in the shroud (v2.45, below).
            -- v2.59: ALSO when the GUARDS round a helper NPC are hostile and there is no safe meeting spot (`meet` -
            -- Lashun has one). Lady Shae only glowers, but West Freeport's Militia attack Xanley on sight; before
            -- this, the item path would have walked him in visible.
            if faction.hostile(npcWord) or (faction.hostile(danger) and not h.meet) then
                local who = faction.hostile(npcWord) and string.format("%s reads %s to you (%s)", h.npc, npcWord, h.npcFaction)
                    or string.format("%s round %s reads %s", h.danger, h.npc, danger)
                local lvl = mq.TLO.Me.Level() or 0
                if not (factionRisk and lvl >= 5 and lvl < tuning.shroudLevel) then
                    outcome = string.format("%s and attacks on sight, so nothing can be handed"
                        .. " over openly - only while hidden, which needs a Goblin Rogue shroud (level 5+). %s", who,
                        lvl < 5 and "Come back at level 5"
                            or "Take a Goblin Rogue shroud from Shroudkeeper Hyush in PoK and hand them over hidden yourself")
                    break
                end
                print(string.format('\ay[Postmaster]\ax %s and attacks on sight - one trip: buy them'
                    .. ' all as yourself, bank them, shroud, and hand them over hidden.', who))
                local ok, why = faction.bankAndShroud(h, want, goal)
                if not ok then outcome = why; break end
                faction.status = string.format("Taking %d %s to %s, shrouded...", faction.count(h), h.item, h.npc)
                local landed = faction.give(h, false, true)
                if automation.stop or not running then break end
                -- v2.44: 2.43 broke out here with no outcome after a death and said "too many rounds".
                if mq.TLO.Me.Hovering() then outcome = "you died on the way to " .. h.npc; break end
                if not landed then outcome = "could not give " .. h.item .. " to " .. h.npc; break end
                -- v2.45: NO goal reading in a shroud. 2.41-2.44 read it off a nearby guard's con; on Xanley the cons
                -- right after the give said Indifferent where the window, after the camp, said Amiably (standing
                -- 1629) - a value no number of chips can give both factions at once under his real adjustments -
                -- while his own cons as himself matched the window exactly (AL, 2026-09-27). The camp is needed to
                -- see the Faction window again anyway, so Check after it is the one true reading.
                outcome = "given"
                break
            end
            -- The one number we can read tells us whether the last give landed. If it did not move, more of
            -- the same will not either - say so rather than buying and walking round in circles.
            if lastStanding and standing and standing <= lastStanding then
                outcome = h.faction .. " did not go up after the last give - it may be as high as this quest takes it"
                break
            end
            lastStanding = standing
            local careful = faction.hostile(danger) and h.meet ~= nil
            if round == 1 and faction.hostile(danger) then
                print(string.format('\ar[Postmaster]\ax %s reads %s - the guards on the way to %s will attack you on sight%s.',
                    h.danger, danger, h.npc, careful and ' - so this run meets him out in the field, away from them'
                        or ', and you are not shrouded'))
            end
            -- SUPPLY (v2.39, AL: *"Do we need personal inv, and bank check and then buy if we need more for desired
            -- 'Stop At' selection? Plus user notice what is happening."*). Count the bags and the personal bank
            -- against what the goal wants and SAY so; then top up from the bank first (free), and buy only the rest.
            local short = faction.stockLine(h, want, goal)   -- said every round, "enough" too
            if faction.count(h) < want then
                if faction.bankCount(h) > 0 then
                    faction.status = string.format("Taking %s out of the bank...", h.item)
                    if faction.openBank() then faction.withdraw(h) end
                    faction.closeBank()
                end
                if short > 0 then
                    faction.status = string.format("Buying %d %s in the %s...", short, h.item, h.vendorWhere)
                    faction.buy(h, short)
                end
                if faction.count(h) == 0 then outcome = "could not buy " .. h.item; break end
            end
            faction.status = string.format("Taking %s to %s...", h.item, h.npc)
            if not faction.give(h, careful, false) then outcome = "could not give " .. h.item .. " to " .. h.npc; break end
        end
    end

    -- Leave nothing half-done on screen: a shop, bank or give window open, or an item on the cursor.
    automation.noShroud = false   -- belt and braces: never leave travel unable to shroud
    faction.closeBank()
    if mq.TLO.Merchant.Open() then mq.cmd('/notify MerchantWnd MW_Done_Button leftmouseup') end
    if mq.TLO.Window('GiveWnd').Open() then mq.cmd('/notify GiveWnd GVW_Cancel_Button leftmouseup') end
    if (mq.TLO.Cursor.ID() or 0) > 0 then mq.cmd('/autoinventory') end

    -- v2.59: A SHROUDED TRIP ENDS BY LEAVING - back to PoK, where Unshroud is - not standing at the NPC with Hide
    -- dropped by the trade. At Lady Shae's (AL, 2026-09-28) Guard Raflin walked up to a sneaking Xanley after a
    -- trade and killed him: a close hostile NPC sees through Sneak alone. Invis back on first, standing still.
    if outcome == "given" and running and not automation.stop and not mq.TLO.Me.Hovering() and not justFledCombat
        and mq.TLO.Me.Shrouded() then
        faction.status = "Handed over - leaving for PoK..."
        if not (mq.TLO.Me.Sneaking() and mq.TLO.Me.Invis()) then setStealth(true, 3) end
        travelToZone(zones.pokShort, "Shroudkeeper Hyush")
    end

    if not running then
        faction.status = ""
    elseif automation.stop then
        mq.cmd('/nav stop')
        mq.cmd('/travelto stop')
        faction.status = "Stopped."
        print('\ay[Postmaster]\ax ' .. h.title .. ' stopped.')
    elseif outcome == "done" then
        if faction.plan and faction.plan.key == h.key then faction.plan = nil end   -- v2.63: nothing left to carry on
        faction.status = string.format("Done - %s is %s.", h.faction, word)
        print(string.format('\ag[Postmaster]\ax %s: %s is now %s.', h.title, h.faction, word))
        ui.announce(nil, h.faction .. " is now " .. word .. ".")
    elseif outcome == "given" then
        -- The shrouded trip finished. Its result cannot be read in a shroud (see above), so it is not a failure
        -- and gets no alarm - just the one step left, which is the player's.
        faction.status = string.format("Gave %d %s to %s. Press Unshroud, camp to character select, come back,"
            .. " then Check.", faction.given, h.item or h.unit, h.npc)
        print(string.format('\ag[Postmaster]\ax %s: gave %d %s to %s. In a shroud your standing cannot be read -'
            .. ' the Faction window is empty, and a con taken sneaking reads everyone Indifferent.', h.title,
            faction.given, h.item or h.unit, h.npc))
        ui.announce(nil, faction.given .. " " .. (h.item or h.unit) .. " handed over.")
    else
        outcome = outcome or "too many rounds without reaching the goal"
        faction.status = "Stopped: " .. outcome .. "."
        -- "Bone Chips stopped: could not buy Bone Chips." - v2.29 read "Bone Chips could not buy Bone Chips."
        print('\ar[Postmaster]\ax ' .. h.title .. ' stopped: ' .. outcome .. '.')
        ui.announce("alert.wav", h.title .. " stopped.<silence msec='250'/> Postmaster is waiting for you.", true)
    end
    -- After the shrouded trip, whatever the outcome: the one step left is the player's.
    if running and faction.given > 0 and mq.TLO.Me.Shrouded() then
        print('\ay[Postmaster]\ax Next: press Unshroud, then camp to character select and come back - EQ keeps your'
            .. ' Faction window empty after a shroud until you do.')
    end
    faction.active = nil
    automation.stop, automation.paused = false, false
end

-- UI

local function coloredText(r, g, b, txt)
    imgui.PushStyleColor(ImGuiCol.Text, r, g, b, 1)
    imgui.Text(txt)
    imgui.PopStyleColor()
end

-- Pulses a button's colors to draw the eye to it - wrap ONLY the one button that represents "what to
-- click right now" in the currently-active accordion section. Push/pop are always paired (both gated on
-- the same activeSection check, which doesn't change mid-frame) so the style stack can't unbalance.
-- All redesigned-UI state and helpers hang off this ONE table on purpose. It breaks the usual "no
-- variable tables" preference for a hard technical reason: Lua caps any single function at 200
-- locals, and this file's main chunk sits close enough to that ceiling that declaring the art
-- loader, the four tab renderers and their helpers as separate locals fails to compile outright
-- ("too many local variables"). One namespace costs one local instead of fourteen.
-- Destination clusters, derived from DELIVERIES rather than hardcoded - one cluster is exactly the
-- unit a single "Run next batch" click handles (every pickup for that city, then one delivery trip),
-- so the Deliveries tab groups by the same thing the automation actually does.
ui.clusters = {}
do
    local byCity = {}
    for i, d in ipairs(DELIVERIES) do
        if not byCity[d.city] then
            byCity[d.city] = { city = d.city, rows = {} }
            ui.clusters[#ui.clusters + 1] = byCity[d.city]
        end
        table.insert(byCity[d.city].rows, i)
    end
end

-- Atlas regions: pixel rects inside a 1024x1024 POWER-OF-TWO sheet. Non-POT sheets get silently
-- padded by CreateTexture while the UV math still divides by the source size, so every crop lands
-- somewhere wrong - that cost an evening in postmaster_uitest.
ui.ART = {
    banner     = { 17,  677, 1008, 1008 },   -- the wide lantern/scroll/parcels desk scene (~3:1)
    parcel     = { 48,  45,  348,  306 },    -- tied parcel
    seal_closed = { 338, 40,  657,  315 },   -- intact wax seal (a finished/sealed step)
    -- Unfinished wax blob: the mockup's postmark seal with a bite cut out of the lower right, its
    -- stamped emblem smoothed away (invisible at 16px anyway, and an UNstamped blob is what
    -- "unfinished" should read as), and warmed to the atlas seals' own wax tone - measured, R x1.231
    -- G x1.501 B x1.393. This replaced the old `seal_open` scene art, which read as a broken ring
    -- rather than incomplete wax; that region has been cleared out of the atlas entirely.
    wax        = { 20,  316, 138,  434 },
    quill      = { 16,  440, 348,  679 },    -- quill + inkpot
    lantern    = { 425, 305, 691,  648 },    -- brass lantern
    -- Stack of gold coins for the tax list. NOT from the generated scene - that art has wax seals
    -- and stamps but no money - so this is FontAwesome's `coins` glyph (U+F51E) rendered to a PNG
    -- and composited into an unused block of the atlas, using the gold-over-dark-stroke treatment
    -- the wordmark uses. Rendering a glyph to a PNG is the only route for anything MQ's
    -- bundled icon font lacks, since the Lua binding cannot load a TTF at runtime.
    coins      = { 716, 332, 951,  568 },
    envelope   = { 716, 578, 828,  664 },    -- fa-envelope, same treatment; for delivery rows
    -- Footer art, both lifted from the mockup and edge-feathered so they dissolve into the window's
    -- own dark ground rather than showing as cut rectangles. Keyed on brightness at first, which
    -- washed both out badly - the wax and cord are DARKER than the parchment, so they went
    -- transparent along with the background. Feathering the outer edge only is what worked.
    letter     = { 712, 50,  860,  198 },    -- sealed letter, mockup top-left
    postmark   = { 144, 320, 424,  401 },    -- wax seal + cancellation lines, mockup bottom-right
}
-- Both glyph blocks sit ABOVE the banner region, which starts at y=677. Anything composited into
-- this atlas must be checked against that: an early attempt put the envelope at y=580 without
-- checking its rendered height (129px), which ran it to y=709 and painted over the banner art. The
-- generator asserts the clearance now, and `design/atlas_ledger.png` (1254x1254) is the untouched
-- master to rebuild from if the shipping atlas is ever damaged again.
ui.tex = nil       -- nil = not tried yet, a texture = loaded, false = missing (header omits the art)
ui.wmTex = nil     -- same tri-state, for the baked wordmark
ui.minimized = false  -- `_` drops to the mini badge; distinct from `hidden`, which /postmaster toggles

-- ImAnim is MQ's animation library. Loaded through pcall so a missing/renamed library degrades to a
-- static lantern instead of killing the whole UI. The do-block keeps its two temporaries out of the
-- main chunk's local budget (this file sits near Lua's 200-local ceiling).
do
    local ok, lib = pcall(require, 'ImAnim')
    ui.anim = ok and lib or nil
end
ui.flickerId = ImHashStr and ImHashStr('postmaster_lantern') or 1
ui.leanId    = ImHashStr and ImHashStr('postmaster_lantern_lean') or 2

-- Theme: a warm brass-on-dark-brown set pulled from the banner art itself (lantern brass, parchment,
-- wax, aged wood) so the widgets sit in the same world as the picture instead of floating on ImGui
-- default blue-grey. Structure copied from croakwatch's THEMES: name + RGBA, resolved through
-- ImGuiCol at push time so an entry ImGui has RENAMED simply skips instead of crashing. That matters
-- here - 1.92 renamed TabActive -> TabSelected and TabUnfocused* -> TabDimmed*, so BOTH spellings are
-- listed below and whichever the running build actually has wins.
ui.THEMES = {}
-- Ordered, because pairs() over a hash has no defined order and the Settings combo must not
-- reshuffle itself between sessions. Illustrated first, then plain.
ui.THEME_NAMES = {
    'Ledger', 'Midnight Ledger', 'Aged Vellum', 'Oxblood Ledger',
    'Gilt', 'Silverpoint', 'Inkwell', 'Verdigris',
}

-- art      = true  -> the full atlas draws (banner, seals, envelopes, footer). Omitted entirely for
--                     a PLAIN theme, which is croakwatch's own 'Classic <colour>' pattern: same
--                     widget colours, no artwork. ui.art() returns nil for those, and since EVERY
--                     art call site is already guarded with `if ui.art() then`, one flag switches
--                     the whole layout over through paths that already existed.
-- wordmark = { r, g, b } tint for the lettering. The asset is GREYSCALE, and AddImage's IM_COL32
--                     MULTIPLIES, so white lettering x tint = that colour at full strength while the
--                     black outline x anything stays black - the drop shadow survives every recolour
--                     for free. Illustrated themes stay in the gold family because their lettering
--                     sits on warm parchment art; plain themes have a solid background, so silver,
--                     ice and verdigris are all fair game.
-- Palettes and this file's Lua are BOTH generated by design/make_theme_preview.py from one set of
-- numbers, so the approved preview and the shipped colours cannot drift. Edit the palettes THERE
-- and re-run it; do not hand-tune here.
--
-- NAMING carries the family, since there is no "Plain" prefix any more: illustrated themes are named
-- for BOOKS AND PAPER (Ledger, Aged Vellum), plain ones for the PIGMENTS AND MATERIALS a scribe
-- worked in (Gilt = gold leaf, Silverpoint = a silver stylus, Inkwell, Verdigris). Keep any new
-- theme inside whichever convention matches its family - the split is meant to be felt, not read.

-- the original - warm brass on parchment
ui.THEMES['Ledger'] = { art = true, wordmark = { 242, 199, 84 }, colors = {
    { 'WindowBg',             0.074, 0.060, 0.046, 1 },
    { 'ChildBg',              0.060, 0.048, 0.037, 1 },
    { 'PopupBg',              0.070, 0.057, 0.044, 0.96 },
    { 'Border',               0.470, 0.370, 0.200, 0.70 },
    { 'Text',                 0.900, 0.870, 0.800, 1 },
    { 'TextDisabled',         0.560, 0.520, 0.450, 1 },
    { 'Button',               0.190, 0.150, 0.092, 0.90 },
    { 'ButtonHovered',        0.310, 0.240, 0.125, 1 },
    { 'ButtonActive',         0.410, 0.320, 0.155, 1 },
    { 'FrameBg',              0.205, 0.170, 0.115, 1 },
    { 'FrameBgHovered',       0.280, 0.230, 0.152, 1 },
    { 'FrameBgActive',        0.345, 0.280, 0.180, 1 },
    { 'CheckMark',            0.950, 0.780, 0.330, 1 },
    { 'PlotHistogram',        0.620, 0.470, 0.180, 1 },
    { 'PlotHistogramHovered', 0.720, 0.560, 0.230, 1 },
    { 'Separator',            0.400, 0.320, 0.170, 0.50 },
    { 'ScrollbarBg',          0.082, 0.066, 0.050, 0.60 },
    { 'ScrollbarGrab',        0.190, 0.150, 0.092, 0.90 },
    { 'ScrollbarGrabHovered', 0.310, 0.240, 0.125, 1 },
    { 'ScrollbarGrabActive',  0.410, 0.320, 0.155, 1 },
    { 'Header',               0.185, 0.145, 0.088, 0.70 },
    { 'HeaderHovered',        0.295, 0.230, 0.120, 0.90 },
    { 'HeaderActive',         0.385, 0.300, 0.150, 1 },
    { 'Tab',                  0.000, 0.000, 0.000, 0.00 },
    { 'TabHovered',           0.310, 0.240, 0.125, 0.55 },
    { 'TabActive',            0.190, 0.150, 0.092, 1 },
    { 'TabSelected',          0.190, 0.150, 0.092, 1 },
    { 'TabUnfocused',         0.000, 0.000, 0.000, 0.00 },
    { 'TabDimmed',            0.000, 0.000, 0.000, 0.00 },
    { 'TabUnfocusedActive',   0.150, 0.120, 0.075, 1 },
    { 'TabDimmedSelected',    0.150, 0.120, 0.075, 1 },
} }

-- darker - deep walnut, brass dimmed to candlelight

ui.THEMES['Midnight Ledger'] = { art = true, wordmark = { 216, 174, 78 }, colors = {
    { 'WindowBg',                0.042, 0.034, 0.027, 1 },
    { 'ChildBg',                 0.034, 0.028, 0.022, 1 },
    { 'PopupBg',                 0.040, 0.032, 0.026, 0.96 },
    { 'Border',                  0.411, 0.325, 0.149, 0.70 },
    { 'Text',                    0.860, 0.830, 0.770, 1 },
    { 'TextDisabled',            0.500, 0.465, 0.405, 1 },
    { 'Button',                  0.135, 0.105, 0.066, 0.90 },
    { 'ButtonHovered',           0.247, 0.194, 0.100, 1 },
    { 'ButtonActive',            0.340, 0.269, 0.128, 1 },
    { 'FrameBg',                 0.150, 0.124, 0.085, 1 },
    { 'FrameBgHovered',          0.230, 0.187, 0.108, 1 },
    { 'FrameBgActive',           0.289, 0.233, 0.124, 1 },
    { 'CheckMark',               0.880, 0.700, 0.290, 1 },
    { 'PlotHistogram',           0.572, 0.455, 0.189, 1 },
    { 'PlotHistogramHovered',    0.669, 0.532, 0.220, 1 },
    { 'Separator',               0.344, 0.272, 0.129, 0.50 },
    { 'ScrollbarBg',             0.046, 0.037, 0.030, 0.60 },
    { 'ScrollbarGrab',           0.135, 0.105, 0.066, 0.90 },
    { 'ScrollbarGrabHovered',    0.247, 0.194, 0.100, 1 },
    { 'ScrollbarGrabActive',     0.340, 0.269, 0.128, 1 },
    { 'Header',                  0.135, 0.105, 0.066, 0.70 },
    { 'HeaderHovered',           0.236, 0.185, 0.096, 0.90 },
    { 'HeaderActive',            0.321, 0.254, 0.122, 1 },
    { 'Tab',                     0.000, 0.000, 0.000, 0 },
    { 'TabHovered',              0.247, 0.194, 0.100, 0.55 },
    { 'TabActive',               0.135, 0.105, 0.066, 1 },
    { 'TabSelected',             0.135, 0.105, 0.066, 1 },
    { 'TabUnfocused',            0.000, 0.000, 0.000, 0 },
    { 'TabDimmed',               0.000, 0.000, 0.000, 0 },
    { 'TabUnfocusedActive',      0.107, 0.083, 0.052, 1 },
    { 'TabDimmedSelected',       0.107, 0.083, 0.052, 1 },
} }

-- lighter - sun-faded paper, softer ink

ui.THEMES['Aged Vellum'] = { art = true, wordmark = { 250, 216, 116 }, colors = {
    { 'WindowBg',                0.125, 0.105, 0.082, 1 },
    { 'ChildBg',                 0.101, 0.085, 0.066, 1 },
    { 'PopupBg',                 0.119, 0.100, 0.078, 0.96 },
    { 'Border',                  0.523, 0.442, 0.242, 0.70 },
    { 'Text',                    0.945, 0.920, 0.865, 1 },
    { 'TextDisabled',            0.640, 0.600, 0.530, 1 },
    { 'Button',                  0.255, 0.205, 0.132, 0.90 },
    { 'ButtonHovered',           0.364, 0.301, 0.177, 1 },
    { 'ButtonActive',            0.454, 0.381, 0.214, 1 },
    { 'FrameBg',                 0.275, 0.230, 0.162, 1 },
    { 'FrameBgHovered',          0.353, 0.298, 0.191, 1 },
    { 'FrameBgActive',           0.409, 0.347, 0.213, 1 },
    { 'CheckMark',               0.980, 0.845, 0.430, 1 },
    { 'PlotHistogram',           0.637, 0.549, 0.280, 1 },
    { 'PlotHistogramHovered',    0.745, 0.642, 0.327, 1 },
    { 'Separator',               0.458, 0.384, 0.215, 0.50 },
    { 'ScrollbarBg',             0.138, 0.116, 0.090, 0.60 },
    { 'ScrollbarGrab',           0.255, 0.205, 0.132, 0.90 },
    { 'ScrollbarGrabHovered',    0.364, 0.301, 0.177, 1 },
    { 'ScrollbarGrabActive',     0.454, 0.381, 0.214, 1 },
    { 'Header',                  0.255, 0.205, 0.132, 0.70 },
    { 'HeaderHovered',           0.353, 0.291, 0.172, 0.90 },
    { 'HeaderActive',            0.436, 0.365, 0.207, 1 },
    { 'Tab',                     0.000, 0.000, 0.000, 0 },
    { 'TabHovered',              0.364, 0.301, 0.177, 0.55 },
    { 'TabActive',               0.255, 0.205, 0.132, 1 },
    { 'TabSelected',             0.255, 0.205, 0.132, 1 },
    { 'TabUnfocused',            0.000, 0.000, 0.000, 0 },
    { 'TabDimmed',               0.000, 0.000, 0.000, 0 },
    { 'TabUnfocusedActive',      0.201, 0.162, 0.104, 1 },
    { 'TabDimmedSelected',       0.201, 0.162, 0.104, 1 },
} }

-- off-colour that still sits with the art - wine-brown, ember brass

ui.THEMES['Oxblood Ledger'] = { art = true, wordmark = { 240, 188, 98 }, colors = {
    { 'WindowBg',                0.080, 0.050, 0.045, 1 },
    { 'ChildBg',                 0.065, 0.041, 0.036, 1 },
    { 'PopupBg',                 0.076, 0.048, 0.043, 0.96 },
    { 'Border',                  0.473, 0.331, 0.184, 0.70 },
    { 'Text',                    0.905, 0.860, 0.830, 1 },
    { 'TextDisabled',            0.575, 0.505, 0.480, 1 },
    { 'Button',                  0.205, 0.120, 0.098, 0.90 },
    { 'ButtonHovered',           0.314, 0.205, 0.133, 1 },
    { 'ButtonActive',            0.404, 0.277, 0.162, 1 },
    { 'FrameBg',                 0.220, 0.140, 0.118, 1 },
    { 'FrameBgHovered',          0.298, 0.201, 0.141, 1 },
    { 'FrameBgActive',           0.355, 0.244, 0.158, 1 },
    { 'CheckMark',               0.930, 0.690, 0.330, 1 },
    { 'PlotHistogram',           0.605, 0.448, 0.215, 1 },
    { 'PlotHistogramHovered',    0.707, 0.524, 0.251, 1 },
    { 'Separator',               0.408, 0.280, 0.163, 0.50 },
    { 'ScrollbarBg',             0.088, 0.055, 0.050, 0.60 },
    { 'ScrollbarGrab',           0.205, 0.120, 0.098, 0.90 },
    { 'ScrollbarGrabHovered',    0.314, 0.205, 0.133, 1 },
    { 'ScrollbarGrabActive',     0.404, 0.277, 0.162, 1 },
    { 'Header',                  0.205, 0.120, 0.098, 0.70 },
    { 'HeaderHovered',           0.303, 0.197, 0.129, 0.90 },
    { 'HeaderActive',            0.386, 0.262, 0.156, 1 },
    { 'Tab',                     0.000, 0.000, 0.000, 0 },
    { 'TabHovered',              0.314, 0.205, 0.133, 0.55 },
    { 'TabActive',               0.205, 0.120, 0.098, 1 },
    { 'TabSelected',             0.205, 0.120, 0.098, 1 },
    { 'TabUnfocused',            0.000, 0.000, 0.000, 0 },
    { 'TabDimmed',               0.000, 0.000, 0.000, 0 },
    { 'TabUnfocusedActive',      0.162, 0.095, 0.077, 1 },
    { 'TabDimmedSelected',       0.162, 0.095, 0.077, 1 },
} }

-- gold leaf - the warm palette with no artwork

ui.THEMES['Gilt'] = { wordmark = { 242, 199, 84 }, colors = {
    { 'WindowBg',                0.078, 0.066, 0.052, 1 },
    { 'ChildBg',                 0.063, 0.053, 0.042, 1 },
    { 'PopupBg',                 0.074, 0.063, 0.049, 0.96 },
    { 'Border',                  0.471, 0.386, 0.185, 0.70 },
    { 'Text',                    0.900, 0.870, 0.800, 1 },
    { 'TextDisabled',            0.560, 0.520, 0.450, 1 },
    { 'Button',                  0.190, 0.155, 0.100, 0.90 },
    { 'ButtonHovered',           0.304, 0.249, 0.135, 1 },
    { 'ButtonActive',            0.399, 0.327, 0.163, 1 },
    { 'FrameBg',                 0.205, 0.172, 0.120, 1 },
    { 'FrameBgHovered',          0.287, 0.239, 0.143, 1 },
    { 'FrameBgActive',           0.347, 0.288, 0.160, 1 },
    { 'CheckMark',               0.950, 0.780, 0.330, 1 },
    { 'PlotHistogram',           0.617, 0.507, 0.215, 1 },
    { 'PlotHistogramHovered',    0.722, 0.593, 0.251, 1 },
    { 'Separator',               0.403, 0.330, 0.164, 0.50 },
    { 'ScrollbarBg',             0.086, 0.073, 0.057, 0.60 },
    { 'ScrollbarGrab',           0.190, 0.155, 0.100, 0.90 },
    { 'ScrollbarGrabHovered',    0.304, 0.249, 0.135, 1 },
    { 'ScrollbarGrabActive',     0.399, 0.327, 0.163, 1 },
    { 'Header',                  0.190, 0.155, 0.100, 0.70 },
    { 'HeaderHovered',           0.293, 0.239, 0.131, 0.90 },
    { 'HeaderActive',            0.380, 0.311, 0.158, 1 },
    { 'Tab',                     0.000, 0.000, 0.000, 0 },
    { 'TabHovered',              0.304, 0.249, 0.135, 0.55 },
    { 'TabActive',               0.190, 0.155, 0.100, 1 },
    { 'TabSelected',             0.190, 0.155, 0.100, 1 },
    { 'TabUnfocused',            0.000, 0.000, 0.000, 0 },
    { 'TabDimmed',               0.000, 0.000, 0.000, 0 },
    { 'TabUnfocusedActive',      0.150, 0.122, 0.079, 1 },
    { 'TabDimmedSelected',       0.150, 0.122, 0.079, 1 },
} }

-- silver stylus on prepared ground - charcoal, SILVER lettering

ui.THEMES['Silverpoint'] = { wordmark = { 214, 222, 232 }, colors = {
    { 'WindowBg',                0.062, 0.066, 0.074, 1 },
    { 'ChildBg',                 0.050, 0.053, 0.060, 1 },
    { 'PopupBg',                 0.059, 0.063, 0.070, 0.96 },
    { 'Border',                  0.424, 0.379, 0.251, 0.70 },
    { 'Text',                    0.880, 0.888, 0.900, 1 },
    { 'TextDisabled',            0.520, 0.535, 0.560, 1 },
    { 'Button',                  0.145, 0.155, 0.175, 0.90 },
    { 'ButtonHovered',           0.258, 0.246, 0.206, 1 },
    { 'ButtonActive',            0.353, 0.321, 0.231, 1 },
    { 'FrameBg',                 0.160, 0.172, 0.195, 1 },
    { 'FrameBgHovered',          0.241, 0.237, 0.215, 1 },
    { 'FrameBgActive',           0.301, 0.284, 0.230, 1 },
    { 'CheckMark',               0.900, 0.760, 0.380, 1 },
    { 'PlotHistogram',           0.585, 0.494, 0.247, 1 },
    { 'PlotHistogramHovered',    0.684, 0.578, 0.289, 1 },
    { 'Separator',               0.356, 0.324, 0.232, 0.50 },
    { 'ScrollbarBg',             0.068, 0.073, 0.081, 0.60 },
    { 'ScrollbarGrab',           0.145, 0.155, 0.175, 0.90 },
    { 'ScrollbarGrabHovered',    0.258, 0.246, 0.206, 1 },
    { 'ScrollbarGrabActive',     0.353, 0.321, 0.231, 1 },
    { 'Header',                  0.145, 0.155, 0.175, 0.70 },
    { 'HeaderHovered',           0.247, 0.237, 0.203, 0.90 },
    { 'HeaderActive',            0.334, 0.306, 0.226, 1 },
    { 'Tab',                     0.000, 0.000, 0.000, 0 },
    { 'TabHovered',              0.258, 0.246, 0.206, 0.55 },
    { 'TabActive',               0.145, 0.155, 0.175, 1 },
    { 'TabSelected',             0.145, 0.155, 0.175, 1 },
    { 'TabUnfocused',            0.000, 0.000, 0.000, 0 },
    { 'TabDimmed',               0.000, 0.000, 0.000, 0 },
    { 'TabUnfocusedActive',      0.115, 0.122, 0.138, 1 },
    { 'TabDimmedSelected',       0.115, 0.122, 0.138, 1 },
} }

-- blue-black writing ink - deep blue, ICE lettering

ui.THEMES['Inkwell'] = { wordmark = { 170, 208, 242 }, colors = {
    { 'WindowBg',                0.024, 0.044, 0.108, 1 },
    { 'ChildBg',                 0.019, 0.036, 0.087, 1 },
    { 'PopupBg',                 0.023, 0.042, 0.103, 0.96 },
    { 'Border',                  0.393, 0.375, 0.318, 0.70 },
    { 'Text',                    0.860, 0.895, 0.945, 1 },
    { 'TextDisabled',            0.480, 0.535, 0.630, 1 },
    { 'Button',                  0.078, 0.132, 0.282, 0.90 },
    { 'ButtonHovered',           0.206, 0.231, 0.297, 1 },
    { 'ButtonActive',            0.312, 0.313, 0.309, 1 },
    { 'FrameBg',                 0.090, 0.152, 0.320, 1 },
    { 'FrameBgHovered',          0.182, 0.222, 0.327, 1 },
    { 'FrameBgActive',           0.250, 0.273, 0.331, 1 },
    { 'CheckMark',               0.930, 0.790, 0.380, 1 },
    { 'PlotHistogram',           0.605, 0.514, 0.247, 1 },
    { 'PlotHistogramHovered',    0.707, 0.600, 0.289, 1 },
    { 'Separator',               0.317, 0.316, 0.309, 0.50 },
    { 'ScrollbarBg',             0.026, 0.048, 0.119, 0.60 },
    { 'ScrollbarGrab',           0.078, 0.132, 0.282, 0.90 },
    { 'ScrollbarGrabHovered',    0.206, 0.231, 0.297, 1 },
    { 'ScrollbarGrabActive',     0.312, 0.313, 0.309, 1 },
    { 'Header',                  0.078, 0.132, 0.282, 0.70 },
    { 'HeaderHovered',           0.193, 0.221, 0.295, 0.90 },
    { 'HeaderActive',            0.291, 0.296, 0.306, 1 },
    { 'Tab',                     0.000, 0.000, 0.000, 0 },
    { 'TabHovered',              0.206, 0.231, 0.297, 0.55 },
    { 'TabActive',               0.078, 0.132, 0.282, 1 },
    { 'TabSelected',             0.078, 0.132, 0.282, 1 },
    { 'TabUnfocused',            0.000, 0.000, 0.000, 0 },
    { 'TabDimmed',               0.000, 0.000, 0.000, 0 },
    { 'TabUnfocusedActive',      0.062, 0.104, 0.223, 1 },
    { 'TabDimmedSelected',       0.062, 0.104, 0.223, 1 },
} }

-- aged-copper pigment - forest green, VERDIGRIS lettering

ui.THEMES['Verdigris'] = { wordmark = { 162, 226, 196 }, colors = {
    { 'WindowBg',                0.026, 0.060, 0.034, 1 },
    { 'ChildBg',                 0.021, 0.049, 0.028, 1 },
    { 'PopupBg',                 0.025, 0.057, 0.032, 0.96 },
    { 'Border',                  0.387, 0.398, 0.185, 0.70 },
    { 'Text',                    0.865, 0.905, 0.865, 1 },
    { 'TextDisabled',            0.490, 0.560, 0.500, 1 },
    { 'Button',                  0.074, 0.162, 0.088, 0.90 },
    { 'ButtonHovered',           0.201, 0.258, 0.127, 1 },
    { 'ButtonActive',            0.307, 0.337, 0.160, 1 },
    { 'FrameBg',                 0.086, 0.184, 0.102, 1 },
    { 'FrameBgHovered',          0.178, 0.252, 0.129, 1 },
    { 'FrameBgActive',           0.244, 0.301, 0.149, 1 },
    { 'CheckMark',               0.920, 0.800, 0.350, 1 },
    { 'PlotHistogram',           0.598, 0.520, 0.227, 1 },
    { 'PlotHistogramHovered',    0.699, 0.608, 0.266, 1 },
    { 'Separator',               0.311, 0.341, 0.161, 0.50 },
    { 'ScrollbarBg',             0.029, 0.066, 0.037, 0.60 },
    { 'ScrollbarGrab',           0.074, 0.162, 0.088, 0.90 },
    { 'ScrollbarGrabHovered',    0.201, 0.258, 0.127, 1 },
    { 'ScrollbarGrabActive',     0.307, 0.337, 0.160, 1 },
    { 'Header',                  0.074, 0.162, 0.088, 0.70 },
    { 'HeaderHovered',           0.188, 0.248, 0.123, 0.90 },
    { 'HeaderActive',            0.286, 0.322, 0.153, 1 },
    { 'Tab',                     0.000, 0.000, 0.000, 0 },
    { 'TabHovered',              0.201, 0.258, 0.127, 0.55 },
    { 'TabActive',               0.074, 0.162, 0.088, 1 },
    { 'TabSelected',             0.074, 0.162, 0.088, 1 },
    { 'TabUnfocused',            0.000, 0.000, 0.000, 0 },
    { 'TabDimmed',               0.000, 0.000, 0.000, 0 },
    { 'TabUnfocusedActive',      0.058, 0.128, 0.070, 1 },
    { 'TabDimmedSelected',       0.058, 0.128, 0.070, 1 },
} }

-- The active theme, always a real one: a settings file naming a theme that no longer exists (renamed,
-- or hand-edited) falls back to Ledger rather than indexing nil.
-- KEEP THIS ABOVE pushTheme AND BELOW the generated tables. It sits between two things that get
-- regenerated, which is exactly how it was lost once (v2.04): a splice that ran from the first theme
-- table to the "Returns how many colors" comment took this function out with it. Syntax still
-- compiled - the failure was a runtime "attempt to call field 'theme' (a nil value)" at load. After
-- ANY regeneration of the tables, grep for `function ui.theme()` before shipping.
function ui.theme()
    return ui.THEMES[state.theme] or ui.THEMES['Ledger']
end

-- Returns how many colors actually pushed, so the caller pops exactly that many.
function ui.pushTheme()
    local n = 0
    for _, c in ipairs(ui.theme().colors) do
        local idx = ImGuiCol[c[1]]
        if idx then
            imgui.PushStyleColor(idx, c[2], c[3], c[4], c[5])
            n = n + 1
        end
    end
    return n
end

-- Shared loader for both textures. MQ's ImGui binding cannot load a TTF at runtime, so the ornate
-- serif title is a BAKED PNG - unity does the same, with
-- "UNITY" baked into its header plate. wordmark.png is 1024x512, power-of-two, UV-cropped to its ink
-- band, and GREYSCALE so it can be tinted per theme (see ui.wordmarkTint).
function ui.loadTex(file)
    local path = (((mq.luaDir or '') .. '/postmaster/assets/images/' .. file):gsub('\\', '/'))
    local tex = mq.CreateTexture and mq.CreateTexture(path)
    return (tex and tex.GetTextureID and tex:GetTextureID()) and tex or false
end

-- Nil for a PLAIN theme, which is the entire mechanism behind plain mode: every art call site in
-- this file is already written `if ui.art() then`, so returning nil turns the artwork off everywhere
-- at once, through the same fallback paths that handle a missing PNG. No per-site changes needed.
-- The texture is still cached either way, so toggling themes back and forth never reloads it.
function ui.art()
    if ui.tex == nil then ui.tex = ui.loadTex('atlas_ledger.png') end
    if not ui.theme().art then return nil end
    return ui.tex or nil
end

-- Deliberately NOT theme-gated: a plain theme still shows the wordmark, it is only the atlas that
-- goes away. Fails to nil on a missing file, which drops the banner to a plain text title.
function ui.wordmark()
    if ui.wmTex == nil then ui.wmTex = ui.loadTex('wordmark.png') end
    return ui.wmTex or nil
end

-- Lettering tint for the current theme, defaulting to Ledger's gold.
function ui.wordmarkTint()
    local w = ui.theme().wordmark or { 242, 199, 84 }
    return IM_COL32(w[1], w[2], w[3], 255)
end

-- Width derives from the piece's own aspect ratio so nothing ever stretches.
function ui.artWidth(name, h)
    local r = ui.ART[name]
    return h * ((r[3] - r[1]) / (r[4] - r[2]))
end

function ui.drawArt(name, h)
    local tex = ui.art()
    if not tex then return end
    local r = ui.ART[name]
    imgui.Image(tex:GetTextureID(), ImVec2(ui.artWidth(name, h), h),
        ImVec2(r[1] / 1024, r[2] / 1024), ImVec2(r[3] / 1024, r[4] / 1024))
end

-- The window's own custom chrome: full-width art that REPLACES the native title bar (the window runs
-- NoTitleBar), with the wordmark, version and _/X controls overlaid on it. Fleet house style, from
-- croakwatch and unity - and the point is scale: croakwatch's banner is the full window width,
-- unity's plate is winW * 0.5 tall.
--
-- GOTCHA (croakwatch v1.29 lost its buttons to this): every overlay uses absolute
-- SetCursorScreenPos, never SameLine(x) - SameLine measures from the current GROUP's start rather
-- than the window's, so right-aligning that way lands off-screen. The final SetCursorScreenPos puts
-- the cursor back below the art so normal layout continues from there.
-- THREE TIERS, best available first. This ladder is why a plain theme and a missing PNG need no
-- separate handling - they arrive at the same rungs:
--   1. atlas + wordmark  - the illustrated themes
--   2. wordmark alone    - a PLAIN theme, or the atlas failing to load
--   3. plain text title  - both assets missing
-- Tier 2 also closes a real gap found 2026-08-23: the atlas and wordmark load INDEPENDENTLY, and the
-- old code only fell back when the ATLAS failed. An atlas that loaded while wordmark.png did not left
-- the banner with no name on it at all - just a floating version number.
function ui.drawBanner()
    local tex = ui.art()
    local wm = ui.wordmark()

    if not tex and not wm then
        -- Tier 3. Window controls still draw: the script must stay usable with no art at all.
        imgui.PushFont(nil, imgui.GetFontSize() * 1.4)
        coloredText(0.95, 0.82, 0.35, "Postmaster's Challenge")
        imgui.PopFont()
        imgui.SameLine()
        imgui.TextDisabled("v" .. version)
        ui.windowControls(imgui.GetWindowWidth() - 16, 0, nil)
        return
    end

    -- FULL BLEED: drawn straight to the draw list from the window's own origin, spanning the entire
    -- width, so it runs edge to edge with no padding gutter - unity's drawHeaderPlate technique.
    -- RoundCornersTop makes the art's top corners follow the window's own rounding instead of
    -- squaring off over it. A plain imgui.Image() cannot do this: it starts at the padded cursor.
    local r = ui.ART.banner
    local wx, wy = imgui.GetWindowPos()
    local bw = imgui.GetWindowWidth()
    -- With no atlas the header still needs a height. Same proportion the art would have occupied, so
    -- the wordmark lands in the same place and the layout below does not shift between themes.
    local bh = bw * ((r[4] - r[2]) / (r[3] - r[1]))
    local origin = ImVec2(wx, wy)
    if tex then
        imgui.GetWindowDrawList():AddImageRounded(tex:GetTextureID(),
            ImVec2(wx, wy), ImVec2(wx + bw, wy + bh),
            ImVec2(r[1] / 1024, r[2] / 1024), ImVec2(r[3] / 1024, r[4] / 1024),
            IM_COL32(255, 255, 255, 255), 9, ImDrawFlags and ImDrawFlags.RoundCornersTop or 0)

        -- Glow goes on immediately after the art and BEFORE the wordmark, so the lettering stays
        -- crisp on top of it rather than being washed out by the bloom. Skipped without the atlas:
        -- the glow is the lantern's light, and with no lantern drawn it would be a bloom from
        -- nothing.
        ui.lanternGlow(wx, wy, bw, bh)
    end

    -- Baked wordmark, centred on the art, with the version tucked under its tail. The PNG is a
    -- 1024x512 power-of-two canvas but the artwork only occupies the band y=47..464 inside it
    -- (AL's source was 1983x793, repadded), so this UV-crops to exactly that band - otherwise the
    -- transparent padding would be included in the drawn rect and the art would sit visibly small
    -- and high inside its own box.
    -- The version is positioned from the wordmark's actual bottom edge rather than its own formula,
    -- so the two can't drift apart if the wordmark is ever resized.
    -- TINTED, not drawn flat: the asset is greyscale, and AddImage's IM_COL32 multiplies, so the
    -- lettering takes the theme's colour at full strength while the black outline stays black. Uses
    -- the draw list rather than imgui.Image() specifically BECAUSE it needs that tint - AddImage is
    -- the confirmed-working tint path in this fleet, and the same call already draws
    -- the banner just above. It does not advance the cursor, which costs nothing here: every position
    -- below is set absolutely anyway.
    local wmBottom = bh * 0.5
    if wm then
        local ww = bw * 0.72
        local wh = ww / 2.4556        -- aspect of the cropped band, so it never stretches
        -- Named wmY, not wy: the enclosing scope already has a `wy` meaning the WINDOW's screen Y,
        -- and shadowing it here meant two different things wore one name in the same function. Current
        -- code is correct (every use is `origin.y + ...`), but the next line added inside this block
        -- that wanted the window's Y would have silently got the wordmark's offset instead.
        local wmY = (bh - wh) / 2 - 9
        local wx0, wy0 = origin.x + (bw - ww) / 2, origin.y + wmY
        imgui.GetWindowDrawList():AddImage(wm:GetTextureID(),
            ImVec2(wx0, wy0), ImVec2(wx0 + ww, wy0 + wh),
            ImVec2(0, 47 / 512), ImVec2(1, 464 / 512), ui.wordmarkTint())
        wmBottom = wmY + wh

        -- Click-to-minimize hotspot over the middle of the wordmark, croakwatch's pattern (its frog
        -- is a minimize button the same way). A square, deliberately kept well inside the wordmark's
        -- bounds so it never reaches the _/X controls in the corner and still leaves plenty of empty
        -- banner to drag the window by - with NoTitleBar, dragging IS the empty body.
        local hs = math.min(wh * 0.62, ww * 0.28)
        imgui.SetCursorScreenPos(ImVec2(origin.x + (bw - hs) / 2, origin.y + wmY + (wh - hs) / 2))
        if imgui.InvisibleButton("##pmtitlemin", ImVec2(hs, hs)) then ui.minimized = true end
        if imgui.IsItemHovered() then imgui.SetTooltip("click the title to minimize") end
    end
    local vtxt = "v" .. version
    imgui.SetCursorScreenPos(ImVec2(origin.x + (bw - imgui.CalcTextSize(vtxt)) / 2,
        origin.y + wmBottom))
    imgui.TextDisabled(vtxt)

    ui.windowControls(bw, 0, origin)
    -- Resume normal flow below the art. AddImageRounded never moved the cursor, and the full-bleed
    -- draw ignored WindowPadding, so the left inset has to be put back explicitly here.
    -- NOTE: this leaves the cursor moved with nothing submitted, which is only safe because the
    -- caller always opens a tab bar straight afterwards. A SetCursorScreenPos that is never followed
    -- by an item does not grow the window's content boundary, and End/EndChild then hard-fails and
    -- takes the WHOLE ImGui overlay down (hit for real in v1.79's footer). If the tab bar ever stops
    -- following this call, submit an `imgui.Dummy(1, 1)` here.
    imgui.SetCursorScreenPos(ImVec2(origin.x + imgui.GetStyle().WindowPadding.x, origin.y + bh + 4))
end

-- Custom minimize / close, top-right. X stops the script (fleet standard - the X is a CLOSE, not a
-- hide); _ drops to the mini badge below, which stays on screen so the window is never simply gone.
function ui.windowControls(bw, _unused, origin)
    local pad2 = imgui.GetStyle().FramePadding.x * 2
    local sp = imgui.GetStyle().ItemSpacing.x
    local blockW = (imgui.CalcTextSize("_") + pad2) + sp + (imgui.CalcTextSize("X") + pad2)
    if origin then
        imgui.SetCursorScreenPos(ImVec2(origin.x + bw - 8 - blockW, origin.y + 6))
    else
        imgui.SameLine(bw - blockW)
    end
    if imgui.SmallButton("_##pmmin") then ui.minimized = true end
    if imgui.IsItemHovered() then imgui.SetTooltip("Shrink to the mini badge") end
    imgui.SameLine()
    if imgui.SmallButton("X##pmclose") then running = false end
    if imgui.IsItemHovered() then imgui.SetTooltip("Close and STOP the script") end
end

-- Lantern flicker. The lantern is baked INTO the banner art, so rather than trying to animate the
-- picture itself this lays a soft warm glow over its flame. The position is a FRACTION of the banner
-- rect - the flame core was measured off the art at 6.57% across, 37.17% down - so it stays locked to
-- the flame if the banner is ever resized or the window width changes.
--
-- Driven by NOISE rather than a sine wiggle on purpose: a clean periodic pulse reads mechanical,
-- noise reads like a live flame (root GUI_REDESIGN.md, "ImAnim"). ImAnim is optional here - with no
-- library the banner simply renders as it always did.
-- Progress bar, drawn by hand instead of imgui.ProgressBar, for two reasons:
--   1. ImGui places the overlay text just past the FILL's right edge, so the label slides rightward
--      as the bar grows and sits hard left at 0%. Drawing it ourselves keeps it centred always -
--      the "fixed-position bar label" technique already logged in root UI_IDEAS.md (essence v0.28).
--   2. A flat single-colour fill looks dead. A light band over the top and a dark band under the
--      bottom give it a rounded, lit look. There is no gradient primitive, but two translucent
--      rectangles read as one well enough at 14px tall.
-- Uses only draw-list calls confirmed working on VVMQ (see UI_IDEAS.md's list).
function ui.progressBar(frac, label, h, done)
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    local dl = imgui.GetWindowDrawList()
    local x, y = imgui.GetCursorScreenPos()
    local w = imgui.GetWindowWidth() - imgui.GetCursorPosX() - 8
    if w < 40 then w = 40 end
    local r = h * 0.35

    dl:AddRectFilled(ImVec2(x, y), ImVec2(x + w, y + h), IM_COL32(34, 27, 18, 255), r)
    local fw = w * frac
    if fw > 2 then
        local fr, fg, fb = 158, 120, 46                 -- brass
        if done then fr, fg, fb = 89, 173, 84 end       -- green once complete
        dl:AddRectFilled(ImVec2(x, y), ImVec2(x + fw, y + h), IM_COL32(fr, fg, fb, 255), r)
        -- top highlight and bottom shade, clipped to the filled part only
        dl:AddRectFilled(ImVec2(x, y + 1), ImVec2(x + fw, y + h * 0.45), IM_COL32(255, 255, 255, 38), r)
        dl:AddRectFilled(ImVec2(x, y + h * 0.66), ImVec2(x + fw, y + h), IM_COL32(0, 0, 0, 46), r)
    end
    dl:AddRect(ImVec2(x, y), ImVec2(x + w, y + h), IM_COL32(120, 94, 51, 190), r)

    -- Label dead centre, independent of the fill.
    local tw = imgui.CalcTextSize(label)
    dl:AddText(ImVec2(x + (w - tw) * 0.5, y + (h - imgui.GetTextLineHeight()) * 0.5),
        IM_COL32(240, 232, 214, 255), label)
    imgui.Dummy(w, h)
end

-- Width of the widest "From -> To" label in the whole table, so every row's buttons can start at the
-- same column. Measured once and cached: CalcTextSize needs a live font, so it cannot be computed at
-- load time, and re-measuring 18 strings every frame would be waste. The delivery names never change
-- at runtime, so one measurement holds for the session.
function ui.rowNameW()
    if not ui.nameW then
        local w = 0
        for i = 1, #DELIVERIES do
            local d = DELIVERIES[i]
            -- Measured as the three SEGMENTS the row actually draws, not as one joined string: the
            -- names are separate hoverable items now (each with its own zone tooltip), joined by
            -- explicit 4px gaps rather than space glyphs, so a joined measurement would be wrong.
            local tw = imgui.CalcTextSize(d.from) + 4 + imgui.CalcTextSize("->") + 4
                + imgui.CalcTextSize(d.to:match("^%S+") or d.to)
            if tw > w then w = tw end
        end
        ui.nameW = w
    end
    return ui.nameW
end

-- One merchant row: coin glyph, name, and the state right-aligned at its column's right edge.
-- Written to be called INSIDE a column child, so GetWindowWidth() here is that column's width and
-- the right-align needs no knowledge of which column it is in.
function ui.taxCell(m)
    local paid = state.taxes[m]
    local r, g, b = 0.58, 0.56, 0.50
    if paid then r, g, b = 0.45, 0.85, 0.45 end
    ui.icon('coins', 15)
    -- Name shares the state colour with the status word, matching the Deliveries rows.
    coloredText(r, g, b, m)
    local st = paid and "Collected" or "Owed"
    imgui.SameLine(imgui.GetWindowWidth() - imgui.CalcTextSize(st) - 8)
    coloredText(r, g, b, st)
end

-- Milestone announcements. Mechanics lifted from croakwatch's sound pipeline, which is the fleet's
-- only proven implementation of either:
--   /beep "<abspath>"  plays a WAV asynchronously through Windows PlaySound. Quote it for spaces.
--   /tts say "<text>"  speaks via the MQTextToSpeech plugin - MUST be guarded on IsLoaded(), the
--                      command simply does not exist otherwise.
-- Croakwatch also learned the hard way (its v0.44) NOT to unload MQTextToSpeech on script exit: doing
-- that as the script tears down crashed the client. So this never loads or unloads the plugin at all;
-- it uses it if the user already has it, and falls back to a beep if not.
local SOUND_DIR = (((mq.luaDir or '') .. '/postmaster/assets/sounds/'):gsub('\\', '/'))
local TTS_PLUGIN = 'MQTextToSpeech'
-- The plugin substring-matches and cannot enumerate installed voices, so this is a curated set of
-- common Windows ones; anything else goes through /tts voice directly.
local TTS_VOICES = { "David", "Zira", "Mark" }

function ui.ttsReady()
    return mq.TLO.Plugin(TTS_PLUGIN).IsLoaded()
end

-- Every .wav actually sitting in assets/sounds, so the audition list reflects what shipped rather
-- than a hardcoded guess. lfs is optional; without it the list is simply empty.
function ui.listSounds()
    local files = {}
    if okLfs then
        pcall(function()
            for f in lfs.dir(SOUND_DIR) do
                if f:lower():match("%.wav$") then files[#files + 1] = f end
            end
        end)
        table.sort(files)
    end
    return files
end

-- Audition panel, croakwatch's renderSoundTest: TTS state and voice picker on top, then a Play
-- button per shipped wav. Lets a user hear everything without hunting for /beep paths.
function ui.soundTest()
    local ttsOk = ui.ttsReady()
    if imgui.SmallButton("Test Voice") then
        if ttsOk then
            mq.cmd('/tts say "Courier of Favor complete"')
        else
            mq.cmd('/beep'); mq.cmd('/beep')
        end
    end
    imgui.SameLine()
    imgui.TextDisabled(ttsOk and "(TTS loaded)" or "(no TTS - double beep)")
    if ttsOk then
        imgui.TextDisabled("Voice:")
        imgui.SameLine()
        imgui.TextColored(0.85, 0.70, 0.34, 1, mq.TLO.TTS.Voice() or "?")
        for _, v in ipairs(TTS_VOICES) do
            imgui.SameLine()
            if imgui.SmallButton(v) then
                mq.cmdf('/tts voice %s', v)
                state.ttsVoice = v
                saveState()
            end
        end
    end
    if not ui.sounds then ui.sounds = ui.listSounds() end
    if #ui.sounds == 0 then
        imgui.TextDisabled("  no .wav files in assets/sounds/")
    end
    for _, f in ipairs(ui.sounds) do
        imgui.PushID(f)
        if imgui.SmallButton("Play") then mq.cmdf('/beep "%s%s"', SOUND_DIR, f) end
        imgui.SameLine()
        imgui.TextDisabled(f)
        imgui.PopID()
    end
end

-- One milestone: optional chime, optional spoken line. Both independently toggleable, because a
-- chime is welcome far more often than a voice is.
-- `urgent` slows the line and gives it a beat, so an alert reads as deliberate rather than chirpy.
-- Markup goes out through `/tts sayxml`, NOT `/tts say`: reading the plugin source (Knightly1/
-- MQTextToSpeech) showed only sayxml sets SPF_IS_XML, and `say` relies on SAPI's best-effort
-- auto-detection, which mis-handles `<silence/>` and reads it out loud. Anything without markup stays
-- on plain `say`, because sayxml parses the line as XML and a stray & or < in a dynamic step name
-- would break it. Full write-up, including what is confirmed vs merely standard SAPI: root
-- TTS_REFERENCE.md.
-- How long a line takes to speak. Has to be ESTIMATED: the plugin exposes only Voice/Volume/Speed,
-- with no "is speaking" member to poll (confirmed by reading its source). English TTS at speed 0
-- runs roughly 2.5-3 words/sec. Markup is stripped first - tags are not spoken - and the margin is
-- deliberately generous, since cutting a line off is far worse than a beat of extra silence.
function ui.speechMs(text)
    local words = 0
    for _ in text:gsub("<[^>]->", " "):gmatch("%S+") do words = words + 1 end
    local ms = math.max(900, math.floor(words / 2.6 * 1000) + 400)
    -- 2.6 words/sec is the rate at /tts speed 0. A user on a SLOWER setting takes longer to finish,
    -- and under-waiting is the one failure that actually costs a message (the next line truncates
    -- it), so stretch the estimate for negative speeds. Deliberately asymmetric: faster settings are
    -- left alone, because over-waiting only ever costs a slightly longer pause. The exact SAPI rate
    -- curve is not documented anywhere I could verify, so this is a deliberately generous linear
    -- approximation rather than a precise one.
    local speed = tonumber(mq.TLO.TTS.Speed()) or 0
    if speed < 0 then ms = math.floor(ms * (1 + (-speed * 0.12))) end
    return ms
end

-- Speak the next queued line, if one is due. Called from the MAIN LOOP *and* from both wait
-- primitives (waitUntil, waitWhileProgressing).
--
-- THE WAIT-PRIMITIVE HOOKS ARE LOAD-BEARING, NOT BELT-AND-BRACES. An automated step runs
-- SYNCHRONOUSLY inside the main loop's request handler, so during a multi-minute batch the loop never
-- reaches its own drain. With Full Auto on, one dispatch call chains all four clusters - so all four
-- "<City> mail is complete" lines would queue silently and then fire in a burst AFTER the whole run
-- had finished. Full Auto is precisely the mode where nobody is watching the screen and the speech is
-- the only feedback, so late-and-batched is the same as not working.
-- Exactly the reasoning that put fleeIfInCombat() into these two primitives in v1.46: anything that
-- must keep happening DURING automation belongs on the poll, not in the loop that automation blocks.
-- Live "waiting on a performance" line. Returns true if it drew, so the caller can show it INSTEAD of
-- the generic "working..." - during a half-hour wait, "working" is technically true but useless.
--
-- Continuous status belongs ON SCREEN, where it costs nothing and nobody has to read scrollback; the
-- console only heartbeats every 5 minutes (see stage.waitForReturn). That split is deliberate: it keeps
-- the user informed without adding to the console noise AL is separately trying to cut down.
function ui.stageWait()
    if not stage.waitingFor then return false end
    local ms = mq.gettime() - stage.waitingSince
    coloredText(0.95, 0.82, 0.35, string.format("  %s is on stage - waiting %dm %02ds",
        stage.waitingFor, math.floor(ms / 60000), math.floor((ms % 60000) / 1000)))
    imgui.TextDisabled("  Hailing mid-performance does nothing, so waiting is the fix.")
    return true
end

function ui.drainSpeech()
    if #ui.sayQueue == 0 or mq.gettime() < ui.sayNextAt then return end
    local item = table.remove(ui.sayQueue, 1)
    mq.cmdf('/tts %s "%s"', item.xml and 'sayxml' or 'say', item.text)
    ui.sayNextAt = mq.gettime() + ui.speechMs(item.text)
end

function ui.announce(wav, spoken, urgent)
    local xml = false
    if urgent and spoken then
        -- Slower, with a short beat after the first clause so the two halves do not collide - the
        -- clipped-word effect AL identified when listening to markup back to back.
        spoken = "<rate speed='-2'>" .. spoken .. "</rate>"
        xml = true
    end
    local chimed = false
    if state.soundOn and wav then
        mq.cmdf('/beep "%s%s"', SOUND_DIR, wav)
        chimed = true
    end
    -- Master gates speech too. The Settings checkbox already DISPLAYS Speak as unchecked while master
    -- is off (croakwatch's behaviour - master-off reads as "both off"), but state.ttsOn deliberately
    -- retains the preference so it comes back with master. Without soundOn here, that retained true
    -- meant a user who turned Sound off still got spoken lines from a box shown unticked.
    if state.soundOn and state.ttsOn and spoken then
        if ui.ttsReady() then
            -- Queued rather than spoken on the spot. Two reasons, both confirmed in game:
            --  1. /beep is async, so speaking immediately buries the words under the chime.
            --  2. SPF_PURGEBEFORESPEAK - a second line CUTS THE FIRST OFF mid-word. Alerts really
            --     can land together (flee, then the step it interrupted fails), so without pacing
            --     the first one is simply lost.
            -- Drained by the main loop; deliberately NOT mq.delay, since announce is also called
            -- from the render thread by the Test button, where delay is illegal.
            ui.sayQueue[#ui.sayQueue + 1] = { text = spoken, xml = xml }
            if ui.sayNextAt < mq.gettime() then
                ui.sayNextAt = mq.gettime() + (chimed and 1150 or 0)   -- milestone.wav runs ~1.05s
            end
        end
        -- No "at least beep" fallback when the plugin is missing. It used to cover master-off, which
        -- the gate above now excludes outright; and substituting a beep for the cluster line would
        -- turn a silent progress event into an alert-shaped noise, which is exactly the confusion the
        -- silent-progress rule exists to prevent. An alert still chimes on its own wav regardless.
    end
end

-- Small atlas glyph drawn inline before a label, then SameLine so the caller's text follows on the
-- same row. No-ops cleanly when the PNG is missing, so call sites need no guard.
function ui.icon(name, size)
    if not ui.art() then return end
    ui.drawArt(name, size)
    imgui.SameLine(0, 6)
end

-- NOTE FOR A FUTURE SESSION - do not "fix" the noise scaling here.
-- `SmoothNoiseFloat(id, 1.0, ...)` returns only about +/-0.37, not +/-1.0 (measured in game,
-- 2026-08-18). v1.67 normalized that away so the written amplitudes matched reality; it was
-- technically correct and AL preferred the look WITHOUT it, so v1.68 reverted to using the raw value
-- directly. That means every amplitude below is effectively running at ~40% of its nominal figure -
-- ON PURPOSE. Judge this by eye, not by the numbers reading low.
function ui.lanternGlow(wx, wy, bw, bh)
    if not ui.anim or not ui.anim.SmoothNoiseFloat then return end
    -- Clamp dt: an unclamped delta after a frame hitch makes the noise JUMP instead of drift.
    local dt = imgui.GetIO().DeltaTime or (1 / 60)
    if dt > 0.1 then dt = 0.1 end
    -- Fold the raw noise into a 0..1 intensity, with a floor so the flame never fully gutters out.
    local intensity = 0.62 + 0.38 * (ui.anim.SmoothNoiseFloat(ui.flickerId, 1.0, 1.9, dt) or 0)
    if intensity < 0.35 then intensity = 0.35 elseif intensity > 1.0 then intensity = 1.0 end

    local dl = imgui.GetWindowDrawList()

    -- Sideways waver, from a SECOND noise channel at the SAME speed as the light. Shared tempo, but
    -- deliberately not locked in perfect step: a flame whose lean tracked its own brightness exactly
    -- would look every bit as mechanical as the sine wiggle that noise was chosen over to begin with.
    -- Everything below shifts by this, so the flame, its bloom and its cast light move as one.
    -- Amplified then clamped: SmoothNoiseFloat's real output range is not documented anywhere, and
    -- smooth noise typically wanders well inside its nominal amplitude rather than reaching it. The
    -- x2 makes the motion visible even if the raw range is much narrower than +/-1; the clamp keeps
    -- it from flying off if it is not.
    local leanRaw = (ui.anim.SmoothNoiseFloat(ui.leanId, 1.0, 1.9, dt) or 0) * 2.0
    if leanRaw > 1 then leanRaw = 1 elseif leanRaw < -1 then leanRaw = -1 end
    local lean = leanRaw * bw * 0.010

    -- 1. Bloom around the flame itself. Six concentric discs, largest+faintest through
    -- smallest+brightest: ImGui's draw list has no radial-gradient primitive, so stacked translucent
    -- circles are the standard cheap way to fake the falloff. Centre is the measured flame core.
    local cx, cy = wx + bw * 0.0610 + lean, wy + bh * 0.3671
    local base = bh * 0.21 * (0.90 + 0.16 * intensity)
    for i = 6, 1, -1 do
        dl:AddCircleFilled(ImVec2(cx, cy), base * (i / 6),
            IM_COL32(255, 188, 96, math.floor(60 * intensity * (1 - (i - 1) / 6))))
    end

    -- 2. The pool of light the flame throws onto the parchment below it (bright core measured off
    -- the art at ~12% across, ~70% down). Flattened into an ellipse because the page is lying almost
    -- flat and seen at an angle - a circular pool would read as a spotlight hovering above it.
    -- Driven by the SAME intensity value as the flame above: a pool that drifts on its own timing
    -- reads as two unrelated effects rather than one light source.
    -- The pool swings BOTH ways around a midpoint: warmer than the base art at the peak, and
    -- genuinely DARKER than it at the trough. Only ever adding light meant the page could look
    -- less-lit but never dim, which reads as a glow fading out rather than a flame guttering. The
    -- dark wash is warm near-black, not grey - shadow in a lantern-lit scene stays warm.
    local lit = (intensity - 0.60) / 0.40          -- +1 at full brightness, 0 at mid, negative below
    local pr, pg, pb, peak
    if lit >= 0 then
        pr, pg, pb, peak = 255, 198, 112, 38 * lit
    else
        pr, pg, pb, peak = 26, 15, 7, 50 * -lit
    end
    local scale = 0.92 + 0.16 * intensity
    for i = 5, 1, -1 do
        local f = (i / 5) * scale
        ui.ellipse(dl, wx + bw * 0.118 + lean * 0.6, wy + bh * 0.70, bw * 0.115 * f, bh * 0.175 * f,
            IM_COL32(pr, pg, pb, math.floor(peak * (1 - (i - 1) / 5))))
    end

    -- 3. The flame itself. It is painted into the banner, so this lays a small warm tongue over it
    -- that leans and stretches: taller when brighter (physically what a flame does), shifted by the
    -- same lean. At roughly 9x19 screen pixels that reads as the flame wavering. Redrawing the
    -- flame's OWN pixels offset would have been the obvious alternative, but it ghosts against the
    -- original still sitting underneath - an abstract highlight has nothing to double against.
    -- The tongue has to clearly OVERSHOOT the painted flame at its peak and fall clearly under it at
    -- its trough, or nothing visibly changes: the painted core is already near-white, so an overlay
    -- barely alters the pixels it covers - the only readable motion is the part that extends past
    -- the original. v1.65 peaked at 1.14x the flame's own half-height (about 1px of overshoot at
    -- this size), which is why it looked completely static. Now 0.80x..1.45x.
    local fry = bh * 0.0559 * (0.80 + 0.65 * intensity)
    local frx = bw * 0.0086 * (0.85 + 0.45 * intensity)
    for i = 3, 1, -1 do
        local f = i / 3
        ui.ellipse(dl, cx, cy, frx * f * 1.25, fry * f,
            IM_COL32(255, 216, 152, math.floor(78 * intensity * (1 - (i - 1) / 3))))
    end
end

-- This ImGui binding exposes no ellipse primitive, so one is built from the path API: walk the
-- perimeter with PathLineTo, then PathFillConvex. Both proven in croakwatch's donut chart (itself
-- borrowed from buttonmaster's cooldown pie).
function ui.ellipse(dl, cx, cy, rx, ry, col)
    for i = 0, 23 do
        local a = (i / 24) * math.pi * 2
        dl:PathLineTo(ImVec2(cx + math.cos(a) * rx, cy + math.sin(a) * ry))
    end
    dl:PathFillConvex(col)
end

-- One tab: gold label, then the body inside its OWN scrolling child so the banner header above
-- never moves. The gold Text push is popped before the body renders - leaving it pushed would tint
-- every widget inside the tab too. Height 0 makes the child fill whatever the window has left, so
-- the scrollbar appears only on the tab that actually overflows. EndChild is unconditional: unlike
-- Begin/End, a BeginChild always has to be closed regardless of what it returned.
-- Accordion transition tracking, evaluated EVERY frame from renderUI - deliberately not inside any
-- tab or section body.
--
-- WHY THIS IS SEPARATE: an auto-accordion needs to know the exact frame a state CHANGED. But a tab
-- body only renders while that tab is selected, and a section body only while it is expanded - so the
-- frame the change happens is usually a frame that code does not run. The edge is silently lost, and
-- the accordion appears to do nothing. That is exactly what AL reported on 2026-08-24 for the delivery
-- clusters, and the tax-merchant list added in v2.09 had the identical flaw.
--
-- The fix is a LATCH, not a faster check: detect the change here where it cannot be missed, set a
-- `*Dirty` flag, and let the body consume it whenever it next draws. A change that happens while its
-- panel is hidden is therefore applied the moment the panel becomes visible, instead of being dropped.
--
-- NOTE: the Overview phase accordion (`lastActiveSection`) has the same shape and is deliberately left
-- alone - AL confirms it behaves well in the field, and it renders on the tab the user is usually
-- standing on, which is why it gets away with it. Do not "fix" it without a reported problem.
function ui.trackTransitions()
    local activeCluster
    for ci, c in ipairs(ui.clusters) do
        for _, i in ipairs(c.rows) do
            if not state.deliveries[i] then activeCluster = ci break end
        end
        if activeCluster then break end
    end
    if activeCluster ~= ui.lastCluster then
        ui.lastCluster = activeCluster
        ui.clusterDirty = true
    end
    ui.activeCluster = activeCluster

    -- Holding the EMPTY box is the collecting window; it becomes the full box once combined, which is
    -- the natural close signal.
    local taxActive = (mq.TLO.FindItem("=" .. items.box).ID() or 0) > 0
    if taxActive ~= ui.lastTaxActive then
        ui.lastTaxActive = taxActive
        ui.taxDirty = true
    end
    ui.taxActive = taxActive
end

function ui.tab(label, id, body)
    imgui.PushStyleColor(ImGuiCol.Text, 0.90, 0.76, 0.36, 1)
    local open = imgui.BeginTabItem(label)
    imgui.PopStyleColor()
    if open then
        imgui.BeginChild(id, 0, 0, false)
        body()
        imgui.EndChild()
        imgui.EndTabItem()
    end
end

-- Mini badge: what `_` drops to. Deliberately NOT "hide the window" - that leaves a user with no
-- visible way back and only a console line to explain it. Mirrors croakwatch's renderMini: tiny,
-- no title bar, semi-transparent, auto-sized, and the whole thing is clickable to expand. Shows
-- whichever number is actually live right now, so it earns its space on screen.
function ui.mini()
    local nc = ui.pushTheme()
    imgui.PushStyleVar(ImGuiStyleVar.WindowRounding, 9)
    imgui.PushStyleVar(ImGuiStyleVar.FrameRounding, 5)
    imgui.SetNextWindowBgAlpha(0.85)
    local _, draw = imgui.Begin("##postmasterMini", true, bit32.bor(
        ImGuiWindowFlags.NoTitleBar, ImGuiWindowFlags.AlwaysAutoResize, ImGuiWindowFlags.NoScrollbar))
    if draw then
        if ui.art() then
            -- Always the finished seal here: the badge is the script's mark, not a progress readout
            -- (the label beside it already carries the live count).
            ui.drawArt('seal_closed', 22)
            if imgui.IsItemClicked() then ui.minimized = false end
            imgui.SameLine(0, 5)
        end
        local label
        if bagLocation ~= nil or state.lysricDone then
            label = "Satchel obtained"
        elseif not state.nonadDone then
            label = string.format("Taxes %d/%d", taxCount(), #tax.merchants)
        else
            label = string.format("Deliveries %d/%d", deliveredCount(), #DELIVERIES)
        end
        if imgui.Button(label .. "##pmMiniExpand") then ui.minimized = false end
        if imgui.IsItemHovered() then imgui.SetTooltip("click to reopen Postmaster") end
    end
    imgui.End()
    imgui.PopStyleVar(2)
    imgui.PopStyleColor(nc)
end

-- Row status for the Deliveries tab. heldId comes from heldParcelId (a live FindItem lookup) rather
-- than the raw state.held flag: that flag is only ever cleared inside runClusterBatch, so it reads
-- stale if a letter is deleted or poofs between runs. Passed IN rather than looked up here so the
-- caller resolves it once per row per frame - the row also needs it for the Sync button.
function ui.status(i, heldId)
    if state.deliveries[i] then return "Delivered", 0.45, 0.85, 0.45 end
    if heldId then return "In hand", 0.88, 0.69, 0.24 end
    return "Awaiting", 0.58, 0.56, 0.50
end


local function pushAttention()
    local pulse = 0.55 + 0.35 * math.abs(math.sin(mq.gettime() / 350))
    imgui.PushStyleColor(ImGuiCol.Button, 0.85 * pulse, 0.65 * pulse, 0.15 * pulse, 1)
    imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.95 * pulse, 0.75 * pulse, 0.20 * pulse, 1)
    imgui.PushStyleColor(ImGuiCol.ButtonActive, 1.00 * pulse, 0.80 * pulse, 0.25 * pulse, 1)
end

local function popAttention()
    imgui.PopStyleColor(3)
end

function ui.overview()
    if isEmu then
        coloredText(0.95, 0.50, 0.30, "EMU detected - this is a Live-only quest.")
    end
    coloredText(0.70, 0.85, 1.00, string.format("%s (%s) - %s", myName, myRace, myServer))
    -- Current zone, right-aligned on the identity line. Width comes from CalcTextSize rather than a
    -- guessed offset, and GetWindowWidth here is the TAB CHILD's width (this runs inside one), which
    -- is what we want to align against. The margin leaves room for the child's scrollbar.
    local zone = mq.TLO.Zone.Name() or "?"
    imgui.SameLine(imgui.GetWindowWidth() - imgui.CalcTextSize(zone) - 24)
    imgui.TextDisabled(zone)
    local prereqsDone = (state.postmasterDone and 1 or 0) + (state.nonadDone and 1 or 0)
    local satchelHave = bagLocation ~= nil or state.lysricDone
    if satchelHave then
        coloredText(0.45, 0.85, 0.45, string.format("Prereqs %d/2  -  Satchel obtained!", prereqsDone))
    else
        coloredText(0.80, 0.80, 0.80, string.format("Prereqs %d/2  -  Satchel: not yet", prereqsDone))
    end
    if factionRisk then
        coloredText(0.95, 0.45, 0.35, myRace .. " faction: KOS risk in Qeynos/Freeport/elf cities.")
    end
    -- Manual nav override - deliberately NOT nested inside any "if not busy" block, so it stays
    -- reachable even mid-automation (e.g. the Halas swim entrance or the Erudin teleport gem, where
    -- the character can get stuck and needs a human to take over for a moment).
    if imgui.SmallButton("Pause Nav###navPause") then mq.cmd('/nav pause') end
    imgui.SameLine()
    if imgui.SmallButton("Continue Nav###navContinue") then mq.cmd('/nav pause off') end
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Manual override for a stuck automated nav (e.g. Halas swim entrance, Erudin's teleport gem).\nCaution: pausing mid-step may make the script think it arrived early - best used when nav looks genuinely stuck.")
    end

    -- Accordion: exactly one phase is "active" at a time, in this order - Travel -> Nonad Brothers
    -- -> Postmaster's Challenge -> Final Hail (AL: prefers Nonad first, it's the easier one).
    -- The active section is forced open (and everything else forced closed) only on a real
    -- TRANSITION - activeSection changing value from the previous frame - never every frame, so
    -- manual clicks in between transitions are still yours, we don't fight them.
    imgui.Separator()
    local inNeighborhood = mq.TLO.Zone.ID() == zones.neighborhood
    if inNeighborhood then reachedNeighborhoodOnce = true end
    local satchelDone = bagLocation ~= nil or state.lysricDone
    local activeSection
    if not reachedNeighborhoodOnce then
        activeSection = "travel"
    elseif not state.nonadDone then
        activeSection = "nonad"
    elseif not state.postmasterDone then
        activeSection = "postmaster"
    else
        activeSection = "lysric"
    end
    local isTransition = activeSection ~= lastActiveSection
    lastActiveSection = activeSection

    -- Travel
    if isTransition then imgui.SetNextItemOpen(activeSection == "travel", ImGuiCond.Always) end
    if imgui.CollapsingHeader("Travel to Sunrise Hills###travelHeader") then
        imgui.Indent(10)
        if traveling then
            coloredText(0.95, 0.82, 0.35, "Traveling to Sunrise Hills...")
        else
            -- Neighborhood sits ON this row rather than off in Settings: it is the one input the
            -- travel button actually depends on, and splitting them meant an empty field showed a
            -- dead hint here pointing at another tab.
            if state.neighborhood ~= "" then
                if activeSection == "travel" then pushAttention() end
                if imgui.Button("Travel to Sunrise Hills") then travelRequested = true end
                if activeSection == "travel" then popAttention() end
            else
                imgui.TextDisabled("(enter a neighborhood to enable travel)")
            end
            -- Wide gap after the button, tight one before the field: the asymmetry is what makes the
            -- row parse as [button] ... [label+field] rather than three items of equal weight.
            imgui.SameLine(0, 28)
            imgui.Text("Neighborhood:")
            imgui.SameLine(0, 6)
            imgui.SetNextItemWidth(120)
            local nbVal, nbChanged = imgui.InputText("##neighborhood", state.neighborhood or "", 64)
            if nbChanged then state.neighborhood = nbVal; saveState() end
            if imgui.IsItemHovered() then
                imgui.SetTooltip("Default '" .. ui.defaultNeighborhood .. "' is a public neighborhood on every server - no need to change it.\n"
                    .. "Type your preferred name here to use your own instead. Hit enter to save.")
            end
            -- Only offered once the name has been changed (v2.30, AL: "we have a default but no way to get it
            -- back in game") - an always-visible button would sit there doing nothing on most screens.
            if state.neighborhood ~= ui.defaultNeighborhood then
                imgui.SameLine(0, 6)
                if imgui.SmallButton("Reset##neighborhood") then
                    state.neighborhood = ui.defaultNeighborhood
                    saveState()
                end
                if imgui.IsItemHovered() then
                    imgui.SetTooltip("Back to '" .. ui.defaultNeighborhood .. "', the public neighborhood every server has.")
                end
            end
        end
        imgui.Unindent(10)
    end

    -- Prereq 1 (AL's preferred order - the easier one first): The Nonad Brothers
    if isTransition then imgui.SetNextItemOpen(activeSection == "nonad", ImGuiCond.Always) end
    imgui.PushStyleColor(ImGuiCol.Text, state.nonadDone and 0.45 or 1, state.nonadDone and 0.85 or 1, state.nonadDone and 0.45 or 1, 1)
    local nonadOpen = imgui.CollapsingHeader("The Nonad Brothers###nonadHeader")
    imgui.PopStyleColor()
    if nonadOpen then
        imgui.Indent(10)
        local beforeNonad = state.nonadDone
        state.nonadDone = imgui.Checkbox("The Nonad Brothers (+ Taxes) done", state.nonadDone)
        if state.nonadDone ~= beforeNonad then saveState() end
        if not state.nonadDone then
            if nonadBusy then
                coloredText(0.95, 0.82, 0.35, "  Nonad: working...")
            else
                local nonadLabel = "Get Cough Tonic (Pagus)"
                if state.taxesInVicus then
                    nonadLabel = "Report to Pagus"
                elseif (mq.TLO.FindItem("=" .. items.fullbox).ID() or 0) > 0 then
                    nonadLabel = "Return Taxes to Vicus"
                elseif (mq.TLO.FindItem("=" .. items.box).ID() or 0) > 0 then
                    nonadLabel = "Collect Taxes"
                elseif (mq.TLO.FindItem("=" .. items.tonic).ID() or 0) > 0 then
                    nonadLabel = "Give Tonic to Vicus"
                end
                if activeSection == "nonad" then pushAttention() end
                if imgui.Button(nonadLabel) then nonadRequested = true end
                if activeSection == "nonad" then popAttention() end
                if imgui.IsItemHovered() then
                    -- The extra line only shows on the Tonic step, where it is actually the question
                    -- someone is likely to have. SetTooltip printf-formats its argument, so nothing
                    -- built here may contain a literal %.
                    local tip = "Runs this step AND every remaining step after it automatically - stops only if something needs your attention."
                    if nonadLabel == "Get Cough Tonic (Pagus)" then
                        tip = tip .. "\n\nIf Pagus will not hand over another Tonic, that means you have already"
                            .. " completed his part of the quest - it is not a failure. You can still use"
                            .. " Go to Vicus to pick the chain back up."
                    end
                    imgui.SetTooltip(tip)
                end
                imgui.SameLine()
                if imgui.Button("Go to Vicus") then vicusBoxRequested = true end
                if imgui.IsItemHovered() then
                    imgui.SetTooltip("To get a new Tax Collection Box and Debt list."
                        .. "\n\nIf Vicus will not give them to you, it is one of two things: your faction"
                        .. " with him is too low - he says so himself when you hail him - or you have"
                        .. " already finished his quest.")
                end
            end
            if boxInBag() then
                coloredText(0.95, 0.45, 0.35, "  ! Tax box is in a bag - it must be in a MAIN inventory slot.")
            end
            -- Auto-accordion, same contract as the phase headers above and the delivery clusters: the
            -- list opens itself the moment collecting actually starts and closes once it is past, but
            -- ONLY on a real transition - so a manual open/close in between stays yours. AL asked for
            -- this after the phase accordion's own behaviour ("Nonad accordions upward when finished
            -- back at Pagus, that works well") did not extend to the merchant list.
            --
            -- Derived from the held box rather than from `nonadLabel`: that label only exists in the
            -- not-busy branch above, and this needs to be right while a step is running too. Holding
            -- the EMPTY box (items.box) is exactly the collecting window - it becomes items.fullbox once
            -- combined, which is the natural close signal.
            -- State lives on `ui` rather than a new local for the usual reason (200-local ceiling);
            -- ui.lastCluster does the same job for the Deliveries tab.
            -- Latched by ui.trackTransitions(), consumed here - same reason as the delivery clusters.
            -- This block only runs while the Nonad section is expanded, so an edge detected here would
            -- be lost whenever the section happened to be collapsed at the moment collecting started.
            if ui.taxDirty then
                ui.taxDirty = false
                imgui.SetNextItemOpen(ui.taxActive, ImGuiCond.Always)
            end
            if imgui.CollapsingHeader(string.format("Tax merchants  [ %d / %d ]###taxList", taxCount(), #tax.merchants)) then
                imgui.Indent(12)
                -- Row layout borrowed from the original mockup's postmaster list: a small glyph, the
                -- name, and the state as a right-aligned WORD rather than a bracket prefix - the eye
                -- scans one column instead of decoding [x]/[ ]. Read-only; this mirrors the box's
                -- real contents, synced every ~2s.
                --
                -- Split into two columns, 1-5 left and 6-10 right, so the list still reads in quest
                -- order DOWN each column while taking half the height. Each column is its own child
                -- on purpose: inside one, right-aligning is just GetWindowWidth() - text width, the
                -- same proven one-column expression. Doing it with absolute SameLine offsets instead
                -- would mean reasoning about how Indent, WindowPadding and SameLine's origin
                -- interact - measured, that is 370px of content in ~492px of space, so the fit is
                -- comfortable either way, but this version cannot get the origin wrong.
                local taxRows = math.ceil(#tax.merchants / 2)
                local taxColW = (imgui.GetWindowWidth() - 36) / 2
                local taxColH = imgui.GetTextLineHeightWithSpacing() * taxRows
                imgui.BeginChild("##taxcolL", taxColW, taxColH, false)
                for i = 1, taxRows do ui.taxCell(tax.merchants[i]) end
                imgui.EndChild()
                imgui.SameLine(0, 10)
                imgui.BeginChild("##taxcolR", taxColW, taxColH, false)
                for i = taxRows + 1, #tax.merchants do ui.taxCell(tax.merchants[i]) end
                imgui.EndChild()
                imgui.Unindent(12)
            end
        end
        imgui.Unindent(10)
    end

    -- Prereq 2: Postmaster's Challenge
    if isTransition then imgui.SetNextItemOpen(activeSection == "postmaster", ImGuiCond.Always) end
    imgui.PushStyleColor(ImGuiCol.Text, state.postmasterDone and 0.45 or 1, state.postmasterDone and 0.85 or 1, state.postmasterDone and 0.45 or 1, 1)
    local pmOpen = imgui.CollapsingHeader("Postmaster's Challenge###pmHeader")
    imgui.PopStyleColor()
    if pmOpen then
        imgui.Indent(10)
        local done = deliveredCount()
        -- 18/18 deliveries is NOT the same as done - Aric must actually be hailed (grants the
        -- "Courier" title and flags Lysric/Celtreus). Only the manual checkbox can self-report
        -- early; finishChallenge() is what legitimately sets this after the real hail.
        local beforePm = state.postmasterDone
        -- ###pmDone keeps a stable widget ID even though the count in the label changes each tick.
        state.postmasterDone = imgui.Checkbox(
            string.format("Postmaster's Challenge done  (%d/18)###pmDone", done), state.postmasterDone)
        if state.postmasterDone ~= beforePm then saveState() end
        if not state.postmasterDone then
            if pmBusy then
                -- The stage wait replaces "working..." when it applies: during a 30-minute performance
                -- "working" is technically true and completely useless.
                if not ui.stageWait() then
                    coloredText(0.95, 0.82, 0.35, "  Postmaster: working...")
                end
            else
                local pmLabel = "Start Challenge (Aric)"
                if deliveredCount() >= #DELIVERIES then
                    pmLabel = "Finish at Aric"
                elseif pmSpaceNeeded then
                    pmLabel = string.format("Continue (need %d free slot%s)", pmSpaceNeeded.need, pmSpaceNeeded.need == 1 and "" or "s")
                elseif state.challengeStarted then
                    pmLabel = state.pmFullAuto and "Run all remaining batches" or "Run next batch"
                end
                if activeSection == "postmaster" then pushAttention() end
                if imgui.Button(pmLabel .. "###pmRun") then pmRequested = true end
                if activeSection == "postmaster" then popAttention() end
                -- Captured NOW, before anything else is drawn: IsItemHovered refers to the most
                -- recent item, so the checkbox below would otherwise steal this button's tooltip.
                local runHovered = imgui.IsItemHovered()

                -- Full auto belongs beside the button it governs, not off in Settings. Label kept to
                -- two words - the old "(chain all remaining batches)" just restated the tooltip.
                imgui.SameLine(0, 14)
                local beforeFullAuto = state.pmFullAuto
                state.pmFullAuto = imgui.Checkbox("Full auto###pmFullAuto", state.pmFullAuto)
                if state.pmFullAuto ~= beforeFullAuto then saveState() end
                if imgui.IsItemHovered() then
                    imgui.SetTooltip("Off - one destination cluster per click, then stop."
                        .. "\nA chance to check bags, HP and faction risk."
                        .. "\n\nOn - runs every remaining cluster, then finishes"
                        .. "\nat Aric. Stops on any real failure either way.")
                end

                if pmSpaceNeeded then
                    coloredText(0.95, 0.45, 0.35, string.format("  ! Only %d free inventory slot(s) - need %d for this batch.", pmSpaceNeeded.free, pmSpaceNeeded.need))
                elseif state.challengeStarted and deliveredCount() < #DELIVERIES and runHovered then
                    imgui.SetTooltip("Picks up every letter for the next destination,"
                        .. "\nthen delivers them all in one trip."
                        .. "\nRuns unattended - may take a few minutes.")
                end
            end
        end

        -- Bar turns green on the last delivery, matching the green-means-done convention used by
        -- every other state readout in this script.
        ui.progressBar(deliveredCount() / #DELIVERIES,
            string.format("%d/%d delivered", deliveredCount(), #DELIVERIES), 14,
            deliveredCount() >= #DELIVERIES)
        imgui.TextDisabled("For delivery detail go to the Deliveries tab")
        imgui.Unindent(10)
    end

    -- Final turn-in
    if isTransition then imgui.SetNextItemOpen(activeSection == "lysric", ImGuiCond.Always) end
    imgui.PushStyleColor(ImGuiCol.Text, satchelDone and 0.45 or 1, satchelDone and 0.85 or 1, satchelDone and 0.45 or 1, 1)
    local turninOpen = imgui.CollapsingHeader("Final Hail (Lysric)###turninHeader")
    imgui.PopStyleColor()
    if turninOpen then
        imgui.Indent(10)
        -- v2.66: the save says the satchel was received, but THIS character holds none (deleted or lost - a shared
        -- bank one is the account's). Lysric hands a new one to anyone who finished the quest and holds none - the
        -- server keeps the completion (AL) - so say that, instead of claiming one is still here.
        local lost = state.lysricDone and bagLocation == nil
        -- Status line first, in the same spot the old locked-message occupied, then the buttons
        -- under it. Everything Lysric reports used to go ONLY to the console, so a user who missed
        -- the chat line was left with a button and no explanation of why nothing happened.
        if ui.lysricMsg then
            imgui.PushStyleColor(ImGuiCol.Text, ui.lysricMsgCol[1], ui.lysricMsgCol[2], ui.lysricMsgCol[3], 1)
            imgui.TextWrapped(ui.lysricMsg)
            imgui.PopStyleColor()
        elseif lost then
            imgui.PushStyleColor(ImGuiCol.Text, 0.95, 0.82, 0.35, 1)
            imgui.TextWrapped("Quest complete - but this character holds no satchel now. Lysric replaces a lost one"
                .. " for anyone who finished the quest: hail her.")
            imgui.PopStyleColor()
        elseif satchelDone then
            local whereText = bagLocation == "inventory" and "in your inventory" or "in your bank"
            coloredText(0.45, 0.85, 0.45, string.format("Quest complete - you have 1 Featherweight Satchel (%s).", whereText))
        elseif state.postmasterDone then
            imgui.TextDisabled("Ready - hail Lysric to claim your reward.")
        else
            imgui.TextDisabled("Courier of Favor reward: locked until the Postmaster's Challenge is done.")
        end
        -- v2.29: a shared-bank satchel no longer counts as this character's (see satchelCounts), so say
        -- what it is rather than leave a player wondering why the one they can see "doesn't count".
        if (not satchelDone or lost) and ui.sharedSatchels > 0 then
            imgui.PushStyleColor(ImGuiCol.Text, 0.56, 0.52, 0.45, 1)
            imgui.TextWrapped("Your shared bank holds a satchel. The shared bank belongs to your whole account,"
                .. " so this character still earns its own from Lysric.")
            imgui.PopStyleColor()
        end

        if satchelDone and not lost then
            imgui.TextDisabled("The satchel is Lore - bank one in your shared bank, then hail again for a second (40 slots total).")
        end

        if state.postmasterDone then
            if lysricBusy then
                if not ui.stageWait() then
                    coloredText(0.95, 0.82, 0.35, "  Lysric: working...")
                end
            else
                -- Same button either way; only the label changes. A second satchel is reachable
                -- because the step's guard checks INVENTORY, not the bank - see runLysricStep.
                local again = satchelDone and not lost   -- v2.66: a replacement is a first hail, not a second
                local label = again and "Hail Lysric again###lysricRun" or "Hail Lysric###lysricRun"
                if activeSection == "lysric" then pushAttention() end
                if imgui.Button(label) then lysricRequested = true end
                if activeSection == "lysric" then popAttention() end
                if again and imgui.IsItemHovered() then
                    imgui.SetTooltip("You've hailed once, yes....but what about Second Hail?"
                        .. "\n\nBank your current satchel first - Lore blocks a second one in the same"
                        .. " inventory. With it banked, hailing again grants another (40 slots in total).")
                end
            end
            if not state.nonadDone then
                imgui.TextDisabled("(Nonad Brothers not done yet - Hyredel Swiftstride only until then)")
            end
        end
        imgui.Unindent(10)
    end

    -- Footer art: sealed letter bottom-left, postmark bottom-right. Purely decorative, and placed
    -- with absolute cursor positions so the two sit BOTTOM-aligned despite different heights -
    -- SameLine would top-align them, which looks accidental rather than composed.
    if ui.art() then
        imgui.Spacing()
        local x, y = imgui.GetCursorScreenPos()
        -- Same height for both, so tops AND bottoms line up. At different heights only the bottoms
        -- matched and the mismatched tops read as a mistake rather than a composition.
        local lh, ph = 74, 74
        local pw = ui.artWidth('postmark', ph)
        ui.drawArt('letter', lh)
        -- Right edge from the WINDOW's own position, not from the cursor: `x` is already inset by
        -- the child's padding, so `x + GetWindowWidth()` overshoots past the right edge by exactly
        -- that padding and pushes the art out of bounds.
        local wx = imgui.GetWindowPos()
        imgui.SetCursorScreenPos(ImVec2(wx + imgui.GetWindowWidth() - pw - 22, y + lh - ph))
        ui.drawArt('postmark', ph)
        -- Put the cursor back on the left, below both, and SUBMIT AN ITEM. A SetCursorScreenPos with
        -- nothing after it never grows the parent's content boundary, and EndChild then hard-fails
        -- with "Missing EndChild()" - it takes the whole ImGui overlay down, not just this window.
        imgui.SetCursorScreenPos(ImVec2(x, y + lh + 4))
        imgui.Dummy(1, 1)
    end
end

function ui.deliveries()
    ui.progressBar(deliveredCount() / #DELIVERIES,
        string.format("%d/%d delivered", deliveredCount(), #DELIVERIES), 14,
        deliveredCount() >= #DELIVERIES)
    if imgui.SmallButton("Mark all") then
        for i = 1, #DELIVERIES do state.deliveries[i] = true; state.held[i] = nil end
        saveState()
    end
    imgui.SameLine()
    if imgui.SmallButton("Clear all") then
        for i = 1, #DELIVERIES do state.deliveries[i] = false; state.held[i] = nil end
        saveState()
    end
    imgui.Spacing()

    -- The count sits INSIDE the header label on purpose - a SameLine after a CollapsingHeader
    -- overlaps the header bar itself and needs the two-pass pre/post dance.
    -- Which cluster the run is on: the first with anything still undelivered. Same order the
    -- automation works them in, so the open section tracks what "Run next batch" will actually do.
    -- Computed by ui.trackTransitions() every frame, NOT here. This body only runs while the
    -- Deliveries tab is the visible one, and the frame a cluster actually finishes is almost never
    -- such a frame - "Run next batch" lives on Overview, so that is where the user is standing while
    -- the batch runs. Detecting a one-frame edge in code that only sometimes runs simply loses it.
    -- (Field report, AL 2026-08-24: "Qeynos delivery did not accordion up when done. Nor did Highpass
    -- accordion down when I hit Run Batch.")
    -- So the edge is latched there and CONSUMED here, whenever this tab next happens to draw.
    local activeCluster = ui.activeCluster
    local clusterMoved = ui.clusterDirty
    ui.clusterDirty = false

    for ci, c in ipairs(ui.clusters) do
        local doneN = 0
        for _, i in ipairs(c.rows) do
            if state.deliveries[i] then doneN = doneN + 1 end
        end
        local allDone = doneN >= #c.rows
        if clusterMoved then imgui.SetNextItemOpen(ci == activeCluster, ImGuiCond.Always) end
        -- Seal reads the cluster's state without parsing its count: intact once every letter in it
        -- is delivered, broken while any are still out.
        ui.icon(allDone and 'seal_closed' or 'wax', 16)
        imgui.PushStyleColor(ImGuiCol.Text, allDone and 0.45 or 1, allDone and 0.85 or 1, allDone and 0.45 or 1, 1)
        local open = imgui.CollapsingHeader(string.format("%s  (%d/%d)###cluster%d", c.city, doneN, #c.rows, ci))
        imgui.PopStyleColor()
        if open then
            imgui.Indent(12)
            for _, i in ipairs(c.rows) do
                local d = DELIVERIES[i]
                local heldId = heldParcelId(i, true)   -- render thread: read-only
                local status, sr, sg, sb = ui.status(i, heldId)
                ui.icon('envelope', 14)
                -- Name carries the state colour too, not just the status word - the whole row reads
                -- as one unit at a glance instead of making the eye jump to the right column.
                local nameX = imgui.GetCursorPosX()
                -- Sender and recipient are drawn as SEPARATE items so each can carry its own zone
                -- tooltip - hovering one name and being told the other's zone would be worse than
                -- no tooltip at all. Widths must match ui.rowNameW()'s segmented measurement.
                coloredText(sr, sg, sb, d.from)
                if imgui.IsItemHovered() then imgui.SetTooltip("In " .. d.fromZone) end
                imgui.SameLine(0, 4)
                coloredText(sr, sg, sb, "->")
                imgui.SameLine(0, 4)
                coloredText(sr, sg, sb, d.to:match("^%S+") or d.to)
                if imgui.IsItemHovered() then imgui.SetTooltip("In " .. d.toZone) end
                if not state.deliveries[i] then
                    -- Two manual escape hatches, for opposite desyncs. "Done": no TLO exists for
                    -- "already completed server-side", so a delivery handed in outside deliverOnly
                    -- (manually, after a script failure) can never be learned automatically - and if
                    -- the sender then refuses to reissue the letter, that row is stuck forever
                    -- without this. "Sync": the mirror case, a letter picked up outside pickupOnly;
                    -- mostly self-healing since v1.22's permanent item ids, kept as a fallback.
                    -- Buttons start at a FIXED column, measured from the longest name in the whole
                    -- table, so they line up down the list instead of stepping raggedly in and out
                    -- with each name's length.
                    imgui.SameLine(nameX + ui.rowNameW() + 12)
                    if imgui.SmallButton("Done##d" .. i) then
                        state.deliveries[i] = true
                        state.held[i] = nil
                        saveState()
                    end
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip("Mark as already delivered server-side.\nUse when you handed it in yourself - the script cannot detect that.")
                    end
                    if not heldId then
                        imgui.SameLine()
                        if imgui.SmallButton("Sync##d" .. i) then syncHeldIdx = i end
                        if imgui.IsItemHovered() then
                            imgui.SetTooltip("Put the letter on your cursor first, then click.\nConfirms you are holding it, so the row reads 'In hand'.")
                        end
                    end
                elseif not state.postmasterDone and not pmBusy then
                    -- v2.65 (AL): "Done" is saved to disk, so a row marked only to make the next batch skip it
                    -- (a quick way to send the run somewhere for a test) stayed delivered for good - and Aric
                    -- will not finish a Challenge with a letter never really handed in. Undo puts it back.
                    -- Hidden while a batch runs (it read the list at its start) and once Aric has signed off.
                    imgui.SameLine(nameX + ui.rowNameW() + 12)
                    if imgui.SmallButton("Undo##u" .. i) then
                        state.deliveries[i] = false
                        saveState()
                    end
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip("Put this row back to Awaiting.\nFor a row you marked Done yourself. A letter really handed in counts\nonce - the sender may not give it again.")
                    end
                end
                imgui.SameLine(imgui.GetWindowWidth() - imgui.CalcTextSize(status) - 28)
                coloredText(sr, sg, sb, status)
            end
            imgui.Unindent(12)
        end
    end
end

-- The Faction tab (v2.29): one section per helper quest. Everything here only READS and sets request
-- flags - the reading, buying and walking all happen in the main loop, because the render thread must
-- never wait.
function ui.factionRow(label, value)
    imgui.TextDisabled(label)
    imgui.SameLine(96)
    imgui.TextWrapped(value)
end

-- One colour per tier, worst to best (v2.30, AL: "colorize the faction bar"). The bad end follows the
-- game's own Faction window - Scowls red, Threatening pink-red, Dubious yellow, Apprehensive grey,
-- Indifferent white (AL's screenshot) - so the strip reads the way the player already knows; the good end
-- runs through greens to a blue Ally.
ui.tierColors = {
    { 205, 55, 50 }, { 220, 110, 100 }, { 215, 185, 60 }, { 150, 150, 150 }, { 225, 225, 225 },
    { 150, 205, 120 }, { 95, 185, 95 }, { 55, 160, 115 }, { 80, 150, 230 },
}

-- The nine tiers as a strip, worst on the left. Tiers you have reached are solid, the rest faint, so the
-- whole scale is always readable; where you stand gets a white edge, the goal a gold one. Hovering names
-- the tier under the mouse.
function ui.factionLadder(word, goal)
    local dl = imgui.GetWindowDrawList()
    local x, y = imgui.GetCursorScreenPos()
    local w = imgui.GetWindowWidth() - imgui.GetCursorPosX() - 8
    local n, gap, h = #faction.tiers, 3, 12
    local seg = (w - gap * (n - 1)) / n
    local now, want = faction.rank(word) or 0, faction.rank(goal) or 0
    for k = 1, n do
        local x0 = x + (k - 1) * (seg + gap)
        local c = ui.tierColors[k]
        dl:AddRectFilled(ImVec2(x0, y), ImVec2(x0 + seg, y + h), IM_COL32(c[1], c[2], c[3], k <= now and 255 or 45), 3)
        if k == now then dl:AddRect(ImVec2(x0, y), ImVec2(x0 + seg, y + h), IM_COL32(255, 255, 255, 210), 3) end
        if k == want then dl:AddRect(ImVec2(x0 - 1, y - 1), ImVec2(x0 + seg + 1, y + h + 1), IM_COL32(242, 199, 84, 255), 3) end
    end
    imgui.Dummy(w, h)
    if imgui.IsItemHovered() then
        local mx = imgui.GetMousePos()   -- two plain numbers; only x is needed
        local k = math.max(1, math.min(n, math.floor((mx - x) / (seg + gap)) + 1))
        imgui.SetTooltip(faction.tiers[k] .. (k == now and "  - where you stand" or "")
            .. (k == want and "  - your Stop at goal" or ""))
    end
end

function ui.pushButtonColor(r, g, b)
    imgui.PushStyleColor(ImGuiCol.Button, r, g, b, 1)
    imgui.PushStyleColor(ImGuiCol.ButtonHovered, r * 1.25, g * 1.25, b * 1.25, 1)
    imgui.PushStyleColor(ImGuiCol.ButtonActive, r * 1.5, g * 1.5, b * 1.5, 1)
end

function ui.faction()
    imgui.PushStyleColor(ImGuiCol.Text, 0.56, 0.52, 0.45, 1)
    imgui.TextWrapped("Quests that raise a faction by handing an NPC something you can buy, or coin. Each one runs"
        .. " on its own, apart from the courier quest.")
    imgui.PopStyleColor()
    local otherBusy = nonadBusy or pmBusy or lysricBusy or traveling
    for i, h in ipairs(faction.helpers) do
        local r = faction.reads[h.key] or {}
        imgui.SetNextItemOpen(true, ImGuiCond.FirstUseEver)
        if imgui.CollapsingHeader(string.format("%s  -  %s%s###factionHelper%d", h.title, h.faction,
            r.word and ("   (" .. r.word .. ")") or "", i)) then
            imgui.Indent(6)
            ui.factionRow("Needed for", h.neededFor)
            if h.coin then
                ui.factionRow("Give", string.format("%d %s at a time, one trade each - no shop. Short of %s, the PoK"
                    .. " bank makes change from platinum.", h.perGive, h.unit, h.unit))
            elseif h.loop then
                ui.factionRow("Buy", string.format("%s - %s, beside him, as it goes (%s in PoK sells it too)",
                    h.item, h.shop, h.vendor))
                ui.factionRow("Give", string.format("%d at a time, one trade each; the %s he hands back is destroyed"
                    .. " (it is Lore and blocks the next).", h.perTrade, h.destroy))
            else
                ui.factionRow("Buy", string.format("%s - %s, %s", h.item, h.vendor, h.vendorWhere))
            end
            ui.factionRow("Give to", string.format("%s - %s", h.npc, h.npcWhere))
            ui.factionRow("Also raises", h.raises)
            ui.factionRow("Lowers", h.lowers)
            imgui.Spacing()
            local goal = faction.goalFor(h)
            ui.factionLadder(r.word, goal)
            if r.word then
                local line = string.format("Now %s, earned standing %s", r.word, r.standing and tostring(r.standing) or "?")
                if (faction.rank(r.word) or 0) >= (faction.rank(goal) or 99) then
                    coloredText(0.45, 0.85, 0.45, line .. " - at your goal.")
                else
                    local need = faction.estimate(h, r.standing, goal)
                    coloredText(0.90, 0.87, 0.80, line .. (need and string.format(" - about %d %s to go.", need,
                        h.item or h.unit) or "."))
                end
            else
                imgui.TextDisabled("Not read yet - Check reads it from your Faction window.")
            end
            -- v2.58, the coin helper: below Indifferent Fabian's own quest will not deal - Run goes in the mask.
            if h.coin and r.word and (faction.rank(r.word) or 0) < faction.rank("Indifferent") then
                imgui.PushStyleColor(ImGuiCol.Text, 0.95, 0.82, 0.35, 1)
                imgui.TextWrapped(string.format("%s's quest deals only with %s Indifferent - so Run goes to him in the"
                    .. " Sneak mask: a sneaking character reads Indifferent to him, and his quest believes it. A Rogue"
                    .. " sneaks as themselves; an evil race from level 5 takes a Goblin Rogue shroud.", h.npc, h.faction))
                imgui.PopStyleColor()
            end
            if h.dangerNpc and faction.hostile(r.danger) then
                -- v2.60: the danger stands IN THE ROOM - close up, a hostile NPC sees through Sneak.
                imgui.PushStyleColor(ImGuiCol.Text, 0.95, 0.45, 0.35, 1)
                imgui.TextWrapped(string.format("%s: %s. %s stands in %s's room, close enough to see through Sneak -"
                    .. " run %s first. Run stops here until then.", h.danger, r.danger, h.dangerNpc, h.npc, h.dangerFix))
                imgui.PopStyleColor()
            elseif faction.hostile(r.danger) then
                imgui.PushStyleColor(ImGuiCol.Text, 0.95, 0.45, 0.35, 1)
                imgui.TextWrapped(string.format("%s: %s. The guards on the way attack you on sight%s.", h.danger,
                    r.danger, faction.hostile(r.npcWord) and " - so Run goes to " .. h.npc .. " shrouded and hidden"
                        or (h.coin and " - so Run goes to " .. h.npc .. " in the Sneak mask, whatever the bards read"
                            or (h.meet and " - so Run waits by the PoK book and meets " .. h.npc .. " out in the field, away from them"
                                -- v2.59: a hostile danger with no meeting spot takes the shrouded one-trip path
                                or " - so Run buys them as you, banks them, and takes them to " .. h.npc
                                    .. " in a Goblin Rogue shroud, hidden, in one trade"))))
                imgui.PopStyleColor()
            end
            if faction.hostile(r.npcWord) then
                imgui.PushStyleColor(ImGuiCol.Text, 0.95, 0.45, 0.35, 1)
                -- What Run will actually DO about it, for this character (v2.37, one trip since v2.41).
                local lvl = mq.TLO.Me.Level() or 0
                local plan = (h.loop and (mq.TLO.Me.Class.ShortName() or "") == "ROG"
                        and "Run sneaks up behind him as yourself and hands them over from there.")
                    or (factionRisk and lvl >= 5 and lvl < tuning.shroudLevel and h.loop
                        and "Run takes a Goblin Rogue shroud (your coins go with you), buys them beside him, and hands"
                            .. " them over from his back.")
                    or (factionRisk and lvl >= 5 and lvl < tuning.shroudLevel
                        and "Run buys them all as you, banks them, takes a Goblin Rogue shroud, and hands them all"
                            .. " over in one trip.")
                    or (lvl < 5 and "that needs a Goblin Rogue shroud, from level 5 - Run stops before buying.")
                    or "take a Goblin Rogue shroud first (Shroudkeeper Hyush, PoK) - Run stops before buying."
                imgui.TextWrapped(string.format("%s: %s. %s attacks you on sight, so the items can only be handed"
                    .. " over while hidden - %s", h.npcFaction, r.npcWord, h.npc, plan))
                imgui.PopStyleColor()
            end
            -- v2.41: a shroud empties the Faction window, and it stays empty after "remove" until a camp.
            if mq.TLO.Me.Shrouded() and faction.active ~= i then
                imgui.PushStyleColor(ImGuiCol.Text, 0.95, 0.82, 0.35, 1)
                local p = faction.plan
                if (h.coin or h.loop) and p and p.key == h.key and p.need > 0 then
                    -- v2.63: a run sized as yourself carries on in the shroud
                    imgui.TextWrapped(string.format("You are shrouded. Run carries on the run you started as yourself -"
                        .. " about %d %s left. Check needs you as yourself (Unshroud, then camp).", p.need, h.item or h.unit))
                else
                    imgui.TextWrapped("You are shrouded. Run and Check need you as yourself: press Unshroud, then camp to"
                        .. " character select and come back - EQ keeps your Faction window empty after a shroud until you do.")
                end
                imgui.PopStyleColor()
            end

            imgui.TextDisabled("Stop at")
            imgui.SameLine()
            imgui.SetNextItemWidth(140)
            if imgui.BeginCombo("##factionGoal" .. i, goal) then
                for _, g in ipairs(faction.goals) do
                    -- v2.61: MQ's Selectable returns (selected, PRESSED) - lua_ImGuiWidgets.cpp. Testing the first
                    -- fired every frame for the CURRENT goal and set it back (AL: "stuck on Kindly"), saving each frame.
                    local _, pressed = imgui.Selectable(g, g == goal)
                    if pressed then
                        state.factionGoals[h.key] = g   -- v2.58: each helper keeps its own
                        saveState()
                    end
                end
                imgui.EndCombo()
            end
            if imgui.IsItemHovered() then
                if h.goalTip then
                    imgui.SetTooltip(h.goalTip)
                elseif h.coin then
                    imgui.SetTooltip("The reaction to stop at. Indifferent is what Fabian's own quest asks for;\nAlly"
                        .. " makes every bard in the Postmaster's Challenge friendly.\n\nThe gold is sized to it, and never"
                        .. " past the +2,000 earned\nstanding - past that a give earns nothing.")
                else
                    imgui.SetTooltip("The reaction to stop at. Apprehensive is what Vicus Nonad\nneeds before he will give you the Taxes."
                        .. "\n\nKindly, Warmly and Ally: the item estimate is on the safe\nside, so a run may buy a few more than it uses."
                        .. " It still\nstops the moment the reaction reads your goal.")
                end
            end

            if faction.last == i and faction.status ~= "" then
                coloredText(0.95, 0.82, 0.35, faction.status)
                if faction.given > 0 then
                    imgui.TextDisabled(string.format("%d %s handed over this run.", faction.given, h.item or h.unit))
                end
            end

            if faction.active == i then
                if automation.paused then
                    ui.pushButtonColor(0.18, 0.35, 0.14)
                    if imgui.Button("Continue##factionGo" .. i) then
                        automation.paused = false
                        if mq.TLO.Navigation.Paused() then mq.cmd('/nav pause off') end
                    end
                else
                    ui.pushButtonColor(0.36, 0.27, 0.07)
                    if imgui.Button("Pause##factionPause" .. i) then
                        automation.paused = true
                        if mq.TLO.Navigation.Active() then mq.cmd('/nav pause') end
                    end
                end
                imgui.PopStyleColor(3)
                imgui.SameLine()
                ui.pushButtonColor(0.42, 0.14, 0.13)
                if imgui.Button("Stop##factionStop" .. i) then
                    automation.stop = true
                    automation.paused = false
                end
                imgui.PopStyleColor(3)
            elseif faction.active or otherBusy then
                imgui.TextDisabled("Another run is going - this one waits until it finishes.")
            else
                ui.pushButtonColor(0.18, 0.35, 0.14)
                if imgui.Button("Run##factionRun" .. i) then
                    faction.last, faction.status, faction.given = i, "Starting...", 0
                    faction.request = i
                end
                imgui.PopStyleColor(3)
                if imgui.IsItemHovered() then
                    if h.coin then
                        imgui.SetTooltip(string.format("Sorts out the %s your Stop at needs (the PoK bank makes change"
                            .. " from platinum),\ntakes it to %s and hands it over %d at a time until %s reaches it.\nStarts"
                            .. " as yourself, never in a shroud.\nPause and Stop appear once it is running.", h.unit, h.npc,
                            h.perGive, h.faction))
                    elseif h.loop then
                        imgui.SetTooltip(string.format("Goes to %s and hands over %s %d at a time,\nbuying it from %s"
                            .. " beside him as it goes, until %s\nreaches your Stop at. Starts as yourself; in a shroud, Run"
                            .. "\ncarries on a run you started. Pause and Stop appear once it is running.",
                            h.npc, h.item, h.perTrade, h.shop, h.faction))
                    else
                        imgui.SetTooltip(string.format("Buys the %s your Stop at reaction needs, takes them to %s,\nand"
                            .. " repeats until %s reaches it. Starts as yourself,\nnever in a shroud.\nPause and Stop appear"
                            .. " once it is running.", h.item, h.npc, h.faction))
                    end
                end
                imgui.SameLine()
                if imgui.Button("Check##factionCheck" .. i) then faction.check = i end
                if imgui.IsItemHovered() then
                    imgui.SetTooltip("Reads where you stand from your Faction window - no travel.")
                end
                if mq.TLO.Me.Shrouded() then
                    imgui.SameLine()
                    ui.pushButtonColor(0.28, 0.20, 0.36)
                    if imgui.Button("Unshroud##factionUnshroud" .. i) then
                        faction.last, faction.status, faction.given = i, "Starting...", 0
                        faction.unshroud = i
                    end
                    imgui.PopStyleColor(3)
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip("Goes to Shroudkeeper Hyush in PoK and says \"remove\".\nThen camp to character"
                            .. " select and come back -\nEQ keeps your Faction window empty until you do.")
                    end
                end
            end
            imgui.Unindent(6)
        end
    end
end

function ui.settings()
    -- Layout mirrors croakwatch's Options tab: a gold section heading, its controls stacked one per
    -- line beneath it, and a Separator between sections. Neighborhood and Full auto are NOT here -
    -- they moved next to the controls they govern (Travel row, Postmaster's Challenge button).
    coloredText(0.90, 0.76, 0.36, "Theme")
    imgui.SetNextItemWidth(220)
    if imgui.BeginCombo("##pmtheme", state.theme) then
        for _, name in ipairs(ui.THEME_NAMES) do
            local _, pressed = imgui.Selectable(name, name == state.theme)   -- v2.61: (selected, pressed)
            if pressed then
                state.theme = name
                saveState()
            end
        end
        imgui.EndCombo()
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Restyles the window - applies instantly.\n\n"
            .. "Named for books and paper - Ledger, Midnight\nLedger, Aged Vellum, Oxblood Ledger - "
            .. "these keep\nthe artwork.\n\n"
            .. "Named for pigments - Gilt, Silverpoint, Inkwell,\nVerdigris - these drop the artwork "
            .. "and show only\nthe title, which frees the colour: silver, ice and\nverdigris "
            .. "lettering.\n\n"
            .. "Semantic colours (green done, amber carrying,\ngrey waiting) stay the same in every "
            .. "theme, so\ntheir meaning never changes.")
    end

    imgui.Separator()
    coloredText(0.90, 0.76, 0.36, "Travel")
    -- The click only records the wish; the main loop does the resizing (fit.request), since applying it
    -- waits for the new size to land and the render thread must never wait.
    local beforeFit = state.fitCounters
    state.fitCounters = imgui.Checkbox("Fit through counters", state.fitCounters)
    if state.fitCounters ~= beforeFit then
        saveState()
        fit.request = state.fitCounters
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Some shopkeepers stand behind a counter with little\nroom above it, and a full-size "
            .. "character gets stuck\nclimbing over. This sets you to MQ2AutoSize size 4\nwhile Postmaster is "
            .. "running - the size that got over\ncleanly in testing.\n\nIf you don't use MQ2AutoSize, Postmaster loads it\nfor the run and "
            .. "unloads it after. If you do, your\nown settings are saved first and put back.")
    end
    -- Only a character the Shroud Strategy applies to sees the box (v2.46).
    if factionRisk and (mq.TLO.Me.Level() or 0) < tuning.shroudLevel then
        local beforeShroud = state.autoShroud
        state.autoShroud = imgui.Checkbox("Shroud for the courier runs", state.autoShroud)
        if state.autoShroud ~= beforeShroud then saveState() end
        if imgui.IsItemHovered() then
            imgui.SetTooltip("Takes a level-matched Goblin Rogue shroud from\nShroudkeeper Hyush before the courier and "
                .. "Nonad runs,\nthen sneaks and hides past guards that attack\nyour race on sight.\n\nOff: you travel "
                .. "as yourself. Fix a faction first\non the Faction tab if its guards are the problem.\n\nA shroud "
                .. "empties your Faction window until you\ncamp to character select and come back.")
        end
    end

    imgui.Separator()
    coloredText(0.90, 0.76, 0.36, "Sounds")
    local beforeSound = state.soundOn
    state.soundOn = imgui.Checkbox("Sound (master - all Postmaster sounds)", state.soundOn)
    if state.soundOn ~= beforeSound then saveState() end
    -- Speak shows unchecked and ignores clicks while master is off, so master-off reads as "both
    -- off" - croakwatch's Camp Watch checkbox behaves the same way. The preference is kept and
    -- comes back when master returns.
    local newTts = imgui.Checkbox("Speak milestones aloud", state.soundOn and state.ttsOn)
    if state.soundOn and newTts ~= state.ttsOn then
        state.ttsOn = newTts
        saveState()
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Says milestones out loud as well as chiming.\nNeeds the MQTextToSpeech plugin loaded.")
    end

    -- Speed and volume, straight from the plugin's own /tts usage output (AL, 2026-08-23):
    --   /tts speed  -10..10        ${TTS.Speed}
    --   /tts volume 0..100         ${TTS.Volume}
    -- Read live from the TLO every frame and written only on change, so the PLUGIN stays the single
    -- source of truth - nothing is mirrored into state.lua that could drift out of step with it.
    -- InputInt rather than SliderInt: InputInt is proven in croakwatch, SliderInt is not used in any
    -- confirmed MQ script, only in a sandbox file that may be a different binding.
    if state.soundOn and state.ttsOn and ui.ttsReady() then
        imgui.Indent(10)
        local curSpeed = math.floor(tonumber(mq.TLO.TTS.Speed()) or 0)
        imgui.SetNextItemWidth(110)
        local newSpeed = imgui.InputInt("Speed  (-10 to 10)###ttsSpeed", curSpeed)
        if newSpeed ~= curSpeed then
            if newSpeed < -10 then newSpeed = -10 elseif newSpeed > 10 then newSpeed = 10 end
            mq.cmdf('/tts speed %d', newSpeed)
        end
        local curVol = math.floor(tonumber(mq.TLO.TTS.Volume()) or 100)
        imgui.SetNextItemWidth(110)
        local newVol = imgui.InputInt("Volume  (0 to 100)###ttsVol", curVol)
        if newVol ~= curVol then
            if newVol < 0 then newVol = 0 elseif newVol > 100 then newVol = 100 end
            mq.cmdf('/tts volume %d', newVol)
        end
        imgui.Unindent(10)
    end
    ui.soundTest()

    imgui.Separator()
    coloredText(0.90, 0.76, 0.36, "Announced milestones")
    imgui.TextDisabled("  Quest complete            (chime: milestone)")
    imgui.TextDisabled("  A step failed, run stopped (chime: alert)")
    imgui.TextDisabled("  Combat - fleeing           (chime: alert)")
    imgui.TextDisabled("Progress is deliberately silent, so an alert always means")
    imgui.TextDisabled("the run needs you.")
end

-- Studio-standard Help layout, matching croakwatch's: gold section headings, a two-column command
-- list, bulleted tips, and a version footer. Keeping siblings visually identical is the point - a
-- user who learns one of AL's scripts should recognise the next one on sight.
-- Postmaster adds "The quest" on top, which croakwatch has no equivalent for: a quest assistant has
-- to say what the quest actually IS before its commands mean anything.
function ui.help()
    coloredText(0.90, 0.76, 0.36, "The quest")
    imgui.TextWrapped("Courier of Favor. The reward is the Featherweight Satchel of the Courier - a "
        .. "20-slot, 100% weight reduction bag - plus Hyredel Swiftstride, your own parcel NPC.")
    imgui.Spacing()
    imgui.BulletText("Nonad Brothers - tonic run to Qeynos, then the nested Taxes quest")
    imgui.BulletText("Postmaster's Challenge - 18 letters, batched by destination city")
    imgui.BulletText("Hail Lysric Loresinger in Sunrise Hills to claim the reward")

    imgui.Separator()
    coloredText(0.90, 0.76, 0.36, "Commands")
    local cmds = {
        { "/postmaster",        "hide or show this window" },
        { "/postmaster travel", "travel to Sunrise Hills" },
        { "/postmaster nonad",  "run the next Nonad Brothers step" },
        { "/postmaster pm",     "run the next delivery batch" },
        { "/postmaster lysric", "hail Lysric for the reward" },
        { "/postmaster reset",  "clear all tracked progress" },
    }
    -- Gutter is MEASURED off the widest command, not hardcoded the way croakwatch's 190 is -
    -- calculate UI values, never guess. Adding a longer command later then reflows the
    -- column automatically instead of silently overlapping its description.
    local col = 0
    for _, c in ipairs(cmds) do
        local w = imgui.CalcTextSize("  " .. c[1])
        if w > col then col = w end
    end
    col = col + 18
    for _, c in ipairs(cmds) do
        imgui.TextColored(0.70, 0.85, 1.00, 1, "  " .. c[1])
        imgui.SameLine(col)
        imgui.TextDisabled(c[2])
    end

    imgui.Separator()
    coloredText(0.90, 0.76, 0.36, "Tips")
    -- Bullet + SameLine(0,0) + TextWrapped rather than BulletText: these tips are full sentences that
    -- would run off a 520-wide window, and BulletText does not wrap. Pattern confirmed in petgear.
    for _, t in ipairs({
        "Letters are TEMPORARY - they vanish on death and after roughly 30 minutes logged out, so "
            .. "never carry one somewhere risky.",
        "The Tax Collection Box has to sit in a MAIN inventory slot, never inside a bag, or the "
            .. "quest will not register what you collect.",
        "If a delivery fails, retry it with this script's own button while it still holds the "
            .. "letter. Handing one in manually is what breaks tracking - the game gives a script no "
            .. "way to find out that happened.",
        "The satchel is Lore but also Heirloom. Bank the first, then hail Lysric again on the same "
            .. "character for a second: 40 slots in total.",
        "High Keep's gnoll pack has killed low-level characters repeatedly, even with a speed buff. "
            .. "A pet soaking the aggro is what actually worked.",
        "Vicus Nonad will not talk to you? Your Antonius Bayle faction is too low. The Faction tab's "
            .. "Bone Chips run raises it - Dark Elves, Trolls, Ogres and Iksar start low there.",
        "A shroud empties EQ's Faction window, and it stays empty after you remove the shroud until you "
            .. "camp to character select and come back. The Faction tab's Run and Check need you as yourself.",
        "Hover almost anything - buttons, statuses and counts explain themselves.",
    }) do
        imgui.Bullet()
        imgui.SameLine(0, 0)
        imgui.TextWrapped(t)
    end

    imgui.Separator()
    coloredText(0.90, 0.76, 0.36, "Version")
    imgui.TextColored(0.70, 0.85, 1.00, 1, "Postmaster v" .. version)
    imgui.TextDisabled("Created by RedFrog")
end

local function renderUI()
    -- BEFORE the hidden/minimized returns, so transitions that happen while the window is minimized or
    -- hidden are still latched and get applied the moment it comes back. Cheap - a few TLO reads.
    ui.trackTransitions()
    if hidden then return end
    if ui.minimized then ui.mini(); return end
    -- Unity's proportions: width locked, height free to auto-fit whatever the open tab needs, so the
    -- window is never a tall half-empty box.
    -- Width still locked, but height is now RESIZABLE rather than auto-fitting the content. That is
    -- a requirement, not a preference: the banner is meant to stay put while each tab's body scrolls
    -- underneath it, and a container that always grows to fit its content can never scroll.
    -- Croakwatch's own shape (locked width, height between a floor and 4000, remembered per user).
    imgui.SetNextWindowSizeConstraints(520, 280, 520, 4000)
    imgui.SetNextWindowSize(520, 640, ImGuiCond.FirstUseEver)
    -- Rounded chrome, croakwatch's values. MUST be popped on every exit path, including the early
    -- return below - a stranded PushStyleVar corrupts ImGui's stack and shows up as white flashing
    -- and frozen windows.
    local nc = ui.pushTheme()
    imgui.PushStyleVar(ImGuiStyleVar.WindowRounding, 9)
    imgui.PushStyleVar(ImGuiStyleVar.ChildRounding, 6)
    imgui.PushStyleVar(ImGuiStyleVar.FrameRounding, 5)
    imgui.PushStyleVar(ImGuiStyleVar.ScrollbarRounding, 6)
    imgui.PushStyleVar(ImGuiStyleVar.TabRounding, 5)
    -- NoTitleBar: the banner art IS the title bar, with our own _/X overlaid on it. Deliberately NOT
    -- also passing NoScrollbar (croakwatch does, but it manages its own scrolling child regions and
    -- we don't) - if a tab ever grows past the screen, a scrollbar is the difference between
    -- awkward and unusable. With no title bar the window is dragged by any empty part of its body.
    local pOpen, show = imgui.Begin("Postmaster##postmaster", true, ImGuiWindowFlags.NoTitleBar)
    if not pOpen then
        running = false          -- X button stops the script (fleet standard - see CroakWatch)
        imgui.End()
        imgui.PopStyleVar(5)
        imgui.PopStyleColor(nc)
        return
    end
    if show then
        ui.drawBanner()   -- above the tab bar, so it belongs to the window rather than one tab
        if imgui.BeginTabBar("##pmtabs") then
            ui.tab("Overview",   "##ovbody", ui.overview)
            ui.tab("Deliveries", "##dlbody", ui.deliveries)
            ui.tab("Faction",    "##fcbody", ui.faction)
            ui.tab("Settings",   "##stbody", ui.settings)
            ui.tab("Help",       "##hpbody", ui.help)
            imgui.EndTabBar()
        end
    end
    imgui.End()
    imgui.PopStyleVar(5)
    imgui.PopStyleColor(nc)
end


-- Main

loadState()
poll()
syncTaxesFromBox()   -- reflect any taxes already in the box on startup
mq.imgui.init('postmaster', renderUI)

mq.bind('/postmaster', function(arg)
    arg = (arg or ""):lower()
    if arg == 'exit' or arg == 'quit' then
        running = false
    elseif arg == 'travel' or arg == 'go' then
        travelRequested = true
    elseif arg == 'nonad' then
        nonadRequested = true
    elseif arg == 'pm' or arg == 'challenge' then
        pmRequested = true
    elseif arg == 'lysric' then
        lysricRequested = true
    elseif arg == 'debug' then
        pmDebug = not pmDebug
        print('\ay[Postmaster]\ax debug output ' .. (pmDebug and 'ON - step-by-step diagnostics will print.' or 'off.'))
    elseif arg == 'navpause' then
        mq.cmd('/nav pause')
    elseif arg == 'navcontinue' or arg == 'navresume' then
        mq.cmd('/nav pause off')
    elseif arg == 'reset' then
        state.postmasterDone, state.nonadDone, state.lysricDone, state.factionAck = false, false, false, false
        state.challengeStarted = false
        for i = 1, #DELIVERIES do state.deliveries[i] = false end
        state.held = {}
        state.taxes = {}
        state.taxesInVicus = false
        saveState()
        print('\ag[Postmaster]\ax progress reset.')
    else
        hidden = not hidden
    end
end)

print(string.format('\ag[Postmaster]\ax v%s loaded - /postmaster hides/shows the window; the X button closes it.', version))

-- Auto-travel on launch when asked (/lua run postmaster travel).
for _, a in ipairs(launchArgs) do
    if a:lower() == 'travel' or a:lower() == 'go' then travelRequested = true end
end

-- A record left on disk means the last session ended without its restore (a /lua stop or a crash) - put
-- the player's own AutoSize settings back FIRST, so a fresh apply captures their real ones, not ours.
fit.restore()
if state.fitCounters then fit.request = true end

local lastPoll = 0
while running do
    mq.doevents()
    local nowShrouded = mq.TLO.Me.Shrouded()
    if lastShroudedState == true and nowShrouded == false then
        -- Shrouding TO true already gets a detailed message from getGoblinRogueShroud() when the script
        -- does it; unshrouding has no equivalent anywhere (manual "say remove" included), so this is the
        -- one direction that actually needs a passive catch-all - both directions clear chat with no
        -- other confirmation (AL, 2026-08-11).
        print('\ag[Postmaster]\ax no longer shrouded - back to normal form.')
    end
    lastShroudedState = nowShrouded
    -- v2.61: WHO YOU ARE is read as yourself, never from a shroud. myRace was read once at start - and a script
    -- started in a shroud read the MONSTER ("Goblin"): the Emerald Warriors estimate lost an Iksar's -1,000 (AL:
    -- "about 0 Red Wine to go" at Dubious, and a run that would not start), and factionRisk read false. Re-read here
    -- whenever unshrouded - the script stays open through a camp, so a restart is not needed any more.
    if not nowShrouded then
        local race = mq.TLO.Me.Race()
        if race and race ~= "" and race ~= myRace then
            myRace = race
            factionRisk = myRace == "Dark Elf" or myRace == "Troll" or myRace == "Ogre" or myRace == "Iksar"
        end
    end
    if fit.request ~= nil then
        local want = fit.request
        fit.request = nil
        if want then fit.apply() else fit.restore() end
    end
    if travelRequested then
        travelRequested = false
        travelToSunriseHills()
    end
    if nonadRequested then
        nonadRequested = false
        runNonadStep()
    end
    if vicusBoxRequested then
        vicusBoxRequested = false
        retryStep("Go to Vicus", getTaxBoxDirect)
    end
    if pmRequested then
        pmRequested = false
        runPostmasterStep()
    end
    if lysricRequested then
        lysricRequested = false
        runLysricStep()
    end
    if faction.check then
        local i = faction.check
        faction.check = nil
        faction.refresh(faction.helpers[i])
        if faction.empty then
            faction.last, faction.given = i, 0
            faction.status = "Can't read it: " .. faction.emptyWhy() .. "."
            print('\ay[Postmaster]\ax ' .. faction.status)
        elseif faction.last == i and not faction.active then
            faction.status = ""   -- a good read replaces an old "can't read it" line
        end
    end
    if faction.unshroud then
        local i = faction.unshroud
        faction.unshroud = nil
        faction.unshroudNow(i)
    end
    if faction.request then
        local i = faction.request
        faction.request = nil
        faction.run(i)
    end
    if syncHeldIdx then
        local idx = syncHeldIdx
        syncHeldIdx = nil
        local cursorId = mq.TLO.Cursor.ID() or 0
        if cursorId > 0 then
            local cursorName = mq.TLO.Cursor.Name()
            for _ = 1, 4 do
                if (mq.TLO.Cursor.ID() or 0) == 0 then break end
                mq.cmd('/autoinventory')
                mq.delay(400)
            end
            if (mq.TLO.Cursor.ID() or 0) > 0 then
                print(string.format('\ar[Postmaster]\ax delivery %d - %s is still on your cursor, could not stow it. Clear a slot and try Sync held again.', idx, tostring(cursorName)))
            else
                state.held[idx] = cursorId
                saveState()
                print(string.format('\ag[Postmaster]\ax delivery %d synced as held (%s).', idx, tostring(cursorName)))
            end
        else
            print('\ay[Postmaster]\ax nothing on your cursor - put delivery ' .. idx .. '\'s letter on your cursor first, then click Sync held.')
        end
    end
    ui.drainSpeech()
    if mq.gettime() - lastPoll > 2000 then
        poll()
        syncTaxesFromBox()
        detectNonadReward()
        lastPoll = mq.gettime()
    end
    mq.delay(250)
end

-- Closing with X or /postmaster exit lands here. A /lua stop does not - that case is caught at the next
-- start instead, from the record fit.apply saved to disk.
fit.restore()
