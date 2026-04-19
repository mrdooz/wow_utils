-- Thunder Blast Alert — plays a sound / TTS when the Thunder Blast buff reaches 2 stacks.
--
-- Stack tracking strategy
-- -----------------------
-- We don't read the aura stacks directly. Midnight's taint system returns nil or
-- secret-tainted fields when aura APIs are called from any automatic context
-- (UNIT_AURA handlers, C_Timer callbacks, OnUpdate). Instead, we simulate the
-- stack count locally by listening to two Blizzard-side notifications:
--
--   * SPELL_ACTIVATION_OVERLAY_GLOW_SHOW  -> a stack was gained (proc / refresh)
--   * SPELL_ACTIVATION_OVERLAY_GLOW_HIDE  -> the buff is fully gone
--   * UNIT_SPELLCAST_SUCCEEDED (435222)   -> a stack was consumed
--
-- The counter lives entirely in Lua memory; BUFF_DURATION is a safety timer in case
-- we ever miss a HIDE. Casting Thunder Blast also triggers a spurious GLOW_SHOW (the
-- glow repaints for the remaining stack); CONSUME_GRACE suppresses that re-entry.
--
-- Why not just read the aura?
-- ---------------------------
-- Tried and abandoned in Midnight (all confirmed broken or blocked 2026-04-19):
--   * C_UnitAuras.GetPlayerAuraBySpellID inside UNIT_AURA handler -> returns nil
--   * UNIT_AURA updateInfo.addedAuras     -> spellId/applications are secret-tainted
--   * COMBAT_LOG_EVENT_UNFILTERED         -> RegisterEvent is protected
--   * C_Timer.After(0, read aura)         -> timer inherits taint, returns nil
--   * C_UnitAuras.AddPrivateAuraAppliedSound -> only works for server-flagged private auras
--
-- Short-circuit on non-Warriors so the whole file never loads for them.
local _, playerClass = UnitClass("player")
if playerClass ~= "WARRIOR" then return end

local ADDON_NAME = "ThunderBlastAlert"

-- Thunder Blast has two IDs in play: the buff (435615) and the cast spell that
-- replaces Thunder Clap while the buff is up (435222). GLOW_SHOW/HIDE events
-- can reference either, so we accept both for aura-change detection.
local THUNDER_BLAST_IDS = {
    [435615] = true, -- buff
    [435222] = true, -- cast
}
-- UNIT_SPELLCAST_SUCCEEDED only ever sees the cast ID.
local THUNDER_BLAST_CAST_ID = 435222

local TRIGGER_STACKS = 2
local BUFF_DURATION = 20

local PRESETS = {
    [1]  = { name = "Ready Check",          kitID = 8959 },
    [2]  = { name = "Raid Warning",         kitID = 8960 },
    [3]  = { name = "Level Up",             kitID = 888 },
    [4]  = { name = "Auction Window Open",  kitID = 873 },
    [5]  = { name = "Map Ping",             kitID = 823 },
    [6]  = { name = "Mail Received",        kitID = 3175 },
    [7]  = { name = "PvP Flag Captured",    kitID = 8174 },
    [8]  = { name = "Murloc Aggro",         kitID = 6674 },
    [9]  = { name = "Alarm Clock",          kitID = 12867 },
    [10] = { name = "Raid Invite",          kitID = 10720 },
    [11] = { name = "Loot Coin Small",      kitID = 120 },
    [12] = { name = "Duel Started",         kitID = 7266 },
}

local SOURCES = {
    [1] = { key = "preset", label = "Preset Sound" },
    [2] = { key = "tts",    label = "Text-to-Speech" },
    [3] = { key = "custom", label = "Custom Kit ID" },
}

local CHANNELS = {
    [1] = "Master",
    [2] = "SFX",
    [3] = "Music",
    [4] = "Ambience",
    [5] = "Dialog",
}

