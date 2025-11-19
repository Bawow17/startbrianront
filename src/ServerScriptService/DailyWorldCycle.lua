local DailyWorldCycle = {}

local SECONDS_PER_DAY = 24 * 60 * 60
local RESET_HOUR_UTC = 18
local RESET_MINUTE_UTC = 00
local REFRESH_OFFSET = RESET_HOUR_UTC * 60 * 60 + RESET_MINUTE_UTC * 60

local function currentUnixTime()
    return DateTime.now().UnixTimestamp
end

function DailyWorldCycle.getCycleStartUnix(timestamp)
    local now = timestamp or currentUnixTime()
    local shifted = now - REFRESH_OFFSET
    local start = math.floor(shifted / SECONDS_PER_DAY) * SECONDS_PER_DAY + REFRESH_OFFSET
    return start
end

function DailyWorldCycle.getCycleId(timestamp)
    local cycleStart = DailyWorldCycle.getCycleStartUnix(timestamp)
    return math.floor(cycleStart / SECONDS_PER_DAY)
end

function DailyWorldCycle.getCycleInfo()
    local now = currentUnixTime()
    local cycleStart = DailyWorldCycle.getCycleStartUnix(now)
    local nextRefresh = cycleStart + SECONDS_PER_DAY

    return {
        cycleId = DailyWorldCycle.getCycleId(now),
        cycleStartUnix = cycleStart,
        nextRefreshUnix = nextRefresh,
        nowUnix = now,
    }
end

function DailyWorldCycle.getCycleInfoForCycleId(targetCycleId)
    targetCycleId = targetCycleId or DailyWorldCycle.getCycleId()
    local cycleStart = targetCycleId * SECONDS_PER_DAY + REFRESH_OFFSET
    return {
        cycleId = targetCycleId,
        cycleStartUnix = cycleStart,
        nextRefreshUnix = cycleStart + SECONDS_PER_DAY,
        nowUnix = currentUnixTime(),
    }
end

function DailyWorldCycle.getNextCycleInfo(baseCycleId)
    local nextId = (baseCycleId or DailyWorldCycle.getCycleId()) + 1
    return DailyWorldCycle.getCycleInfoForCycleId(nextId)
end

function DailyWorldCycle.makeSeed(baseSeed, cycleId)
    local id = cycleId or DailyWorldCycle.getCycleId()
    local base = baseSeed or 0
    return base + id * 1000003
end

function DailyWorldCycle.hasCycleChanged(lastCycleId)
    local id = DailyWorldCycle.getCycleId()
    return id > (lastCycleId or -math.huge)
end

function DailyWorldCycle.getScheduleVersion()
    return RESET_HOUR_UTC * 60 + RESET_MINUTE_UTC
end

return DailyWorldCycle
