--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const PhysicsFolder = SharedFolder:WaitForChild("Utilities"):WaitForChild("Physics")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const PhysicsMath = require(PhysicsFolder:WaitForChild("Core"):WaitForChild("PhysicsMath"))
const PhysicsMathHelper = require(PhysicsFolder:WaitForChild("Core"):WaitForChild("PhysicsMathHelper"))
const PhysicsInputGateway = require(script.Parent.PhysicsInputGateway)

-- Configs --
const OBJECT_DEFAULT_DENSITY = SystemsConfigs.ObjectDefaultDensity :: number
const OBJECT_RESTITUTION = SystemsConfigs.ObjectRestitution :: number
const DEFAULT_LAUNCH_ANGLE = SystemsConfigs.ObjectDefaultLaunchAngle :: Vector3
const SLEEP_SPEED_THRESHOLD = SystemsConfigs.ObjectSleepSpeedThreshold :: number
const SLEEP_SPEED_SQ = SLEEP_SPEED_THRESHOLD * SLEEP_SPEED_THRESHOLD :: number
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const FLAG_CAN_COLLIDE = bit32.lshift(1, 1) :: number
const FLAG_IS_VISIBLE = bit32.lshift(1, 2) :: number
const FLAG_ANCHORED = bit32.lshift(1, 3) :: number

-- Tables --
local PhysicsControllerHelper = {
	ResolveObjectStorage = PhysicsInputGateway.ResolveObjectStorage,
	ConfigureCharacterInstance = PhysicsInputGateway.ConfigureCharacterInstance,
	AwaitCharacterRoot = PhysicsInputGateway.AwaitCharacterRoot,
	SampleKeyboardInput = PhysicsInputGateway.SampleKeyboardInput,
	FlushPlayerIntent = PhysicsInputGateway.FlushPlayerIntent,
}

-- Functions --

-- ============================================================================
-- 1. DYNAMIC MASS ALLOCATION, LAUNCH DIRECTION & RIGID BODY SUBSTEPPING
-- ============================================================================

--[=[
	Calculates and writes dynamic entity mass and inverse mass into storage buffers.
]=]
function PhysicsControllerHelper.EnsureDynamicEntityMass(
	EntityId: number,
	ObjectInvMassBuffer: buffer,
	SizeBuffer: buffer?,
	PropertiesBuffer: buffer?,
	CustomMass: number?
): number
	if EntityId ~= EntityId or EntityId < 1 or EntityId % 1 ~= 0 or EntityId * 4 > buffer.len(ObjectInvMassBuffer) then
		return 0
	end
	const MassOffset = (EntityId - 1) * 4 :: number
	const ExistingInvMass = buffer.readf32(ObjectInvMassBuffer, MassOffset) :: number
	if ExistingInvMass > 0 and CustomMass == nil then
		return ExistingInvMass
	end

	local ResolvedMass = CustomMass :: number?
	if not ResolvedMass or ResolvedMass ~= ResolvedMass or ResolvedMass <= 1e-4 or ResolvedMass == math.huge then
		if SizeBuffer and EntityId * COMPONENT_STRIDE <= buffer.len(SizeBuffer) then
			const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
			const SizeX = math.max(0.1, buffer.readf32(SizeBuffer, CompOffset)) :: number
			const SizeY = math.max(0.1, buffer.readf32(SizeBuffer, CompOffset + 4)) :: number
			const SizeZ = math.max(0.1, buffer.readf32(SizeBuffer, CompOffset + 8)) :: number
			ResolvedMass = SizeX * SizeY * SizeZ * OBJECT_DEFAULT_DENSITY
		else
			ResolvedMass = OBJECT_DEFAULT_DENSITY
		end
	end

	const InverseMass = math.clamp(1 / (ResolvedMass :: number), 1e-6, 1e4) :: number
	buffer.writef32(ObjectInvMassBuffer, MassOffset, InverseMass)
	if PropertiesBuffer and MassOffset + 4 <= buffer.len(PropertiesBuffer) then
		const PropReg = buffer.readu32(PropertiesBuffer, MassOffset) :: number
		buffer.writeu32(PropertiesBuffer, MassOffset, bit32.bor(bit32.band(PropReg, bit32.bnot(FLAG_ANCHORED)), FLAG_CAN_COLLIDE, FLAG_IS_VISIBLE))
	end
	return InverseMass
end

--[=[
	Resolves a unit launch direction vector from a Vector3 direction, yaw angle in degrees, or default.
]=]
function PhysicsControllerHelper.ResolveLaunchDirection(Angle: (Vector3 | number)?): (number, number, number)
	if typeof(Angle) == "Vector3" then
		const Len = Angle.Magnitude :: number
		if Len <= 1e-6 then
			return 0, 0, 0
		end
		const InvLen = 1 / Len :: number
		return Angle.X * InvLen, Angle.Y * InvLen, Angle.Z * InvLen
	elseif type(Angle) == "number" then
		const Rad = math.rad(Angle) :: number
		const RawX = math.cos(Rad) :: number
		const RawY = DEFAULT_LAUNCH_ANGLE.Y :: number
		const RawZ = math.sin(Rad) :: number
		const InvLen = 1 / math.sqrt(RawX * RawX + RawY * RawY + RawZ * RawZ) :: number
		return RawX * InvLen, RawY * InvLen, RawZ * InvLen
	end
	return DEFAULT_LAUNCH_ANGLE.X, DEFAULT_LAUNCH_ANGLE.Y, DEFAULT_LAUNCH_ANGLE.Z