local DEFAULTS = {
    source = 1,
    presetChoice = 1,
    customKitID = 8959,
    channel = 1,
    ttsText = "Thunder Blast",
    ttsVoice = 0,
}

local DEBUG = false
local stacks = 0
local expirationTimer = nil
local settingsCategoryID = nil
-- Casting Thunder Blast fires a spurious GLOW_SHOW right after the cast (the
-- glow re-paints for the remaining stack). Without this grace window, the
-- re-show would be counted as a new proc and re-trigger the alert.
local lastConsumeTime = 0
local CONSUME_GRACE = 0.25

local function db() return ThunderBlastAlertDB end

local function dprint(fmt, ...)
    if DEBUG then print(("|cff33ff99TBA|r " .. fmt):format(...)) end
end

local function GetChannel() return CHANNELS[db().channel] or "Master" end

-- TextToSpeech_Speak is the only reliable TTS path in Midnight: C_VoiceChat.SpeakText
-- still exists but Enum.VoiceTtsDestination was removed, leaving no way to construct
-- the dest arg. The second arg must be a voice TABLE (from GetTtsVoices) - passing a
-- number raises "attempt to index local 'voice' (a number value)".
local function SpeakTTS(text)
    if not TextToSpeech_Speak then
        print("|cffff5555TBA|r TextToSpeech_Speak unavailable"); return
    end
    local voices = C_VoiceChat and C_VoiceChat.GetTtsVoices and C_VoiceChat.GetTtsVoices() or {}
    if #voices == 0 then
        print("|cffff5555TBA|r no TTS voices"); return
    end
    local voice = nil
    for _, v in ipairs(voices) do
        if v.voiceID == db().ttsVoice then voice = v; break end
    end
    if not voice then voice = voices[1] end
    dprint("TTS voiceID=%s name=%s text=%q", tostring(voice.voiceID), tostring(voice.name), tostring(text))
    local ok, err = pcall(TextToSpeech_Speak, text or "", voice)
    if not ok then print("|cffff5555TBA|r TTS error: " .. tostring(err)) end
end

local function PlayPreset(idx)
    local p = PRESETS[idx] or PRESETS[1]
    PlaySound(p.kitID, GetChannel())
end

local function PlayCustom()
    PlaySound(db().customKitID, GetChannel())
end

local function PlayAlert()
    local source = SOURCES[db().source] or SOURCES[1]
    if source.key == "preset" then PlayPreset(db().presetChoice)
    elseif source.key == "tts" then SpeakTTS(db().ttsText)
    elseif source.key == "custom" then PlayCustom()
    end
end

local function ResetStacks(reason)
    if stacks ~= 0 then dprint("reset (%s): stacks %d -> 0", reason, stacks) end
    stacks = 0
    if expirationTimer then expirationTimer:Cancel(); expirationTimer = nil end
end

local function AddStack()
    local was = stacks
    stacks = math.min(stacks + 1, TRIGGER_STACKS)
    dprint("stacks %d -> %d", was, stacks)
    if expirationTimer then expirationTimer:Cancel() end
    expirationTimer = C_Timer.NewTimer(BUFF_DURATION, function() ResetStacks("expired") end)
    if stacks >= TRIGGER_STACKS and was < TRIGGER_STACKS then
        PlayAlert()
    end
end

local function ConsumeStack()
    if stacks <= 0 then return end
    local was = stacks
    stacks = stacks - 1
    lastConsumeTime = GetTime()
    dprint("consumed: stacks %d -> %d", was, stacks)
    if stacks == 0 and expirationTimer then
        expirationTimer:Cancel(); expirationTimer = nil
    end
end

