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
const OBJECT_ANGULAR_DRAG = SystemsConfigs.ObjectAngularDrag :: number
const OBJECT_ROLL_COUPLING = SystemsConfigs.ObjectRollCoupling :: number
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number

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

--[=[
	Rotates a 3D basis vector around a unit axis using Rodrigues' rotation formula.
	@param VecX number -- Input vector X.
	@param VecY number -- Input vector Y.
	@param VecZ number -- Input vector Z.
	@param AxisX number -- Unit rotation axis X.
	@param AxisY number -- Unit rotation axis Y.
	@param AxisZ number -- Unit rotation axis Z.
	@param CosAngle number -- Cosine of rotation angle.
	@param SinAngle number -- Sine of rotation angle.
	@return (number, number, number) -- Rotated vector (X, Y, Z).
]=]
function PhysicsMathHelper.RotateVectorByAxisAngle(
	VecX: number,
	VecY: number,
	VecZ: number,
	AxisX: number,
	AxisY: number,
	AxisZ: number,
	CosAngle: number,
	SinAngle: number
): (number, number, number)
	const OneMinusCos = 1 - CosAngle :: number
	const AxisDotVec = AxisX * VecX + AxisY * VecY + AxisZ * VecZ :: number
	const CrossX = AxisY * VecZ - AxisZ * VecY :: number
	const CrossY = AxisZ * VecX - AxisX * VecZ :: number
	const CrossZ = AxisX * VecY - AxisY * VecX :: number

	return VecX * CosAngle + CrossX * SinAngle + AxisX * (AxisDotVec * OneMinusCos),
		VecY * CosAngle + CrossY * SinAngle + AxisY * (AxisDotVec * OneMinusCos),
		VecZ * CosAngle + CrossZ * SinAngle + AxisZ * (AxisDotVec * OneMinusCos)
end

