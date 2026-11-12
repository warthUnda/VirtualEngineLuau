--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const PhysicsFolder = ReplicatedStorage:WaitForChild("Shared")
	:WaitForChild("Utilities")
	:WaitForChild("Physics")

-- Modules --
const PhysicsController = require(PhysicsFolder:WaitForChild("Controller"):WaitForChild("PhysicsController"))

local PhysicsLibrary = {}

-- ============================================================================
-- 1. DYNAMIC ENTITY & OBJECT SIMULATION CALLS
-- ============================================================================

--[=[
	Sets whether an ECS entity is dynamically simulated in the physics engine.
	@param EntityId number -- Target ECS entity index.
	@param IsDynamic boolean -- Whether the entity should be dynamic.
	@param CustomMass number? -- Optional explicit mass override in kg.
]=]
function PhysicsLibrary.SetEntityDynamic(EntityId: number, IsDynamic: boolean, CustomMass: number?)
	PhysicsController.SetEntityDynamic(EntityId, IsDynamic, CustomMass)
end

--[=[
	Enables physics simulation for a registered entity.
	@param EntityId number -- Target ECS entity index.
	@param CustomMass number? -- Optional explicit mass override in kg.
]=]
function PhysicsLibrary.SimulateInstance(EntityId: number, CustomMass: number?)
	PhysicsController.SetEntityDynamic(EntityId, true, CustomMass)
end

--[=[
	Disables dynamic physics simulation for a registered entity.
	@param EntityId number -- Target ECS entity index.
]=]
function PhysicsLibrary.StopSimulatingInstance(EntityId: number)
	PhysicsController.SetEntityDynamic(EntityId, false)
end

--[=[
	Directly queues continuous force or instantaneous impulse movement on an object.
	@param EntityId number -- Target ECS entity index.
	@param DirX number -- Unit force or impulse direction X.
	@param DirY number -- Unit force or impulse direction Y.
	@param DirZ number -- Unit force or impulse direction Z.
	@param Magnitude number -- Force (Newtons) or impulse (kg*m/s) magnitude.
	@param IsImpulse boolean? -- True if instantaneous impulse; false if continuous force.
]=]
function PhysicsLibrary.AddObjectMovement(
	EntityId: number,
	DirX: number,
	DirY: number,
	DirZ: number,
	Magnitude: number,
	IsImpulse: boolean?
)
	PhysicsController.AddObjectMovement(EntityId, DirX, DirY, DirZ, Magnitude, IsImpulse)
end

--[=[
	Applies a continuous world-space force to a dynamic object.
	@param EntityId number -- Target ECS entity index.
	@param Direction Vector3 -- Force direction vector.
	@param Magnitude number -- Force magnitude in Newtons.
]=]
function PhysicsLibrary.ApplyObjectForce(EntityId: number, Direction: Vector3, Magnitude: number)
	const DirLen = Direction.Magnitude :: number
	if DirLen <= 1e-6 or Magnitude == 0 then
		return
	end

	const InvLen = 1 / DirLen :: number
	PhysicsController.AddObjectMovement(
		EntityId,
		Direction.X * InvLen,
		Direction.Y * InvLen,
		Direction.Z * InvLen,
		Magnitude,
		false
	)
end

--[=[
	Applies an instantaneous world-space impulse to a dynamic object.
	@param EntityId number -- Target ECS entity index.
	@param Direction Vector3 -- Impulse direction vector.
	@param Magnitude number -- Impulse magnitude in kg*m/s.
]=]
function PhysicsLibrary.ApplyObjectImpulse(EntityId: number, Direction: Vector3, Magnitude: number)
	const DirLen = Direction.Magnitude :: number
	if DirLen <= 1e-6 or Magnitude == 0 then
		return
	end

	const InvLen = 1 / DirLen :: number
	PhysicsController.AddObjectMovement(
		EntityId,
		Direction.X * InvLen,
		Direction.Y * InvLen,
		Direction.Z * InvLen,
		Magnitude,
		true
	)
