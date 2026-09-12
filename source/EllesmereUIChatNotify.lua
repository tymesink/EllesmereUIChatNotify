if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
-- EllesmereUIChatNotify.lua
--
-- Plays a sound when a chat message arrives. Every stream gets its own on/off
-- toggle and sound; on top of that a watchlist (keywords + sender names) fires
-- a different, louder sound regardless of whether that stream's own toggle is
-- on -- the "guild chat is muted, but ping me if someone says my name" case.
--
-- Events are registered directly rather than hooking ChatFrame_OnEvent. The
-- old TymeUI_ChatNotify hooked it only to reach ChatFrame's `tellTimer` for
-- whisper throttling, which this file replaces with its own per-stream clock.
-------------------------------------------------------------------------------
local addonName, ns = ...

-- Stale-parent guard: a partially updated install (old EllesmereUI, new child)
-- goes dormant instead of erroring. Deliberately does NOT set EUI_CLIENT_BLOCKED
-- the way suite members do -- that global disables every EllesmereUI file that
-- loads after it, which is not a third-party module's call to make.
if not (EllesmereUI and EllesmereUI.Lite and EllesmereUI._ModuleNS) then return end
EllesmereUI._ModuleNS[addonName] = ns

local ECN = {}
ns.ECN = ECN
_G.EllesmereUIChatNotify = ECN

local EUILite = EllesmereUI.Lite
local addon = EUILite.NewAddon("EllesmereUIChatNotify")
ECN.addon = addon

local PREFIX = "|cff0cd29fEllesmereUI|r ChatNotify: "

local function Print(msg)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg) end
end
ECN.Print = Print

-------------------------------------------------------------------------------
--  Streams
--
--  One entry per notifiable chat stream. `events` lists the CHAT_MSG_* suffixes
--  that feed it: leader variants fold into their base stream because a sound
--  cannot tell you who spoke, so a separate "party leader" sound only ever
--  meant a second row in the options page. Raid Warning stays separate -- that
--  one really is a different kind of message.
-------------------------------------------------------------------------------
local STREAMS = {
    { key = "guild",     label = "Guild",             events = { "GUILD" } },
    { key = "officer",   label = "Officer",           events = { "OFFICER" } },
    { key = "party",     label = "Party",             events = { "PARTY", "PARTY_LEADER" } },
    { key = "raid",      label = "Raid",              events = { "RAID", "RAID_LEADER" } },
    { key = "warning",   label = "Raid Warning",      events = { "RAID_WARNING" } },
    { key = "instance",  label = "Instance Group",    events = { "INSTANCE_CHAT", "INSTANCE_CHAT_LEADER" } },
    { key = "channel",   label = "Custom Channels",   events = { "CHANNEL" } },
    { key = "whisper",   label = "Whisper",           events = { "WHISPER" } },
    { key = "bnwhisper", label = "Battle.net Whisper", events = { "BN_WHISPER" } },
    { key = "say",       label = "Say",               events = { "SAY" } },
    { key = "yell",      label = "Yell",              events = { "YELL" } },
}
ECN.STREAMS = STREAMS

-- "CHAT_MSG_RAID_LEADER" -> "raid"
local EVENT_STREAM = {}
for _, s in ipairs(STREAMS) do
    for _, ev in ipairs(s.events) do
        EVENT_STREAM["CHAT_MSG_" .. ev] = s.key
    end
end

-------------------------------------------------------------------------------
--  Defaults
--
--  Lives in EllesmereUIDB.profiles[active].addons.EllesmereUIChatNotify via
--  EUILite.NewDB, so profile switching re-points it with the rest of the suite
--  (EllesmereUI_Profiles.lua RepointAllDBs walks the whole Lite db registry).
-------------------------------------------------------------------------------
local DEFAULTS = {
    profile = {
        enabled             = true,
        throttle            = 2,      -- seconds between sounds on one stream
        suppressInCombat    = false,  -- off: too aggressive for questing/dungeons
        suppressInEncounter = true,   -- on: boss fights are where pings hurt most
        streams             = {},     -- filled below
        watch = {
            enabled         = false,
            sound           = "none",
            throttle        = 1,      -- a watch hit outranks chatter, so shorter
            matchPlayerName = true,   -- your character name counts as a keyword
            words           = "",     -- comma-separated, matched anywhere in the message
            senders         = "",     -- comma-separated character / Battle.net names
        },
        chatWhisperSaved    = nil,    -- EllesmereUIChat's sound key while we hold it parked
    },
}
for _, s in ipairs(STREAMS) do
    DEFAULTS.profile.streams[s.key] = { enabled = false, sound = "none" }
end
ECN.DEFAULTS = DEFAULTS

local function DB()
    return ECN.db and ECN.db.profile
end
ECN.DB = DB

-------------------------------------------------------------------------------
--  Sound catalogue
--
--  Same tables the rest of the suite uses for its alert pickers: EllesmereUI's
--  bundled sounds plus everything any addon has registered with LibSharedMedia.
--  Rebuilt on demand because LSM registrations keep arriving after login.
-------------------------------------------------------------------------------
local soundPaths, soundNames, soundOrder