--[=[
	Updates angular velocity from contact impulses/rolling and rotates the entity's orthonormal basis in DirectionsBuffer.
	@param EntityId number -- Target ECS entity ID.
	@param HalfSizeX number -- Half extent X of the entity.
	@param HalfSizeY number -- Half extent Y of the entity.
	@param HalfSizeZ number -- Half extent Z of the entity.
	@param PreVelocityX number -- Linear velocity X before collision resolution.
	@param PreVelocityY number -- Linear velocity Y before collision resolution.
	@param PreVelocityZ number -- Linear velocity Z before collision resolution.
	@param VelocityX number -- Linear velocity X after collision resolution.
	@param VelocityY number -- Linear velocity Y after collision resolution.
	@param VelocityZ number -- Linear velocity Z after collision resolution.
	@param Grounded boolean -- Whether the entity is currently resting on ground.
	@param StepDeltaTime number -- Substep delta time in seconds.
	@param DirectionsBuffer buffer -- ECS directions buffer storing Look, Up, and Right vectors.
	@param OrientationBuffer buffer? -- Optional ECS orientation buffer storing Look vector.
	@param ObjectAngularVelocityBuffer buffer -- Dynamic objects angular velocity buffer (rad/s).
	@return number -- Squared angular speed after stepping.
]=]
function PhysicsMathHelper.StepObjectRotation(
	EntityId: number,
	HalfSizeX: number,
	HalfSizeY: number,
	HalfSizeZ: number,
	PreVelocityX: number,
	PreVelocityY: number,
	PreVelocityZ: number,
	VelocityX: number,
	VelocityY: number,
	VelocityZ: number,
	Grounded: boolean,
	StepDeltaTime: number,
	DirectionsBuffer: buffer,
	OrientationBuffer: buffer?,
	ObjectAngularVelocityBuffer: buffer
): number
	const FlagIndex = EntityId - 1 :: number
	const CompOffset = FlagIndex * COMPONENT_STRIDE :: number
	const DirOffset = FlagIndex * DIRECTION_STRIDE :: number

	local AngVelX = buffer.readf32(ObjectAngularVelocityBuffer, CompOffset) :: number
	local AngVelY = buffer.readf32(ObjectAngularVelocityBuffer, CompOffset + 4) :: number
	local AngVelZ = buffer.readf32(ObjectAngularVelocityBuffer, CompOffset + 8) :: number

	const Radius = math.max(0.25, (HalfSizeX + HalfSizeY + HalfSizeZ) / 3) :: number
	const ImpulseX = VelocityX - PreVelocityX :: number
	const ImpulseY = VelocityY - PreVelocityY :: number
	const ImpulseZ = VelocityZ - PreVelocityZ :: number
	const ImpulseMagSq = ImpulseX * ImpulseX + ImpulseY * ImpulseY + ImpulseZ * ImpulseZ :: number

	if ImpulseMagSq > 1e-8 then
		const InvImpulseMag = 1 / math.sqrt(ImpulseMagSq) :: number
		const NormX = ImpulseX * InvImpulseMag :: number
		const NormY = ImpulseY * InvImpulseMag :: number
		const NormZ = ImpulseZ * InvImpulseMag :: number

		const VelDotNorm = VelocityX * NormX + VelocityY * NormY + VelocityZ * NormZ :: number
		const TanX = VelocityX - VelDotNorm * NormX :: number
		const TanY = VelocityY - VelDotNorm * NormY :: number
		const TanZ = VelocityZ - VelDotNorm * NormZ :: number

		const TargetX = (NormY * TanZ - NormZ * TanY) / Radius :: number
		const TargetY = (NormZ * TanX - NormX * TanZ) / Radius :: number
		const TargetZ = (NormX * TanY - NormY * TanX) / Radius :: number

		const Blend = math.min(1, OBJECT_ROLL_COUPLING * StepDeltaTime) :: number
		AngVelX += (TargetX - AngVelX) * Blend
		AngVelY += (TargetY - AngVelY) * Blend
		AngVelZ += (TargetZ - AngVelZ) * Blend
	elseif Grounded then
		const TargetX = VelocityZ / Radius :: number
		const TargetZ = -VelocityX / Radius :: number
		const Blend = math.min(1, OBJECT_ROLL_COUPLING * StepDeltaTime) :: number
		AngVelX += (TargetX - AngVelX) * Blend
		AngVelY *= math.max(0, 1 - OBJECT_ANGULAR_DRAG * 2 * StepDeltaTime)
		AngVelZ += (TargetZ - AngVelZ) * Blend
	else
		const AirDecay = math.max(0, 1 - OBJECT_ANGULAR_DRAG * StepDeltaTime) :: number
		AngVelX *= AirDecay
		AngVelY *= AirDecay
		AngVelZ *= AirDecay
	end

	buffer.writef32(ObjectAngularVelocityBuffer, CompOffset, AngVelX)
	buffer.writef32(ObjectAngularVelocityBuffer, CompOffset + 4, AngVelY)
	buffer.writef32(ObjectAngularVelocityBuffer, CompOffset + 8, AngVelZ)

	const AngSpeedSq = AngVelX * AngVelX + AngVelY * AngVelY + AngVelZ * AngVelZ :: number
	if AngSpeedSq <= 1e-8 then
		return AngSpeedSq
	end

	const AngSpeed = math.sqrt(AngSpeedSq) :: number
	const Angle = AngSpeed * StepDeltaTime :: number
	const InvAngSpeed = 1 / AngSpeed :: number
	const AxisX = AngVelX * InvAngSpeed :: number
	const AxisY = AngVelY * InvAngSpeed :: number
	const AxisZ = AngVelZ * InvAngSpeed :: number
	const CosAngle = math.cos(Angle) :: number
	const SinAngle = math.sin(Angle) :: number

	local LookX = buffer.readf32(DirectionsBuffer, DirOffset) :: number
	local LookY = buffer.readf32(DirectionsBuffer, DirOffset + 4) :: number
	local LookZ = buffer.readf32(DirectionsBuffer, DirOffset + 8) :: number
	local UpX = buffer.readf32(DirectionsBuffer, DirOffset + 12) :: number
	local UpY = buffer.readf32(DirectionsBuffer, DirOffset + 16) :: number
	local UpZ = buffer.readf32(DirectionsBuffer, DirOffset + 20) :: number

	if LookX * LookX + LookY * LookY + LookZ * LookZ < 0.5 or UpX * UpX + UpY * UpY + UpZ * UpZ < 0.5 then
		LookX, LookY, LookZ = 0, 0, -1
		UpX, UpY, UpZ = 0, 1, 0
	end

	LookX, LookY, LookZ =
		PhysicsMathHelper.RotateVectorByAxisAngle(LookX, LookY, LookZ, AxisX, AxisY, AxisZ, CosAngle, SinAngle)
	UpX, UpY, UpZ = PhysicsMathHelper.RotateVectorByAxisAngle(UpX, UpY, UpZ, AxisX, AxisY, AxisZ, CosAngle, SinAngle)

	const LookLenSq = LookX * LookX + LookY * LookY + LookZ * LookZ :: number
	const InvLookLen = if LookLenSq > 1e-8 then 1 / math.sqrt(LookLenSq) else 1 :: number
	LookX *= InvLookLen
	LookY *= InvLookLen
	LookZ *= InvLookLen

	local RightX = LookY * UpZ - LookZ * UpY :: number
	local RightY = LookZ * UpX - LookX * UpZ :: number
	local RightZ = LookX * UpY - LookY * UpX :: number
	const RightLenSq = RightX * RightX + RightY * RightY + RightZ * RightZ :: number
	if RightLenSq <= 1e-8 then
		return AngSpeedSq
	end

	const InvRightLen = 1 / math.sqrt(RightLenSq) :: number
	RightX *= InvRightLen
	RightY *= InvRightLen
	RightZ *= InvRightLen

	UpX = RightY * LookZ - RightZ * LookY
	UpY = RightZ * LookX - RightX * LookZ
	UpZ = RightX * LookY - RightY * LookX

	buffer.writef32(DirectionsBuffer, DirOffset, LookX)
	buffer.writef32(DirectionsBuffer, DirOffset + 4, LookY)
	buffer.writef32(DirectionsBuffer, DirOffset + 8, LookZ)
	buffer.writef32(DirectionsBuffer, DirOffset + 12, UpX)
	buffer.writef32(DirectionsBuffer, DirOffset + 16, UpY)
	buffer.writef32(DirectionsBuffer, DirOffset + 20, UpZ)
	buffer.writef32(DirectionsBuffer, DirOffset + 24, RightX)
	buffer.writef32(DirectionsBuffer, DirOffset + 28, RightY)
	buffer.writef32(DirectionsBuffer, DirOffset + 32, RightZ)

	if OrientationBuffer then
		buffer.writef32(OrientationBuffer, CompOffset, LookX)
		buffer.writef32(OrientationBuffer, CompOffset + 4, LookY)
		buffer.writef32(OrientationBuffer, CompOffset + 8, LookZ)
	end

	return AngSpeedSq
end

return PhysicsMathHelper