end

-- ============================================================================
-- 2. PLAYER MOVEMENT & STATE CALLS
-- ============================================================================

--[=[
	Directly queues wish-direction intent, jumping, or impulses on the local player.
	@param DirX number -- Wish-direction component X.
	@param DirY number -- Wish-direction component Y.
	@param DirZ number -- Wish-direction component Z.
	@param Scale number? -- Movement speed scale factor (defaults to 1).
	@param Jump boolean? -- Whether jump intent is triggered.
	@param IsImpulse boolean? -- True if instantaneous impulse.
]=]
function PhysicsLibrary.AddPlayerMovement(
	DirX: number,
	DirY: number,
	DirZ: number,
	Scale: number?,
	Jump: boolean?,
	IsImpulse: boolean?
)
	PhysicsController.AddPlayerMovement(DirX, DirY, DirZ, Scale, Jump, IsImpulse)
end

--[=[
	Moves the local player along a world-space direction vector with optional jump.
	@param Direction Vector3 -- Desired movement direction.
	@param Scale number? -- Movement speed scale factor.
	@param Jump boolean? -- Whether jump intent is active.
]=]
function PhysicsLibrary.MovePlayer(Direction: Vector3, Scale: number?, Jump: boolean?)
	const DirLen = Direction.Magnitude :: number
	if DirLen <= 1e-6 then
		if Jump then
			PhysicsController.AddPlayerMovement(0, 0, 0, 0, true, false)
		end
		return
	end

	const InvLen = 1 / DirLen :: number
	PhysicsController.AddPlayerMovement(
		Direction.X * InvLen,
		Direction.Y * InvLen,
		Direction.Z * InvLen,
		Scale,
		Jump,
		false
	)
end

--[=[
	Applies an instantaneous velocity impulse to the local player.
	@param Direction Vector3 -- Impulse direction vector.
	@param Magnitude number -- Impulse magnitude.
]=]
function PhysicsLibrary.ApplyPlayerImpulse(Direction: Vector3, Magnitude: number)
	const DirLen = Direction.Magnitude :: number
	if DirLen <= 1e-6 or Magnitude == 0 then
		return
	end

	const InvLen = 1 / DirLen :: number
	PhysicsController.AddPlayerMovement(
		Direction.X * InvLen,
		Direction.Y * InvLen,
		Direction.Z * InvLen,
		Magnitude,
		false,
		true
	)
end

--[=[
	Triggers an instantaneous jump for the local player.
]=]
function PhysicsLibrary.JumpPlayer()
	PhysicsController.AddPlayerMovement(0, 0, 0, 0, true, false)
end

--[=[
	Returns the current simulated position of the local player character.
	@return Vector3 -- Current position.
]=]
function PhysicsLibrary.GetPlayerPosition(): Vector3
	return PhysicsController.GetPlayerPosition()
end

--[=[
	Teleports the local player character to a new world position.
	@param NewPosition Vector3 -- Target world position.
]=]
function PhysicsLibrary.SetPlayerPosition(NewPosition: Vector3)
	PhysicsController.SetPlayerPosition(NewPosition)
end

--[=[
	Returns the current linear velocity of the local player character.
	@return Vector3 -- Current linear velocity.
]=]
function PhysicsLibrary.GetPlayerVelocity(): Vector3
	return PhysicsController.GetPlayerVelocity()
end

--[=[
	Sets the linear velocity of the local player character.
	@param NewVelocity Vector3 -- Target linear velocity.
]=]
function PhysicsLibrary.SetPlayerVelocity(NewVelocity: Vector3)
	PhysicsController.SetPlayerVelocity(NewVelocity)
end

--[=[
	Checks whether the local player character is currently resting on ground.
	@return boolean -- True if grounded.
]=]
function PhysicsLibrary.IsPlayerGrounded(): boolean
	return PhysicsController.IsPlayerGrounded()
end

return PhysicsLibrary
