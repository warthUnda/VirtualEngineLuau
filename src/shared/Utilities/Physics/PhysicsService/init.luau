local PhysicsService = {}

local PhysicsQueue = require(game.ReplicatedStorage.Shared.Utilities.Physics.PhysicsMovementQueue)

function PhysicsService.New()
	local self = setmetatable({}, {})

	return self
end

function PhysicsService:SimulateInstance()
    PhysicsQueue.
end

return PhysicsService
