if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
-- EllesmereUIChatNotify_Options.lua
--
-- Our own settings window, built with EllesmereUI's widget factory and visual
-- primitives so it reads as part of the suite.
--
-- It has to be our own window: EllesmereUI:RegisterModule() only accepts calls
-- from a hardcoded list of suite folders (EllesmereUI.lua), and the options
-- sidebar is built from a fixed roster (EllesmereUI.ADDON_GROUPS), so a page
-- inside their panel is not available to a third-party addon. The widgets and
-- primitives themselves are plain functions with no such gate. EllesmereUI_-
-- WindTools reaches the same conclusion and builds its own panel the same way.
-------------------------------------------------------------------------------
local addonName, ns = ...
if not (EllesmereUI and EllesmereUI.Lite) then return end

local ECN = ns.ECN
if not ECN then return end

-------------------------------------------------------------------------------
--  Layout
--
--  Width is not free choice: a DualRow half is (contentW - 90) / 2, and a
--  slider eats ~212px of its half. At 1040 total the label still gets ~128px,
--  which "Repeat Delay" fits. Narrower and the slider labels start ellipsizing.
-------------------------------------------------------------------------------
local PANEL_W, PANEL_H = 1040, 660
local HEADER_H   = 52
local NAV_W      = 180
local CONTENT_W  = PANEL_W - NAV_W - 10
local NAV_ROW_H  = 34
local SCROLL_BAR_W = 4

local ACCENT = EllesmereUI.ELLESMERE_GREEN or { r = 0.05, g = 0.82, b = 0.62 }

local NAV_SELECTED_TEXT = { r = 1, g = 1, b = 1, a = 1 }
local NAV_NORMAL_TEXT   = { r = 1, g = 1, b = 1, a = 0.6 }
local NAV_HOVER_TEXT    = { r = 1, g = 1, b = 1, a = 0.86 }

local panel           -- the window, created on first open
local contentHost     -- scroll child; every page frame lives in here
local UpdateThumb     -- scrollbar thumb updater
local navButtons = {} -- page key -> nav row
local pages = {}      -- page key -> { frame, refreshes, height, built }
local activePage
local builtForProfile

local function C() return ECN.DB() end

local MakeFont   = EllesmereUI.MakeFont
local SolidTex   = EllesmereUI.SolidTex
local MakeBorder = EllesmereUI.MakeBorder

-------------------------------------------------------------------------------
--  Widget factory availability
--
--  EllesmereUIOptions is LoadOnDemand, so on a fresh login it is not in memory
--  until something asks for it. Reports its own failures, so callers stay quiet.
-------------------------------------------------------------------------------
local function EnsureWidgets()
    if EllesmereUI.Widgets then return true end

    -- EllesmereUI:EnsureLoaded() is the only correct entry point, and loading
    -- the addon by hand is not enough: every options file -- the widget factory
    -- included -- wraps its ENTIRE body in a closure queued onto
    -- EllesmereUI._deferredInits, and nothing but EnsureLoaded drains that
    -- queue. C_AddOns.LoadAddOn on its own therefore returns success while
    -- leaving EllesmereUI.Widgets nil. It also handles the pieces the factory
    -- depends on (unlock core first, standalone builds, a failed options load
    -- left retryable) and reports its own reason when the addon will not load.
    if EllesmereUI.EnsureLoaded then
        pcall(EllesmereUI.EnsureLoaded, EllesmereUI)
        if EllesmereUI.Widgets then return true end
    end

    ECN.Print("EllesmereUI could not provide the settings controls. If it just told you why, "
        .. "fix that and try again.")
    return false
end

--- Re-read every value the active page displays. Also re-applies `disabled`
--- dimming, which is why it runs after each setter and not only on open.
local function RefreshValues()
    local page = activePage and pages[activePage]
    if not page then return end
    for i = 1, #page.refreshes do page.refreshes[i]() end
end

--- Wrap a setter: apply it, re-assert the EllesmereUIChat whisper handoff (a
--- whisper stream or the master switch may have just changed), then refresh.
local function Set(fn)
    return function(value)
        fn(value)
        ECN.SyncChatWhisper(true)
        RefreshValues()
    end
end