-- Multi-generation schema migration: the addon shipped through several internal
-- config layouts (single 'choice' int, then 'choice' string key, then 'source' +
-- 'lsmChoice'). Map any of those into the current { source, presetChoice } shape.
local function MigrateDB()
    -- Old: 4-source layout with LSM at index 2 → remap to 3-source layout
    if ThunderBlastAlertDB.source == 2 and ThunderBlastAlertDB.lsmChoice ~= nil then
        ThunderBlastAlertDB.source = 1
    elseif ThunderBlastAlertDB.source == 3 then
        ThunderBlastAlertDB.source = 2
    elseif ThunderBlastAlertDB.source == 4 then
        ThunderBlastAlertDB.source = 3
    end
    ThunderBlastAlertDB.lsmChoice = nil

    -- Older: single 'choice' field
    local c = ThunderBlastAlertDB.choice
    if c ~= nil then
        if type(c) == "string" then
            if c == "tts" then ThunderBlastAlertDB.source = 2
            elseif c == "custom" then ThunderBlastAlertDB.source = 3
            elseif c:match("^preset:") then
                ThunderBlastAlertDB.source = 1
                ThunderBlastAlertDB.presetChoice = tonumber(c:match(":(%d+)")) or 1
            else
                ThunderBlastAlertDB.source = 1
            end
        elseif type(c) == "number" then
            if c == 13 then ThunderBlastAlertDB.source = 3
            elseif c == 14 then ThunderBlastAlertDB.source = 2
            elseif c >= 1 and c <= #PRESETS then
                ThunderBlastAlertDB.source = 1
                ThunderBlastAlertDB.presetChoice = c
            end
        end
        ThunderBlastAlertDB.choice = nil
    end
end

local function popupEdit(popup) return popup.EditBox or popup.editBox end

StaticPopupDialogs["TBA_SET_TTS"] = {
    text = "Thunder Blast Alert — text to speak:",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 200,
    OnShow = function(self)
        local eb = popupEdit(self)
        eb:SetText(db().ttsText or ""); eb:HighlightText(); eb:SetFocus()
    end,
    OnAccept = function(self)
        db().ttsText = popupEdit(self):GetText()
        SpeakTTS(db().ttsText)
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        db().ttsText = popupEdit(parent):GetText()
        SpeakTTS(db().ttsText); parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true,
}

StaticPopupDialogs["TBA_SET_CUSTOM_ID"] = {
    text = "Custom sound kit ID (number):",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 12,
    OnShow = function(self)
        local eb = popupEdit(self)
        eb:SetText(tostring(db().customKitID or "")); eb:HighlightText(); eb:SetFocus()
    end,
    OnAccept = function(self)
        local n = tonumber(popupEdit(self):GetText())
        if n then
            db().customKitID = n
            PlayCustom()
        end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true,
}

local frame = CreateFrame("Frame")
frame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
frame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
frame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        ThunderBlastAlertDB = ThunderBlastAlertDB or {}
        for k, v in pairs(DEFAULTS) do
            if ThunderBlastAlertDB[k] == nil then ThunderBlastAlertDB[k] = v end
        end
        MigrateDB()
        TBA_InitSettings()
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        ResetStacks("reload")
        return
    end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if arg3 == THUNDER_BLAST_CAST_ID then ConsumeStack() end
        return
    end
    local spellID = arg1
    if not THUNDER_BLAST_IDS[spellID] then return end
    if event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
        if GetTime() - lastConsumeTime < CONSUME_GRACE then
            dprint("ignoring glow show (post-consume grace)")
        else
            AddStack()
        end
    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        ResetStacks("glow hide")
    end
end)

