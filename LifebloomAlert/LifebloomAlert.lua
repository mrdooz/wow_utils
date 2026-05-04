-- Lifebloom Alert — plays the Cash Register sound 3 seconds before Lifebloom drops.
--
-- Tracking strategy
-- -----------------
-- Polls C_UnitAuras.GetAuraDataBySpellName from OnUpdate every 0.25s. Walks a
-- cached unit list (player, target, focus, mouseover, party/raid frames) and
-- returns the first Lifebloom whose source is the player. The aura's
-- expirationTime is the source of truth — Blizzard already accounts for
-- pandemic refreshes, Swiftmend extensions, dispels, target death, and any
-- other bloom-touching effect. No local state to keep in sync.
--
-- A previous version of this addon avoided aura reads entirely because of
-- Midnight's taint on aura APIs in automatic contexts. That comment called out
-- UNIT_AURA handlers and C_Timer callbacks specifically; OnUpdate appears to
-- be safe (LifebloomTracker uses the same approach and works). If alerts ever
-- silently stop after a Midnight patch, taint is the first thing to suspect.

local _, playerClass = UnitClass("player")
if playerClass ~= "DRUID" then return end

local LIFEBLOOM_SPELL_ID = 33763
local LIFEBLOOM_SPELL_NAME  -- cached after PLAYER_ENTERING_WORLD when API is ready
local WARN_LEAD = 3
local SCAN_INTERVAL = 0.25
-- FileDataID for the cash register sound. Path-based lookup
-- ("Sound\Interface\CashRegister.ogg") played nothing; FileDataID works.
local ALERT_SOUND = 7466070

local DEBUG = false
local cachedUnits = { "player", "target", "focus", "mouseover" }
-- expirationTime of the bloom we last alerted on. A refresh, recast, or new
-- target produces a different expirationTime, which re-arms the alert.
local lastWarnedExpire = 0
local scanAccum = 0

local function dprint(fmt, ...)
    if DEBUG then print(("|cff33ff99LBA|r " .. fmt):format(...)) end
end

local function PlayAlert()
    PlaySoundFile(ALERT_SOUND, "Master")
end

local function RebuildUnitsCache()
    cachedUnits = { "player", "target", "focus", "mouseover" }
    if IsInRaid() then
        for i = 1, 40 do cachedUnits[#cachedUnits + 1] = "raid" .. i end
    elseif IsInGroup() then
        for i = 1, 4 do cachedUnits[#cachedUnits + 1] = "party" .. i end
    end
end

local function FindMyLifebloom()
    if not LIFEBLOOM_SPELL_NAME then return nil end
    for _, unit in ipairs(cachedUnits) do
        if UnitExists(unit) then
            local aura = C_UnitAuras.GetAuraDataBySpellName(unit, LIFEBLOOM_SPELL_NAME, "HELPFUL")
            if aura and aura.sourceUnit == "player" then
                return aura, unit
            end
        end
    end
    return nil, nil
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_ENTERING_WORLD" then
        if not LIFEBLOOM_SPELL_NAME then
            LIFEBLOOM_SPELL_NAME = C_Spell.GetSpellName(LIFEBLOOM_SPELL_ID)
        end
        RebuildUnitsCache()
        lastWarnedExpire = 0
    elseif event == "GROUP_ROSTER_UPDATE" then
        RebuildUnitsCache()
    end
end)

frame:SetScript("OnUpdate", function(_, elapsed)
    scanAccum = scanAccum + elapsed
    if scanAccum < SCAN_INTERVAL then return end
    scanAccum = 0

    local aura = FindMyLifebloom()
    if not aura then return end

    local expire = aura.expirationTime or 0
    local rem = expire - GetTime()
    if rem > 0 and rem <= WARN_LEAD and expire ~= lastWarnedExpire then
        lastWarnedExpire = expire
        dprint("alert! rem=%.2f", rem)
        PlayAlert()
    end
end)

SLASH_LIFEBLOOMALERT1 = "/lba"
SlashCmdList.LIFEBLOOMALERT = function(msg)
    msg = (msg or ""):match("^%s*(.-)%s*$") or ""
    local cmd, rest = msg:match("^(%S+)%s*(.*)$")
    cmd = cmd or msg
    rest = rest or ""

    if cmd == "debug" then
        DEBUG = not DEBUG
        print(("|cff33ff99LBA|r debug = %s"):format(tostring(DEBUG)))
    elseif cmd == "test" then
        PlayAlert()
    elseif cmd == "status" then
        local aura, unit = FindMyLifebloom()
        if aura then
            local name = (unit and UnitName(unit)) or unit or "?"
            print(("|cff33ff99LBA|r bloom on %s, %.1fs remaining"):format(
                name, (aura.expirationTime or 0) - GetTime()))
        else
            print("|cff33ff99LBA|r no bloom found")
        end
    elseif cmd == "kit" then
        local n = tonumber(rest)
        if not n then print("|cffff5555LBA|r usage: /lba kit <number>"); return end
        local ok = PlaySound(n, "Master")
        print(("|cff33ff99LBA|r kit %d: %s"):format(n, ok and "playing" or "rejected (bad kit id?)"))
    elseif cmd == "file" then
        if rest == "" then print("|cffff5555LBA|r usage: /lba file <id_or_path>"); return end
        local arg = tonumber(rest) or rest
        local ok = PlaySoundFile(arg, "Master")
        print(("|cff33ff99LBA|r file %s: %s"):format(tostring(arg), ok and "playing" or "rejected (bad file/path?)"))
    else
        print("|cff33ff99LBA|r cmds: test | status | debug | kit <id> | file <id_or_path>")
    end
end