function ECN.RefreshSounds()
    soundPaths, soundNames, soundOrder = EllesmereUI.BuildAlertSoundTables()
    if EllesmereUI.AppendSharedMediaSounds then
        EllesmereUI.AppendSharedMediaSounds(soundPaths, soundNames, soundOrder)
    end
    return soundPaths, soundNames, soundOrder
end

function ECN.GetSounds()
    if not soundPaths then ECN.RefreshSounds() end
    return soundPaths, soundNames, soundOrder
end

--- Play a catalogue key. "none" and unresolvable keys (an LSM sound whose
--- addon is not loaded this session) are silent rather than an error.
function ECN.PlayKey(key)
    if not key or key == "none" then return end
    local paths = ECN.GetSounds()
    local path = paths[key]
    if path then PlaySoundFile(path, "Master") end
end

-------------------------------------------------------------------------------
--  Suppression state
-------------------------------------------------------------------------------
local inEncounter = false
local lastPlayed = {}  -- stream key (or "@watch") -> GetTime() of last sound

--- Trim a "Name-Realm" to "name" for watchlist comparison. Sender names arrive
--- realm-qualified for cross-realm players and bare for same-realm ones, so
--- matching either form against a typed-in name needs both sides normalized.
local function NormalizeName(name)
    if not name or name == "" then return nil end
    local base = name:match("^([^-]+)") or name
    return base:lower()
end

--- Split a comma-separated options string into a lowercase lookup list.
--- Parsed per message rather than cached: these lists are a handful of entries
--- and the alternative is cache invalidation wired into every options setter.
local function SplitList(text)
    if not text or text == "" then return nil end
    local out
    for piece in text:gmatch("[^,]+") do
        local trimmed = piece:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            out = out or {}
            out[#out + 1] = trimmed:lower()
        end
    end
    return out
end
ECN.SplitList = SplitList

--- True when the message trips the watchlist: a keyword anywhere in the text,
--- your own character name when that option is on, or a listed sender.
local function MatchesWatch(cfg, text, sender)
    local watch = cfg.watch
    if not watch.enabled then return false end

    local lowerText = text and text:lower()

    if lowerText then
        if watch.matchPlayerName then
            local me = NormalizeName(UnitName("player"))
            if me and lowerText:find(me, 1, true) then return true end
        end
        local words = SplitList(watch.words)
        if words then
            for _, w in ipairs(words) do
                if lowerText:find(w, 1, true) then return true end
            end
        end
    end

    local senders = SplitList(watch.senders)
    if senders then
        local who = NormalizeName(sender)
        if who then
            for _, s in ipairs(senders) do
                if who == NormalizeName(s) then return true end
            end
        end
    end

    return false
end

--- Shared gate for both sound paths. Returns false when the sound should be
--- swallowed: throttled, or muted by a suppression toggle.
local function CanPlay(cfg, slot, throttle)
    if cfg.suppressInEncounter and inEncounter then return false end
    if cfg.suppressInCombat and InCombatLockdown() then return false end

    local now = GetTime()
    if now - (lastPlayed[slot] or 0) < (throttle or 0) then return false end
    lastPlayed[slot] = now
    return true
end

-------------------------------------------------------------------------------
--  Message handling
--
--  12.x ships "secret" values: a chat argument the addon is not permitted to
--  read, most reliably the sender on every Battle.net whisper. Any string
--  operation or comparison on one errors, so every argument below is tested
--  before use and simply drops out of the decision when it is secret. This is
--  why EllesmereUIChat's own whisper handler reads no arguments at all.
-------------------------------------------------------------------------------
local issecretvalue = _G.issecretvalue

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v)
end

local function OnChatMessage(_, event, text, sender, _, _, _, flags, zoneChannelID, _, _, _, _, guid)
    local cfg = DB()
    if not cfg or not cfg.enabled then return end

    local streamKey = EVENT_STREAM[event]
    if not streamKey then return end

    -- Your own messages echo back on every group/guild stream. GUID beats the
    -- old name comparison: it is realm-proof and needs no name formatting.
    if not IsSecret(guid) and guid and guid == UnitGUID("player") then return end

    -- AFK / DND auto-replies and the chat system's own COM messages are noise.
    if not IsSecret(flags) and (flags == "AFK" or flags == "DND" or flags == "COM") then return end

    -- CHAT_MSG_CHANNEL covers both custom channels and Blizzard's zone channels
    -- (General, Trade, LocalDefense). A nonzero zoneChannelID marks the latter,
    -- and Trade chat pinging every few seconds is nobody's idea of a feature.
    -- An unreadable id is treated as a zone channel: silence is the safer guess
    -- for the one stream that can fire every few seconds.
    if streamKey == "channel" then
        if IsSecret(zoneChannelID) then return end
        if zoneChannelID and zoneChannelID > 0 then return end
    end

    local stream = cfg.streams[streamKey]

    -- Watchlist runs before the stream toggle on purpose: a muted stream still
    -- pings when someone says your name. Its own slot keeps a watch hit from
    -- being eaten by the stream throttle. Secret arguments are withheld from
    -- the match rather than compared, so a Battle.net whisper falls through to
    -- its stream sound instead of erroring.
    if MatchesWatch(cfg, (not IsSecret(text)) and text or nil,
                         (not IsSecret(sender)) and sender or nil) then
        if CanPlay(cfg, "@watch", cfg.watch.throttle) then
            ECN.PlayKey(cfg.watch.sound)
        end
        return
    end

    if not (stream and stream.enabled) then return end
    if CanPlay(cfg, streamKey, cfg.throttle) then
        ECN.PlayKey(stream.sound)
    end
