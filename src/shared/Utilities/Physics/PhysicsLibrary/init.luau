--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const PhysicsFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("Physics")

-- Libraries --
const PhysicsController = require(PhysicsFolder:WaitForChild("Controller"):WaitForChild("PhysicsController"))

-- Tables --
local PhysicsLibrary = {}

-- Functions --

-- ============================================================================
-- 1. DYNAMIC ENTITY & OBJECT SIMULATION CALLS
-- ============================================================================

--[=[
	Enables physics simulation for an ECS entity if it is not anchored, immediately applying launch angle, impulse, and speed (falling back to prepackaged PhysicsConfig defaults when nil).
	@param EntityId number -- Target ECS entity index.
	@param Angle (Vector3 | number)? -- Optional launch direction Vector3 or horizontal yaw angle in degrees (defaults to ObjectDefaultLaunchAngle).
	@param Impulse number? -- Optional instantaneous launch impulse in kg*m/s (defaults to ObjectDefaultImpulse).
	@param Speed number? -- Optional initial linear speed in studs/s (defaults to ObjectDefaultSpeed).
	@param CustomMass number? -- Optional explicit mass override in kg.
	@return boolean -- True if simulation started; false if entity is invalid or anchored.
]=]
function PhysicsLibrary.SimulateInstance(
	EntityId: number,
	Angle: (Vector3 | number)?,
	Impulse: number?,
	Speed: number?,
	CustomMass: number?
): boolean
	return PhysicsController.SimulateInstance(EntityId, Angle, Impulse, Speed, CustomMass)
end

--[=[
	Disables dynamic physics simulation for a registered entity and clears its velocities and forces.
	@param EntityId number -- Target ECS entity index.
]=]
function PhysicsLibrary.StopSimulatingInstance(EntityId: number)
	PhysicsController.StopSimulatingInstance(EntityId)
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
