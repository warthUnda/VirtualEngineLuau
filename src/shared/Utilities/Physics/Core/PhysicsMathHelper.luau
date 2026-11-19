--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const PhysicsRotationMath = require(script.Parent.PhysicsRotationMath)

-- Configs --
const OBJECT_RESTITUTION = SystemsConfigs.ObjectRestitution :: number
const NEG_ONE_PLUS_RESTITUTION = -(1 + OBJECT_RESTITUTION) :: number
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DENORMAL_EPSILON = 1e-12 :: number

-- Tables --
local PhysicsMathHelper = {
	RotateVectorByAxisAngle = PhysicsRotationMath.RotateVectorByAxisAngle,
	StepObjectRotation = PhysicsRotationMath.StepObjectRotation,
}

-- Functions --

-- ============================================================================
-- 1. DYNAMIC PAIR CONTACT IMPULSE RESOLUTION & ROTATION FACADE
-- ============================================================================

--[=[
	Resolves penetration and dynamic impulse transfer between two intersecting moving bodies.
]=]
function PhysicsMathHelper.ResolveDynamicPairContact(
	BodyX: number, BodyY: number, BodyZ: number,
	VelocityX: number, VelocityY: number, VelocityZ: number,
	BodyInverseMass: number,
	OtherEntityIndex: number,
	NormalX: number, NormalY: number, NormalZ: number,
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
		return BodyX + NormalX * Penetration, BodyY + NormalY * Penetration, BodyZ + NormalZ * Penetration,
			VelocityX, VelocityY, VelocityZ
	end

	buffer.writeu8(DynamicFlags, FlagIndex, 1)

	const InvTotalMass = 1 / TotalInverseMass :: number
	const BodyPenetration = Penetration * BodyInverseMass * InvTotalMass :: number
	const OtherPenetration = Penetration * OtherInverseMass * InvTotalMass :: number
	const NextBodyX = BodyX + NormalX * BodyPenetration :: number
	const NextBodyY = BodyY + NormalY * BodyPenetration :: number
	const NextBodyZ = BodyZ + NormalZ * BodyPenetration :: number

	const NextOtherPosX = buffer.readf32(PositionBuffer, OtherCompOffset) - NormalX * OtherPenetration :: number
	const NextOtherPosY = buffer.readf32(PositionBuffer, OtherCompOffset + 4) - NormalY * OtherPenetration :: number
	const NextOtherPosZ = buffer.readf32(PositionBuffer, OtherCompOffset + 8) - NormalZ * OtherPenetration :: number
	buffer.writef32(PositionBuffer, OtherCompOffset, NextOtherPosX)
	buffer.writef32(PositionBuffer, OtherCompOffset + 4, NextOtherPosY)
	buffer.writef32(PositionBuffer, OtherCompOffset + 8, NextOtherPosZ)

	const OtherVelocityX = buffer.readf32(ObjectVelocityBuffer, OtherCompOffset) :: number
	const OtherVelocityY = buffer.readf32(ObjectVelocityBuffer, OtherCompOffset + 4) :: number
	const OtherVelocityZ = buffer.readf32(ObjectVelocityBuffer, OtherCompOffset + 8) :: number

	const RelativeNormalVelocity = (VelocityX - OtherVelocityX) * NormalX
		+ (VelocityY - OtherVelocityY) * NormalY
		+ (VelocityZ - OtherVelocityZ) * NormalZ :: number
	if RelativeNormalVelocity >= 0 then
		return NextBodyX, NextBodyY, NextBodyZ, VelocityX, VelocityY, VelocityZ
	end

	const ImpulseScalar = NEG_ONE_PLUS_RESTITUTION * RelativeNormalVelocity * InvTotalMass :: number
	const BodyImpulse = ImpulseScalar * BodyInverseMass :: number
	const OtherImpulse = ImpulseScalar * OtherInverseMass :: number

	const NextOtherVelX = OtherVelocityX - NormalX * OtherImpulse :: number
	const NextOtherVelY = OtherVelocityY - NormalY * OtherImpulse :: number
	const NextOtherVelZ = OtherVelocityZ - NormalZ * OtherImpulse :: number
	buffer.writef32(ObjectVelocityBuffer, OtherCompOffset, if math.abs(NextOtherVelX) < DENORMAL_EPSILON then 0 else NextOtherVelX)
	buffer.writef32(ObjectVelocityBuffer, OtherCompOffset + 4, if math.abs(NextOtherVelY) < DENORMAL_EPSILON then 0 else NextOtherVelY)
	buffer.writef32(ObjectVelocityBuffer, OtherCompOffset + 8, if math.abs(NextOtherVelZ) < DENORMAL_EPSILON then 0 else NextOtherVelZ)

	const NextVelX = VelocityX + NormalX * BodyImpulse :: number
	const NextVelY = VelocityY + NormalY * BodyImpulse :: number
	const NextVelZ = VelocityZ + NormalZ * BodyImpulse :: number
	return NextBodyX, NextBodyY, NextBodyZ,
		if math.abs(NextVelX) < DENORMAL_EPSILON then 0 else NextVelX,
		if math.abs(NextVelY) < DENORMAL_EPSILON then 0 else NextVelY,
		if math.abs(NextVelZ) < DENORMAL_EPSILON then 0 else NextVelZ
end

return PhysicsMathHelper
