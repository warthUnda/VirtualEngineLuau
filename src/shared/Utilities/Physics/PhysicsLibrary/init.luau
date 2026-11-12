--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const PhysicsFolder = ReplicatedStorage:WaitForChild("Shared")
	:WaitForChild("Utilities")
	:WaitForChild("Physics") :: Folder

-- Modules --
const PhysicsController = require(PhysicsFolder:WaitForChild("Controller"):WaitForChild("PhysicsController"))

local PhysicsLibrary = {}

-- ============================================================================
-- 1. DYNAMIC ENTITY & OBJECT SIMULATION CALLS
-- ============================================================================

function PhysicsLibrary.SetEntityDynamic(EntityId: number, IsDynamic: boolean, CustomMass: number?)
	PhysicsController.SetEntityDynamic(EntityId, IsDynamic, CustomMass)
end

function PhysicsLibrary.SimulateInstance(EntityId: number, CustomMass: number?)
	PhysicsController.SetEntityDynamic(EntityId, true, CustomMass)
end

function PhysicsLibrary.StopSimulatingInstance(EntityId: number)
	PhysicsController.SetEntityDynamic(EntityId, false)
end

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

function PhysicsLibrary.JumpPlayer()
	PhysicsController.AddPlayerMovement(0, 0, 0, 0, true, false)
end

function PhysicsLibrary.GetPlayerPosition(): Vector3
	return PhysicsController.GetPlayerPosition()
end

function PhysicsLibrary.SetPlayerPosition(NewPosition: Vector3)
	PhysicsController.SetPlayerPosition(NewPosition)
end

function PhysicsLibrary.GetPlayerVelocity(): Vector3
	return PhysicsController.GetPlayerVelocity()
end

function PhysicsLibrary.SetPlayerVelocity(NewVelocity: Vector3)
	PhysicsController.SetPlayerVelocity(NewVelocity)
end

function PhysicsLibrary.IsPlayerGrounded(): boolean
	return PhysicsController.IsPlayerGrounded()
end

return PhysicsLibrary