end

-------------------------------------------------------------------------------
--  EllesmereUIChat whisper handoff
--
--  EllesmereUIChat plays ONE sound for both CHAT_MSG_WHISPER and
--  CHAT_MSG_BN_WHISPER, off a single `whisperSoundKey` (EllesmereUIChat.lua).
--  So the moment either of our whisper streams goes live, a whisper pings
--  twice. Rather than make the user go turn theirs off, we take the stream
--  over: their key is parked in our profile and set to "none", and handed back
--  as soon as we stop covering whispers ourselves.
-------------------------------------------------------------------------------
function ECN.GetChatWhisperConfig()
    local chatNS = EllesmereUI._ModuleNS and EllesmereUI._ModuleNS["EllesmereUIChat"]
    local cfg = chatNS and chatNS.ECHAT and chatNS.ECHAT.DB and chatNS.ECHAT.DB()
    return cfg or _G._ECHAT_DB
end

local WHISPER_STREAMS = { "whisper", "bnwhisper" }

--- True when we would make a noise for a whisper of either kind.
local function WeCoverWhispers(cfg)
    if not cfg.enabled then return false end
    for _, key in ipairs(WHISPER_STREAMS) do
        local s = cfg.streams[key]
        if s and s.enabled and s.sound ~= "none" then return true end
    end
    return false
end

--- Park or restore EllesmereUIChat's whisper sound to match our own settings.
--- Safe to call on every settings change and at login: it only acts when the
--- two addons actually disagree. `announce` prints what changed, which is what
--- the options page wants and a silent login re-assert does not.
function ECN.SyncChatWhisper(announce)
    local cfg = DB()
    if not cfg then return end
    local theirs = ECN.GetChatWhisperConfig()
    if not theirs then return end  -- EllesmereUIChat not loaded; nothing to coordinate

    local theirKey = theirs.whisperSoundKey or "none"

    if WeCoverWhispers(cfg) then
        if theirKey ~= "none" then
            cfg.chatWhisperSaved = theirKey
            theirs.whisperSoundKey = "none"
            if announce then
                Print("EllesmereUIChat's whisper sound is now off -- one setting there covers "
                    .. "both whispers and Battle.net whispers, and ChatNotify has them.")
            end
        end
    elseif cfg.chatWhisperSaved then
        -- Hand back only what we parked, and only if nothing else has chosen a
        -- sound there since. If it has, theirs wins and we drop our copy.
        if theirKey == "none" then
            theirs.whisperSoundKey = cfg.chatWhisperSaved
            if announce then
                Print("EllesmereUIChat's whisper sound has been restored.")
            end
        end
        cfg.chatWhisperSaved = nil
    end
end

-------------------------------------------------------------------------------
--  Lifecycle
-------------------------------------------------------------------------------
function addon:OnInitialize()
    ECN.db = EUILite.NewDB("EllesmereUIChatNotifyDB", DEFAULTS)

    for event in pairs(EVENT_STREAM) do
        self:RegisterEvent(event, OnChatMessage)
    end

    self:RegisterEvent("ENCOUNTER_START", function() inEncounter = true end)
    self:RegisterEvent("ENCOUNTER_END", function() inEncounter = false end)

    -- A reload mid-fight leaves inEncounter false with no ENCOUNTER_START to
    -- come; leaving the instance is the reliable point to clear it either way.
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        if not IsInInstance() then inEncounter = false end
    end)

    SLASH_ELLESMEREUICHATNOTIFY1 = "/chatnotify"
    SLASH_ELLESMEREUICHATNOTIFY2 = "/cn"
    SlashCmdList["ELLESMEREUICHATNOTIFY"] = function()
        if ECN.ToggleOptions then
            ECN.ToggleOptions()
        else
            Print("Options are unavailable -- EllesmereUIChatNotify_Options.lua did not load.")
        end
    end
end

function addon:OnEnable()
    ECN.RefreshSounds()
    -- Deferred and silent: EllesmereUIChat's DB is built during its own
    -- OnEnable, and the queue order between two children is not something to
    -- depend on. This only re-asserts a handoff the user already chose, so it
    -- has nothing to announce.
    C_Timer.After(5, function() ECN.SyncChatWhisper(false) end)
end