-------------------------------------------------------------------------------
--  Thin scrollbar, in the suite's idiom: a barely-there track that only
--  appears when there is something to scroll, with a proportional thumb.
-------------------------------------------------------------------------------
local function AttachScrollBar(scroll)
    local track = CreateFrame("Frame", nil, scroll)
    track:SetWidth(SCROLL_BAR_W)
    track:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -2, -2)
    track:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", -2, 2)
    track:SetFrameLevel(scroll:GetFrameLevel() + 3)
    track:Hide()
    SolidTex(track, "BACKGROUND", 1, 1, 1, 0.02):SetAllPoints()

    local thumb = CreateFrame("Frame", nil, track)
    thumb:SetWidth(SCROLL_BAR_W)
    thumb:SetHeight(40)
    thumb:SetPoint("TOP", track, "TOP", 0, 0)
    thumb:SetFrameLevel(track:GetFrameLevel() + 1)
    SolidTex(thumb, "ARTWORK", 1, 1, 1, 0.25):SetAllPoints()

    local function Update()
        local maxScroll = scroll:GetVerticalScrollRange()
        if maxScroll <= 0 then track:Hide() return end
        track:Show()
        local trackH = track:GetHeight()
        local visH = scroll:GetHeight()
        local thumbH = math.max(30, trackH * (visH / (visH + maxScroll)))
        thumb:SetHeight(thumbH)
        local ratio = scroll:GetVerticalScroll() / maxScroll
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", track, "TOP", 0, -(ratio * (trackH - thumbH)))
    end

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = self:GetVerticalScrollRange()
        if maxScroll <= 0 then return end
        local target = self:GetVerticalScroll() - delta * 45
        self:SetVerticalScroll(math.min(maxScroll, math.max(0, target)))
        Update()
    end)
    scroll:SetScript("OnScrollRangeChanged", Update)

    return Update
end

-------------------------------------------------------------------------------
--  Page builders
-------------------------------------------------------------------------------
local function SoundCfg(label, get, set, disabled)
    local _, names, order = ECN.GetSounds()
    return {
        type = "dropdown", text = label, values = names, order = order,
        getValue = get,
        -- Selecting a sound previews it: picking blind from a 40-entry list and
        -- waiting for a guild message to find out what you chose is no way to
        -- configure this.
        setValue = Set(function(v) set(v); ECN.PlayKey(v) end),
        disabled = disabled,
    }
end

local function BuildGeneral(parent)
    local W = EllesmereUI.Widgets
    local _, y, h = nil, -10, 0

    _, h = W:SectionHeader(parent, "GENERAL", y); y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle", text = "Enable Sound Notifications",
        tooltip = "Master switch. Off means no sound from this addon at all.",
        getValue = function() return C().enabled end,
        setValue = Set(function(v) C().enabled = v end),
    }, {
        type = "slider", text = "Repeat Delay", min = 0, max = 15, step = 1, trackWidth = 120,
        tooltip = "Minimum gap in seconds between two sounds on the same chat stream, so a busy conversation does not machine-gun.",
        getValue = function() return C().throttle end,
        setValue = function(v) C().throttle = v end,
        disabled = function() return not C().enabled end,
    }); y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle", text = "Silence During Boss Encounters",
        tooltip = "No sounds between the pull and the end of a boss encounter.",
        getValue = function() return C().suppressInEncounter end,
        setValue = Set(function(v) C().suppressInEncounter = v end),
        disabled = function() return not C().enabled end,
    }, {
        type = "toggle", text = "Silence While In Combat",
        tooltip = "No sounds at any time you are in combat. Broader than the boss-encounter option and will hide whispers while questing.",
        getValue = function() return C().suppressInCombat end,
        setValue = Set(function(v) C().suppressInCombat = v end),
        disabled = function() return not C().enabled end,
    }); y = y - h

    return -y
end

local function BuildWatchlist(parent)
    local W = EllesmereUI.Widgets
    local _, y, h = nil, -10, 0
    local function watchOff() return not (C().enabled and C().watch.enabled) end

    _, h = W:SectionHeader(parent, "WATCHLIST", y); y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle", text = "Enable Watchlist",
        tooltip = "Fires on any chat stream, including streams whose own sound is turned off.",
        getValue = function() return C().watch.enabled end,
        setValue = Set(function(v) C().watch.enabled = v end),
        disabled = function() return not C().enabled end,
    }, SoundCfg("Watchlist Sound",
        function() return C().watch.sound end,
        function(v) C().watch.sound = v end,
        watchOff)); y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle", text = "Match My Character Name",
        tooltip = "Treat your own character name as a watched keyword.",
        getValue = function() return C().watch.matchPlayerName end,
        setValue = Set(function(v) C().watch.matchPlayerName = v end),
        disabled = watchOff,
    }, {
        type = "slider", text = "Repeat Delay", min = 0, max = 15, step = 1, trackWidth = 120,
        tooltip = "Watchlist hits throttle separately, in seconds, so an important message is not swallowed by ordinary chatter.",
        getValue = function() return C().watch.throttle end,
        setValue = function(v) C().watch.throttle = v end,
        disabled = watchOff,
    }); y = y - h

    _, h = W:DualRow(parent, y, {
        type = "input", text = "Keywords", inputStyle = "popup", inputWidth = 420,
        placeholder = "inv, invite, summon",
        tooltip = "Comma separated. Matched anywhere in the message, ignoring case.",
        getValue = function() return C().watch.words end,
        setValue = function(v) C().watch.words = v end,
        disabled = watchOff,
    }); y = y - h

    _, h = W:DualRow(parent, y, {
        type = "input", text = "Senders", inputStyle = "popup", inputWidth = 420,
        placeholder = "Tymesink, Someguildie",
        tooltip = "Comma separated character or Battle.net names. Realm suffixes are ignored.",
        getValue = function() return C().watch.senders end,
        setValue = function(v) C().watch.senders = v end,
        disabled = watchOff,
    }); y = y - h

    return -y
