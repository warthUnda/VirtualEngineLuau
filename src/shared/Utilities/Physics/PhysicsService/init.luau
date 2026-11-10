local PhysicsService = {}

local PhysicsQueue = require(game.ReplicatedStorage.Shared.Utilities.Physics.PhysicsService)

function PhysicsService.New()
	local self = setmetatable({}, {})

	return self
end

function PhysicsService:SimulateInstance() end

return PhysicsService
