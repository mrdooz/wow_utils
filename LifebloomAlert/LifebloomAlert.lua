-- Lifebloom Alert — plays the Cash Register sound 3 seconds before Lifebloom drops.
--
-- Tracking strategy
-- -----------------
-- Same constraint as ThunderBlastAlert: Midnight taints aura-read APIs inside
-- automatic contexts (UNIT_AURA handlers, C_Timer callbacks), so we can't poll
-- the buff's remaining duration. Instead UNIT_SPELLCAST_SUCCEEDED is the source
-- of truth: each successful Lifebloom cast (re)starts a local timer for
-- (DURATION - WARN_LEAD) seconds. When the timer fires, play the sound.
--
-- Caveats:
--   * Pandemic refreshes extend the real duration up to 30% beyond base. Our
--     timer doesn't know about that — it'll fire earlier than the actual 3s
--     mark when refreshed inside the pandemic window. For the stated goal
--     (don't let it drop), firing early is harmless.
--   * Death, dispel, or target loss aren't tracked. Use /lba reset if needed.
--   * Multi-target Lifebloom was removed in Midnight, so we only track one.

local _, playerClass = UnitClass("player")
if playerClass ~= "DRUID" then return end

local LIFEBLOOM_SPELL_ID = 33763
local DURATION = 15
local WARN_LEAD = 3
-- FileDataID for the cash register sound. Path-based lookup
-- ("Sound\Interface\CashRegister.ogg") played nothing; FileDataID works.
local ALERT_SOUND = 7466070

local DEBUG = false
local warnTimer = nil

local function dprint(fmt, ...)
    if DEBUG then print(("|cff33ff99LBA|r " .. fmt):format(...)) end
end

local function PlayAlert()
    PlaySoundFile(ALERT_SOUND, "Master")
end

local function CancelTimer(reason)
    if warnTimer then
        warnTimer:Cancel(); warnTimer = nil
        dprint("timer cancelled (%s)", reason)
    end
end

local function StartTimer()
    CancelTimer("restart")
    local delay = DURATION - WARN_LEAD
    warnTimer = C_Timer.NewTimer(delay, function()
        warnTimer = nil
        dprint("alert!")
        PlayAlert()
    end)
    dprint("timer set for %.1fs", delay)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
frame:SetScript("OnEvent", function(_, event, _, _, spellID)
    if event == "PLAYER_ENTERING_WORLD" then
        CancelTimer("reload")
        return
    end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if spellID == LIFEBLOOM_SPELL_ID then StartTimer() end
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
    elseif cmd == "reset" then
        CancelTimer("manual")
    elseif cmd == "test" then
        PlayAlert()
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
        print("|cff33ff99LBA|r cmds: test | reset | debug | kit <id> | file <id_or_path>")
    end
end