function TBA_InitSettings()
    if not Settings or not Settings.RegisterVerticalLayoutCategory then return end

    local category = Settings.RegisterVerticalLayoutCategory("Thunder Blast Alert")

    local sourceOptions = function()
        local c = Settings.CreateControlTextContainer()
        for i, s in ipairs(SOURCES) do c:Add(i, s.label) end
        return c:GetData()
    end
    local sourceSetting = Settings.RegisterAddOnSetting(
        category, "ThunderBlastAlert_Source", "source",
        ThunderBlastAlertDB, Settings.VarType.Number,
        "Source", DEFAULTS.source)
    Settings.CreateDropdown(category, sourceSetting, sourceOptions,
        "Which kind of sound to play at 2 stacks.")
    sourceSetting:SetValueChangedCallback(function() PlayAlert() end)

    local presetOptions = function()
        local c = Settings.CreateControlTextContainer()
        for i, p in ipairs(PRESETS) do c:Add(i, p.name) end
        return c:GetData()
    end
    local presetSetting = Settings.RegisterAddOnSetting(
        category, "ThunderBlastAlert_Preset", "presetChoice",
        ThunderBlastAlertDB, Settings.VarType.Number,
        "Preset Sound", DEFAULTS.presetChoice)
    Settings.CreateDropdown(category, presetSetting, presetOptions,
        "Preset sound (used when Source = Preset). Previews on change.")
    presetSetting:SetValueChangedCallback(function(_, value) PlayPreset(value) end)

    local channelOptions = function()
        local c = Settings.CreateControlTextContainer()
        for i, name in ipairs(CHANNELS) do c:Add(i, name) end
        return c:GetData()
    end
    local channelSetting = Settings.RegisterAddOnSetting(
        category, "ThunderBlastAlert_Channel", "channel",
        ThunderBlastAlertDB, Settings.VarType.Number,
        "Sound Channel", DEFAULTS.channel)
    Settings.CreateDropdown(category, channelSetting, channelOptions,
        "Audio channel for preset/custom sounds (TTS uses its own path).")
    channelSetting:SetValueChangedCallback(function() PlayAlert() end)

    local voicesList = C_VoiceChat and C_VoiceChat.GetTtsVoices and C_VoiceChat.GetTtsVoices() or {}
    if #voicesList > 0 then
        local ttsVoiceOptions = function()
            local c = Settings.CreateControlTextContainer()
            for _, v in ipairs(voicesList) do
                c:Add(v.voiceID, tostring(v.name or ("voice " .. tostring(v.voiceID))))
            end
            return c:GetData()
        end
        local ttsVoiceSetting = Settings.RegisterAddOnSetting(
            category, "ThunderBlastAlert_TTSVoice", "ttsVoice",
            ThunderBlastAlertDB, Settings.VarType.Number,
            "TTS Voice", DEFAULTS.ttsVoice)
        Settings.CreateDropdown(category, ttsVoiceSetting, ttsVoiceOptions,
            "Which system voice to use. Previews on change.")
        ttsVoiceSetting:SetValueChangedCallback(function() SpeakTTS(db().ttsText) end)
    end

    Settings.RegisterAddOnCategory(category)
    settingsCategoryID = category:GetID()
end

SLASH_THUNDERBLASTALERT1 = "/tba"
SlashCmdList.THUNDERBLASTALERT = function(msg)
    msg = (msg or ""):match("^%s*(.-)%s*$") or ""
    local cmd, rest = msg:match("^(%S+)%s*(.*)$")
    cmd = cmd or msg

    if cmd == "debug" then
        DEBUG = not DEBUG
        print(("|cff33ff99TBA|r debug = %s"):format(tostring(DEBUG)))
    elseif cmd == "reset" then
        ResetStacks("manual")
    elseif cmd == "tts" or cmd == "ttsedit" then
        StaticPopup_Show("TBA_SET_TTS")
    elseif cmd == "customid" then
        StaticPopup_Show("TBA_SET_CUSTOM_ID")
    elseif cmd == "config" or cmd == "options" then
        -- OpenSettingsPanel is protected in Midnight; it logs ADDON_ACTION_BLOCKED to
        -- BugGrabber but the panel still opens. It also hard-errors while in combat.
        if InCombatLockdown() then
            print("|cffff5555TBA|r can't open settings panel in combat")
        elseif settingsCategoryID then
            Settings.OpenToCategory(settingsCategoryID)
        else
            print("|cffff5555TBA|r settings not initialized yet")
        end
    else
        print("|cff33ff99TBA|r cmds: config | tts | customid | debug | reset")
        PlayAlert()
    end
end