end

local function BuildStreams(parent)
    local W = EllesmereUI.Widgets
    local _, y, h = nil, -10, 0

    _, h = W:SectionHeader(parent, "CHAT STREAMS", y); y = y - h

    for _, stream in ipairs(ECN.STREAMS) do
        local key = stream.key
        _, h = W:DualRow(parent, y, {
            type = "toggle", text = stream.label,
            getValue = function() return C().streams[key].enabled end,
            setValue = Set(function(v) C().streams[key].enabled = v end),
            disabled = function() return not C().enabled end,
        }, SoundCfg("Sound",
            function() return C().streams[key].sound end,
            function(v) C().streams[key].sound = v end,
            function() return not (C().enabled and C().streams[key].enabled) end)); y = y - h
    end

    return -y
end

local PAGES = {
    { key = "general",   label = "General",      build = BuildGeneral },
    { key = "watchlist", label = "Watchlist",    build = BuildWatchlist },
    { key = "streams",   label = "Chat Streams", build = BuildStreams },
}

-------------------------------------------------------------------------------
--  Page construction, isolated from EllesmereUI's own options panel in two
--  ways the widget factory otherwise takes for granted:
--
--    * Search index. Every row it builds registers into EllesmereUI's global
--      options search, keyed by the module and page it thinks it is building.
--      Ours belong to neither, so an indexed row would be a search hit that
--      cannot be navigated to. Park the indexer while we build.
--
--    * Refresh registry. `_widgetRefreshList` is ONE shared list that their
--      panel clears on page enter and folds into its page cache on page leave.
--      Building into it would both leak our closures into their cache and get
--      ours wiped on their next page switch. So we snapshot theirs away, build
--      into an empty list, harvest what our widgets registered, and hand their
--      list back untouched. (WindTools does the same dance, but clears their
--      list outright instead of putting it back.)
-------------------------------------------------------------------------------
local function BuildPage(entry)
    local page = pages[entry.key]
    if page and page.built then return page end

    if not page then
        local frame = CreateFrame("Frame", nil, contentHost)
        frame:SetWidth(CONTENT_W)
        frame:SetHeight(1)
        frame:SetPoint("TOPLEFT", contentHost, "TOPLEFT", 0, 0)
        frame:Hide()
        page = { frame = frame, refreshes = {}, height = 1 }
        pages[entry.key] = page
    end

    local savedIndexer = EllesmereUI._RegisterSearchEntry
    local Snapshot = EllesmereUI._SnapshotAndClearWidgetRefreshList
    local Restore  = EllesmereUI._RestoreWidgetRefreshList

    local theirs = Snapshot and Snapshot() or nil
    EllesmereUI._RegisterSearchEntry = nil

    local ok, result = pcall(entry.build, page.frame)

    wipe(page.refreshes)
    if Snapshot then
        local mine = Snapshot()
        for i = 1, #mine do page.refreshes[i] = mine[i] end
    end
    if Restore and theirs then Restore(theirs) end
    EllesmereUI._RegisterSearchEntry = savedIndexer

    if ok then
        page.height = result or 1
        page.built = true
    else
        ECN.Print("|cffff6060Could not build the " .. entry.label .. " page:|r " .. tostring(result))
    end

    page.frame:SetHeight(page.height)
    return page
end

local function SelectPage(key)
    local entry
    for _, e in ipairs(PAGES) do if e.key == key then entry = e break end end
    if not entry then return end

    if activePage and pages[activePage] then pages[activePage].frame:Hide() end

    local page = BuildPage(entry)
    activePage = key
    page.frame:Show()
    contentHost:SetHeight(page.height)

    for k, btn in pairs(navButtons) do
        local selected = (k == key)
        local c = selected and NAV_SELECTED_TEXT or NAV_NORMAL_TEXT
        btn._label:SetTextColor(c.r, c.g, c.b, c.a)
        btn._marker:SetShown(selected)
        btn._hl:SetAlpha(selected and 0.05 or 0)
    end

    panel._scroll:SetVerticalScroll(0)
    if UpdateThumb then UpdateThumb() end
    RefreshValues()
end

