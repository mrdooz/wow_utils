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
-- Pandemic
-- --------
-- Refreshing a HoT carries the remaining duration (capped at 30% of base) into
-- the new duration. We mirror that math from local cast times so refreshes stay
-- in sync without ever reading the aura. Carry only applies when the new cast
-- targets the same unit as the previous one; we resolve the target from
-- UNIT_SPELLCAST_SENT (works for target frames, mouseover, clique, Healbot,
-- etc. — anything that resolves a unit before the cast goes out).
--
-- Caveats we can't address inside Midnight's API restrictions:
--   * Bloom ending without a cast (target dies, dispelled, you die) — our model
--     thinks it's still up, so a recast within 15s carries phantom pandemic.
--   * Auto-applies from procs/talents — no SUCCEEDED event for those.
--   * Reload mid-bloom resets state; first post-reload cast skips carry.
--   * Use /lba reset to force a clean slate.

local _, playerClass = UnitClass("player")
if playerClass ~= "DRUID" then return end

local LIFEBLOOM_SPELL_ID = 33763
local DURATION = 15
local WARN_LEAD = 3
local PANDEMIC_FACTOR = 0.3
-- FileDataID for the cash register sound. Path-based lookup
-- ("Sound\Interface\CashRegister.ogg") played nothing; FileDataID works.
local ALERT_SOUND = 7466070

local DEBUG = false
local warnTimer = nil
local lastCastTime = 0
local lastDuration = 0
local lastTargetName = nil
-- Stashed from UNIT_SPELLCAST_SENT, consumed by the next SUCCEEDED. Lifebloom
-- is instant, so SENT immediately precedes SUCCEEDED with nothing in between.
local pendingTarget = nil

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

local function FullReset(reason)
    CancelTimer(reason)
    lastCastTime = 0
    lastDuration = 0
    lastTargetName = nil
    pendingTarget = nil
end

local function StartTimer(target)
    CancelTimer("restart")
    local now = GetTime()
    local carryover = 0
    -- Pandemic carry only applies on a same-target refresh. Unknown target
    -- (SENT didn't fire) is treated as fresh — safer to fire early than late.
    if lastCastTime > 0 and target and target == lastTargetName then
        -- Subtract from lastDuration (not DURATION): a previous pandemic refresh
        -- extended the bloom past the base, and that remainder is still real.
        local remaining = math.max(0, lastDuration - (now - lastCastTime))
        carryover = math.min(remaining, DURATION * PANDEMIC_FACTOR)
    end
    lastCastTime = now
    lastDuration = DURATION + carryover
    lastTargetName = target
    local delay = lastDuration - WARN_LEAD
    warnTimer = C_Timer.NewTimer(delay, function()
        warnTimer = nil
        dprint("alert!")
        PlayAlert()
    end)
    dprint("timer set for %.1fs (target=%s carry=%.1fs)", delay, tostring(target), carryover)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        FullReset("reload")
        return
    end
    if event == "UNIT_SPELLCAST_SENT" then
        local _unit, target, _castGUID, spellID = ...
        if spellID == LIFEBLOOM_SPELL_ID then pendingTarget = target end
        return
    end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _unit, _castGUID, spellID = ...
        if spellID == LIFEBLOOM_SPELL_ID then
            StartTimer(pendingTarget)
            pendingTarget = nil
        end
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
        FullReset("manual")
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
