--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const OBJECT_ANGULAR_DRAG = SystemsConfigs.ObjectAngularDrag :: number
const OBJECT_ROLL_COUPLING = SystemsConfigs.ObjectRollCoupling :: number
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number

-- Tables --
local PhysicsRotationMath = {}

-- Functions --

-- ============================================================================
-- 1. RODRIGUES AXIS-ANGLE ROTATION & ANGULAR VELOCITY INTEGRATION
-- ============================================================================

--[=[
	Rotates a 3D basis vector around a unit axis using Rodrigues' rotation formula.
]=]
function PhysicsRotationMath.RotateVectorByAxisAngle(
	VecX: number, VecY: number, VecZ: number,
	AxisX: number, AxisY: number, AxisZ: number,
	CosAngle: number, SinAngle: number
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
]=]
function PhysicsRotationMath.StepObjectRotation(
	EntityId: number,
	HalfSizeX: number, HalfSizeY: number, HalfSizeZ: number,
	PreVelocityX: number, PreVelocityY: number, PreVelocityZ: number,
	VelocityX: number, VelocityY: number, VelocityZ: number,
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

		const Blend = math.min(1, OBJECT_ROLL_COUPLING * StepDeltaTime) :: number
		AngVelX += ((NormY * TanZ - NormZ * TanY) / Radius - AngVelX) * Blend
		AngVelY += ((NormZ * TanX - NormX * TanZ) / Radius - AngVelY) * Blend
		AngVelZ += ((NormX * TanY - NormY * TanX) / Radius - AngVelZ) * Blend
	elseif Grounded then
		const Blend = math.min(1, OBJECT_ROLL_COUPLING * StepDeltaTime) :: number
		AngVelX += (VelocityZ / Radius - AngVelX) * Blend
		AngVelY *= math.max(0, 1 - OBJECT_ANGULAR_DRAG * 2 * StepDeltaTime)
		AngVelZ += (-VelocityX / Radius - AngVelZ) * Blend
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

	LookX, LookY, LookZ = PhysicsRotationMath.RotateVectorByAxisAngle(LookX, LookY, LookZ, AxisX, AxisY, AxisZ, CosAngle, SinAngle)
	UpX, UpY, UpZ = PhysicsRotationMath.RotateVectorByAxisAngle(UpX, UpY, UpZ, AxisX, AxisY, AxisZ, CosAngle, SinAngle)

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

return PhysicsRotationMath