-------------------------------------------------------------------------------
--  Chrome
-------------------------------------------------------------------------------
local function CreateNavRow(parent, entry, index)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(NAV_W - 20, NAV_ROW_H)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -(10 + (index - 1) * NAV_ROW_H))

    local hl = SolidTex(btn, "BACKGROUND", 1, 1, 1, 1)
    hl:SetAllPoints()
    hl:SetAlpha(0)
    btn._hl = hl

    local marker = SolidTex(btn, "ARTWORK", ACCENT.r, ACCENT.g, ACCENT.b, 1)
    marker:SetWidth(2)
    marker:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, -6)
    marker:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 6)
    marker:Hide()
    btn._marker = marker

    local label = MakeFont(btn, 13, nil, NAV_NORMAL_TEXT.r, NAV_NORMAL_TEXT.g, NAV_NORMAL_TEXT.b, NAV_NORMAL_TEXT.a)
    label:SetPoint("LEFT", btn, "LEFT", 14, 0)
    label:SetText(entry.label)
    btn._label = label

    btn:SetScript("OnEnter", function(self)
        if activePage == entry.key then return end
        self._hl:SetAlpha(0.04)
        self._label:SetTextColor(NAV_HOVER_TEXT.r, NAV_HOVER_TEXT.g, NAV_HOVER_TEXT.b, NAV_HOVER_TEXT.a)
    end)
    btn:SetScript("OnLeave", function(self)
        if activePage == entry.key then return end
        self._hl:SetAlpha(0)
        self._label:SetTextColor(NAV_NORMAL_TEXT.r, NAV_NORMAL_TEXT.g, NAV_NORMAL_TEXT.b, NAV_NORMAL_TEXT.a)
    end)
    btn:SetScript("OnClick", function() SelectPage(entry.key) end)

    return btn
end

local function CreatePanel()
    local f = CreateFrame("Frame", "EllesmereUIChatNotifyOptionsFrame", UIParent)
    f:SetSize(PANEL_W, PANEL_H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()

    SolidTex(f, "BACKGROUND", 0.055, 0.055, 0.055, 0.96):SetAllPoints()
    if MakeBorder then MakeBorder(f, 1, 1, 1, 0.08) end

    local headerLine = SolidTex(f, "ARTWORK", 1, 1, 1, 0.06)
    headerLine:SetHeight(1)
    headerLine:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -HEADER_H)
    headerLine:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -HEADER_H)

    local brand = MakeFont(f, 16, nil, ACCENT.r, ACCENT.g, ACCENT.b, 1)
    brand:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -18)
    brand:SetText("EllesmereUI")

    local title = MakeFont(f, 16, nil, 1, 1, 1, 1)
    title:SetPoint("LEFT", brand, "RIGHT", 6, 0)
    title:SetText("ChatNotify")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    close:SetScript("OnClick", function() f:Hide() end)

    -- Nav rail
    local nav = CreateFrame("Frame", nil, f)
    nav:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -(HEADER_H + 1))
    nav:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    nav:SetWidth(NAV_W)

    local navEdge = SolidTex(nav, "ARTWORK", 1, 1, 1, 0.06)
    navEdge:SetWidth(1)
    navEdge:SetPoint("TOPRIGHT", nav, "TOPRIGHT", 0, 0)
    navEdge:SetPoint("BOTTOMRIGHT", nav, "BOTTOMRIGHT", 0, 0)

    for i, entry in ipairs(PAGES) do
        navButtons[entry.key] = CreateNavRow(nav, entry, i)
    end

    -- Content
    local scroll = CreateFrame("ScrollFrame", nil, f)
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", NAV_W + 1, -(HEADER_H + 1))
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 8)

    local host = CreateFrame("Frame", nil, scroll)
    host:SetSize(CONTENT_W, 1)
    scroll:SetScrollChild(host)

    f._scroll = scroll
    UpdateThumb = AttachScrollBar(scroll)

    -- Escape closes it, same as every other settings window.
    tinsert(UISpecialFrames, "EllesmereUIChatNotifyOptionsFrame")

    return f, host
end

-------------------------------------------------------------------------------
--  Entry point
-------------------------------------------------------------------------------
function ECN.ToggleOptions()
    if panel and panel:IsShown() then
        panel:Hide()
        return
    end

    if not EnsureWidgets() then return end  -- it has already said why

    if not panel then
        panel, contentHost = CreatePanel()
    end

    -- Pages are discarded on a profile change only: widgets read live values
    -- through their getters, but a profile switch re-points the whole db
    -- underneath them.
    local activeProfile = (EllesmereUIDB and EllesmereUIDB.activeProfile) or "Default"
    if builtForProfile ~= activeProfile then
        for _, page in pairs(pages) do
            page.frame:Hide()
            page.frame:SetParent(nil)
        end
        wipe(pages)
        builtForProfile = activeProfile
        activePage = nil
    end

    panel:Show()
    SelectPage(activePage or PAGES[1].key)
end
