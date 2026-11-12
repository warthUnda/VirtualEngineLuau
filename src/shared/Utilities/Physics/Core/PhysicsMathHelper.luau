--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const PLAYER_MASS = SystemsConfigs.PlayerMass :: number
const PLAYER_INV_MASS = 1 / PLAYER_MASS :: number
const PLAYER_MOVE_FORCE = SystemsConfigs.PlayerMoveForce :: number
const PLAYER_MAX_GROUND_SPEED = SystemsConfigs.PlayerMaxGroundSpeed :: number
const PLAYER_GROUND_FRICTION = SystemsConfigs.PlayerGroundFriction :: number
const PLAYER_BRAKE_MULTIPLIER = SystemsConfigs.PlayerBrakeMultiplier :: number
const PLAYER_STOP_SPEED = SystemsConfigs.PlayerStopSpeed :: number
const PLAYER_AIR_CONTROL = SystemsConfigs.PlayerAirControlMultiplier :: number
const PLAYER_AIR_DRAG = SystemsConfigs.PlayerAirDrag :: number
const OBJECT_RESTITUTION = SystemsConfigs.ObjectRestitution :: number
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number

local PhysicsMathHelper = {}

-- ============================================================================
-- 1. FRICTION, DRIVE INTEGRATION & PAIR CONTACT RESOLUTION HELPERS
-- ============================================================================

--[=[
	Applies ground stopping friction to bring horizontal velocity smoothly to rest.
	@param VelocityX number -- Current horizontal velocity X.
	@param VelocityZ number -- Current horizontal velocity Z.
	@param FrictionRate number -- Rate of ground friction decay.
	@param DeltaTime number -- Elapsed frame time in seconds.
	@return (number, number) -- Decelerated (VelocityX, VelocityZ).
]=]
function PhysicsMathHelper.ApplyStopFriction(
	VelocityX: number,
	VelocityZ: number,
	FrictionRate: number,
	DeltaTime: number
): (number, number)
	const HorizontalSpeed = math.sqrt(VelocityX * VelocityX + VelocityZ * VelocityZ) :: number
	if HorizontalSpeed <= 1e-5 then
		return 0, 0
	end

	const ControlSpeed = math.max(HorizontalSpeed, PLAYER_STOP_SPEED) :: number
	const SpeedDrop = ControlSpeed * FrictionRate * DeltaTime :: number
	const RetainedScale = math.max(0, HorizontalSpeed - SpeedDrop) / HorizontalSpeed :: number
	return VelocityX * RetainedScale, VelocityZ * RetainedScale
end

--[=[
	Integrates player horizontal ground acceleration and directional braking against wish intent.
	@param VelocityX number -- Current horizontal velocity X.
	@param VelocityZ number -- Current horizontal velocity Z.
	@param WishX number -- Desired unit wish direction X.
	@param WishZ number -- Desired unit wish direction Z.
	@param WishScale number -- Wish speed multiplier.
	@param DeltaTime number -- Elapsed frame time in seconds.
	@return (number, number) -- Next (VelocityX, VelocityZ).
]=]
function PhysicsMathHelper.IntegrateGroundedDrive(
	VelocityX: number,
	VelocityZ: number,
	WishX: number,
	WishZ: number,
	WishScale: number,
	DeltaTime: number
): (number, number)
	if WishScale <= 1e-4 then
		return PhysicsMathHelper.ApplyStopFriction(
			VelocityX,
			VelocityZ,
			PLAYER_GROUND_FRICTION * PLAYER_BRAKE_MULTIPLIER,
			DeltaTime
		)
	end

	local ParallelSpeed = VelocityX * WishX + VelocityZ * WishZ :: number
	const LateralDecay = math.max(0, 1 - PLAYER_GROUND_FRICTION * DeltaTime) :: number
	const LateralVelocityX = (VelocityX - ParallelSpeed * WishX) * LateralDecay :: number
	const LateralVelocityZ = (VelocityZ - ParallelSpeed * WishZ) * LateralDecay :: number

	const TargetSpeed = PLAYER_MAX_GROUND_SPEED * WishScale :: number
	const DriveStep = (PLAYER_MOVE_FORCE * PLAYER_INV_MASS) * WishScale * DeltaTime :: number

	if ParallelSpeed < 0 then
		const BrakeDecay = math.max(0, 1 - PLAYER_GROUND_FRICTION * PLAYER_BRAKE_MULTIPLIER * DeltaTime) :: number
		ParallelSpeed = math.min(TargetSpeed, ParallelSpeed * BrakeDecay + DriveStep)
	elseif ParallelSpeed < TargetSpeed then
		ParallelSpeed = math.min(TargetSpeed, ParallelSpeed + DriveStep)
	else
		ParallelSpeed = math.max(TargetSpeed, ParallelSpeed - ParallelSpeed * PLAYER_GROUND_FRICTION * DeltaTime)
	end

	return LateralVelocityX + WishX * ParallelSpeed, LateralVelocityZ + WishZ * ParallelSpeed