end

--[=[
	Simulates a single substepped physics frame for an active dynamic ECS object.
]=]
function PhysicsControllerHelper.StepSingleDynamicObject(
	EntityId: number,
	EntityCount: number,
	StepDeltaTime: number,
	PositionBuffer: buffer,
	SizeBuffer: buffer,
	DirectionsBuffer: buffer,
	OrientationBuffer: buffer?,
	DynamicFlags: buffer,
	ObjectGroundedFlags: buffer,
	ObjectVelocityBuffer: buffer,
	ObjectAngularVelocityBuffer: buffer,
	ObjectForceBuffer: buffer,
	ObjectInvMassBuffer: buffer
)
	const FlagIndex = EntityId - 1 :: number
	const CompOffset = FlagIndex * COMPONENT_STRIDE :: number
	const InverseMass = buffer.readf32(ObjectInvMassBuffer, FlagIndex * 4) :: number
	if InverseMass <= 0 then
		buffer.writeu8(DynamicFlags, FlagIndex, 0)
		return
	end

	const WasGrounded = (buffer.readu8(ObjectGroundedFlags, FlagIndex) == 1) :: boolean
	const ForceX = buffer.readf32(ObjectForceBuffer, CompOffset) :: number
	const ForceY = buffer.readf32(ObjectForceBuffer, CompOffset + 4) :: number
	const ForceZ = buffer.readf32(ObjectForceBuffer, CompOffset + 8) :: number

	local VelocityX: number, VelocityY: number, VelocityZ: number = PhysicsMath.StepObjectVelocity(
		buffer.readf32(ObjectVelocityBuffer, CompOffset),
		buffer.readf32(ObjectVelocityBuffer, CompOffset + 4),
		buffer.readf32(ObjectVelocityBuffer, CompOffset + 8),
		ForceX, ForceY, ForceZ, InverseMass, WasGrounded, StepDeltaTime
	)

	const PreVelX: number, PreVelY: number, PreVelZ: number = VelocityX, VelocityY, VelocityZ
	local PosX = buffer.readf32(PositionBuffer, CompOffset) + VelocityX * StepDeltaTime :: number
	local PosY = buffer.readf32(PositionBuffer, CompOffset + 4) + VelocityY * StepDeltaTime :: number
	local PosZ = buffer.readf32(PositionBuffer, CompOffset + 8) + VelocityZ * StepDeltaTime :: number
	const HalfSizeX = buffer.readf32(SizeBuffer, CompOffset) * 0.5 :: number
	const HalfSizeY = buffer.readf32(SizeBuffer, CompOffset + 4) * 0.5 :: number
	const HalfSizeZ = buffer.readf32(SizeBuffer, CompOffset + 8) * 0.5 :: number

	local Grounded: boolean
	PosX, PosY, PosZ, VelocityX, VelocityY, VelocityZ, Grounded = PhysicsMath.ResolveBodyWorldCollisions(
		PosX, PosY, PosZ, HalfSizeX, HalfSizeY, HalfSizeZ,
		VelocityX, VelocityY, VelocityZ, InverseMass, OBJECT_RESTITUTION,
		EntityId, EntityCount, PositionBuffer, SizeBuffer, DirectionsBuffer,
		DynamicFlags, ObjectVelocityBuffer, ObjectInvMassBuffer, true
	)

	buffer.writef32(PositionBuffer, CompOffset, PosX)
	buffer.writef32(PositionBuffer, CompOffset + 4, PosY)
	buffer.writef32(PositionBuffer, CompOffset + 8, PosZ)
	buffer.writeu8(ObjectGroundedFlags, FlagIndex, if Grounded then 1 else 0)

	const AngSpeedSquared = PhysicsMathHelper.StepObjectRotation(
		EntityId, HalfSizeX, HalfSizeY, HalfSizeZ, PreVelX, PreVelY, PreVelZ,
		VelocityX, VelocityY, VelocityZ, Grounded, StepDeltaTime,
		DirectionsBuffer, OrientationBuffer, ObjectAngularVelocityBuffer
	) :: number

	const SpeedSquared = VelocityX * VelocityX + VelocityY * VelocityY + VelocityZ * VelocityZ :: number
	const HasAppliedForce = (ForceX ~= 0 or ForceY ~= 0 or ForceZ ~= 0) :: boolean
	if Grounded and not HasAppliedForce and SpeedSquared < SLEEP_SPEED_SQ and AngSpeedSquared < SLEEP_SPEED_SQ then
		buffer.fill(ObjectVelocityBuffer, CompOffset, 0, COMPONENT_STRIDE)
		buffer.fill(ObjectAngularVelocityBuffer, CompOffset, 0, COMPONENT_STRIDE)
		buffer.writeu8(DynamicFlags, FlagIndex, 2)
		return
	end

	buffer.writef32(ObjectVelocityBuffer, CompOffset, VelocityX)
	buffer.writef32(ObjectVelocityBuffer, CompOffset + 4, VelocityY)
	buffer.writef32(ObjectVelocityBuffer, CompOffset + 8, VelocityZ)
end

function PhysicsControllerHelper.ClearAccumulatedForces(ActiveForceCount: number, ActiveForceSlots: buffer, ObjectForceBuffer: buffer): number
	for i = 0, ActiveForceCount - 1 do
		buffer.fill(ObjectForceBuffer, buffer.readu32(ActiveForceSlots, i * 4), 0, COMPONENT_STRIDE)
	end
	return 0
end

return PhysicsControllerHelper
