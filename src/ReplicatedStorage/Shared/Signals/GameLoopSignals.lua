local GameLoopSignals = {}

local fixedStepBindable = Instance.new("BindableEvent")
local heartbeatBindable = Instance.new("BindableEvent")

GameLoopSignals.FixedStep = fixedStepBindable.Event
GameLoopSignals.Heartbeat = heartbeatBindable.Event

function GameLoopSignals._fireFixedStep(deltaTime)
	fixedStepBindable:Fire(deltaTime)
end

function GameLoopSignals._fireHeartbeat(deltaTime)
	heartbeatBindable:Fire(deltaTime)
end

return GameLoopSignals