end

--[=[
	Integrates player airborne velocity, applying air resistance and responsive air-control steering.
	@param VelocityX number -- Current horizontal velocity X.
	@param VelocityZ number -- Current horizontal velocity Z.
	@param WishX number -- Desired unit wish direction X.
	@param WishZ number -- Desired unit wish direction Z.
	@param WishScale number -- Wish speed multiplier.
	@param DeltaTime number -- Elapsed frame time in seconds.
	@return (number, number) -- Next (VelocityX, VelocityZ).
]=]
function PhysicsMathHelper.IntegrateAirborneDrive(
	VelocityX: number,
	VelocityZ: number,
	WishX: number,
	WishZ: number,
	WishScale: number,
	DeltaTime: number
): (number, number)
	const AirDecay = math.max(0, 1 - PLAYER_AIR_DRAG * DeltaTime) :: number
	local NextVelocityX = VelocityX * AirDecay :: number
	local NextVelocityZ = VelocityZ * AirDecay :: number

	if WishScale <= 1e-4 then
		return NextVelocityX, NextVelocityZ
	end

	const ProjectedSpeed = NextVelocityX * WishX + NextVelocityZ * WishZ :: number
	const TargetSpeed = PLAYER_MAX_GROUND_SPEED * WishScale :: number
	const MaxAirStep = (PLAYER_MOVE_FORCE * PLAYER_INV_MASS * PLAYER_AIR_CONTROL) * WishScale * DeltaTime :: number
	const AirAddedSpeed = math.clamp(TargetSpeed - ProjectedSpeed, 0, MaxAirStep) :: number

	return NextVelocityX + WishX * AirAddedSpeed, NextVelocityZ + WishZ * AirAddedSpeed
end

