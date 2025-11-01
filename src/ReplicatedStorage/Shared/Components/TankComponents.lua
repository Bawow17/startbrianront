local TankComponents = {}

local DEFAULTS = {
	MoveSpeed = 18,
	Acceleration = 80,
	Drag = 40,
	TurnRate = math.rad(360),
	MaxHealth = 100,
	RegenPerSecond = 5,
	RegenDelay = 2,
}

function TankComponents.createMovementComponent(overrides)
	overrides = overrides or {}
	return {
		Position = overrides.Position or Vector3.new(),
		Velocity = overrides.Velocity or Vector3.new(),
		Facing = overrides.Facing or 0,
		MoveSpeed = overrides.MoveSpeed or DEFAULTS.MoveSpeed,
		Acceleration = overrides.Acceleration or DEFAULTS.Acceleration,
		Drag = overrides.Drag or DEFAULTS.Drag,
		TurnRate = overrides.TurnRate or DEFAULTS.TurnRate,
	}
end

function TankComponents.createHealthComponent(overrides)
	overrides = overrides or {}
	local maxHealth = overrides.MaxHealth or DEFAULTS.MaxHealth
	return {
		MaxHealth = maxHealth,
		CurrentHealth = overrides.CurrentHealth or maxHealth,
		RegenPerSecond = overrides.RegenPerSecond or DEFAULTS.RegenPerSecond,
		RegenDelay = overrides.RegenDelay or DEFAULTS.RegenDelay,
		LastDamageTime = overrides.LastDamageTime or 0,
	}
end

function TankComponents.createInputState()
	return {
		Move = Vector3.zero,
		AimDirection = Vector3.new(0, 0, -1),
		IsFiring = false,
	}
end

return TankComponents

