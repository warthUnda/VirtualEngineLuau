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
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number

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

	const BodyShare = BodyInverseMass / TotalInverseMass :: number
	const OtherShare = OtherInverseMass / TotalInverseMass :: number
	const NextBodyX = BodyX + NormalX * (Penetration * BodyShare) :: number
	const NextBodyY = BodyY + NormalY * (Penetration * BodyShare) :: number
	const NextBodyZ = BodyZ + NormalZ * (Penetration * BodyShare) :: number

	buffer.writef32(PositionBuffer, OtherCompOffset, buffer.readf32(PositionBuffer, OtherCompOffset) - NormalX * (Penetration * OtherShare))
	buffer.writef32(PositionBuffer, OtherCompOffset + 4, buffer.readf32(PositionBuffer, OtherCompOffset + 4) - NormalY * (Penetration * OtherShare))
	buffer.writef32(PositionBuffer, OtherCompOffset + 8, buffer.readf32(PositionBuffer, OtherCompOffset + 8) - NormalZ * (Penetration * OtherShare))

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

	return NextBodyX, NextBodyY, NextBodyZ,
		VelocityX + NormalX * BodyImpulse,
		VelocityY + NormalY * BodyImpulse,
		VelocityZ + NormalZ * BodyImpulse
end

return PhysicsMathHelper