--[=[
	Resolves penetration and dynamic impulse transfer between two intersecting moving bodies.
	@param BodyX number -- Primary body center position X.
	@param BodyY number -- Primary body center position Y.
	@param BodyZ number -- Primary body center position Z.
	@param VelocityX number -- Primary body velocity X.
	@param VelocityY number -- Primary body velocity Y.
	@param VelocityZ number -- Primary body velocity Z.
	@param BodyInverseMass number -- 1 / mass of primary body.
	@param OtherEntityIndex number -- Target colliding entity index.
	@param NormalX number -- Contact surface normal X.
	@param NormalY number -- Contact surface normal Y.
	@param NormalZ number -- Contact surface normal Z.
	@param Penetration number -- Overlap depth along contact normal.
	@param PositionBuffer buffer -- ECS positions buffer.
	@param DynamicFlags buffer -- ECS dynamic state buffer.
	@param ObjectVelocityBuffer buffer -- Dynamic objects velocity buffer.
	@param ObjectInvMassBuffer buffer -- Dynamic objects inverse mass buffer.
	@return (number, number, number, number, number, number) -- NextBodyX, NextBodyY, NextBodyZ, NextVelX, NextVelY, NextVelZ.
]=]
function PhysicsMathHelper.ResolveDynamicPairContact(
	BodyX: number,
	BodyY: number,
	BodyZ: number,
	VelocityX: number,
	VelocityY: number,
	VelocityZ: number,
	BodyInverseMass: number,
	OtherEntityIndex: number,
	NormalX: number,
	NormalY: number,
	NormalZ: number,
	Penetration: number,
	PositionBuffer: buffer,
	DynamicFlags: buffer,
	ObjectVelocityBuffer: buffer,
	ObjectInvMassBuffer: buffer
): (number, number, number, number, number, number)
	const FlagIndex = OtherEntityIndex - 1 :: number
	const OtherCompOffset = FlagIndex * COMPONENT_STRIDE :: number
	const OtherInverseMass = buffer.readf32(ObjectInvMassBuffer, FlagIndex * 4) :: number
	const TotalInverseMass = BodyInverseMass + OtherInverseMass :: number

	if TotalInverseMass <= 1e-6 then
		return BodyX + NormalX * Penetration,
			BodyY + NormalY * Penetration,
			BodyZ + NormalZ * Penetration,
			VelocityX,
			VelocityY,
			VelocityZ
	end

	buffer.writeu8(DynamicFlags, FlagIndex, 1)

	const BodyShare = BodyInverseMass / TotalInverseMass :: number
	const OtherShare = OtherInverseMass / TotalInverseMass :: number

	const NextBodyX = BodyX + NormalX * (Penetration * BodyShare) :: number
	const NextBodyY = BodyY + NormalY * (Penetration * BodyShare) :: number
	const NextBodyZ = BodyZ + NormalZ * (Penetration * BodyShare) :: number

	buffer.writef32(
		PositionBuffer,
		OtherCompOffset,
		buffer.readf32(PositionBuffer, OtherCompOffset) - NormalX * (Penetration * OtherShare)
	)
	buffer.writef32(
		PositionBuffer,
		OtherCompOffset + 4,
		buffer.readf32(PositionBuffer, OtherCompOffset + 4) - NormalY * (Penetration * OtherShare)
	)
	buffer.writef32(
		PositionBuffer,
		OtherCompOffset + 8,
		buffer.readf32(PositionBuffer, OtherCompOffset + 8) - NormalZ * (Penetration * OtherShare)
	)

	const OtherVelocityX = buffer.readf32(ObjectVelocityBuffer, OtherCompOffset) :: number
	const OtherVelocityY = buffer.readf32(ObjectVelocityBuffer, OtherCompOffset + 4) :: number
	const OtherVelocityZ = buffer.readf32(ObjectVelocityBuffer, OtherCompOffset + 8) :: number

	const RelativeNormalVelocity = (VelocityX - OtherVelocityX) * NormalX
		+ (VelocityY - OtherVelocityY) * NormalY
		+ (VelocityZ - OtherVelocityZ) * NormalZ :: number
	if RelativeNormalVelocity >= 0 then
		return NextBodyX, NextBodyY, NextBodyZ, VelocityX, VelocityY, VelocityZ
	end

	const ImpulseScalar = -(1 + OBJECT_RESTITUTION) * RelativeNormalVelocity / TotalInverseMass :: number
	const BodyImpulse = ImpulseScalar * BodyInverseMass :: number
	const OtherImpulse = ImpulseScalar * OtherInverseMass :: number

	buffer.writef32(ObjectVelocityBuffer, OtherCompOffset, OtherVelocityX - NormalX * OtherImpulse)
	buffer.writef32(ObjectVelocityBuffer, OtherCompOffset + 4, OtherVelocityY - NormalY * OtherImpulse)
	buffer.writef32(ObjectVelocityBuffer, OtherCompOffset + 8, OtherVelocityZ - NormalZ * OtherImpulse)

	return NextBodyX,
		NextBodyY,
		NextBodyZ,
		VelocityX + NormalX * BodyImpulse,
		VelocityY + NormalY * BodyImpulse,
		VelocityZ + NormalZ * BodyImpulse
end

return PhysicsMathHelper
