--!strict
--!native
--!optimize 2

-- Tables --
local PhysicsSATMath = {}

-- Functions --

-- ============================================================================
-- 1. SEPARATING AXIS THEOREM (SAT) NARROWPHASE (AABB BODY VS ECS OBB)
-- ============================================================================

--[=[
	Performs a Separating Axis Theorem (SAT) collision test between an axis-aligned box body and an oriented ECS box.
	@return (boolean, number, number, number, number) -- Overlaps, NormalX, NormalY, NormalZ, Penetration.
]=]
function PhysicsSATMath.TestBoxVsOBB(
	BodyX: number,
	BodyY: number,
	BodyZ: number,
	BodyHalfSizeX: number,
	BodyHalfSizeY: number,
	BodyHalfSizeZ: number,
	CompOffset: number,
	DirOffset: number,
	PositionBuffer: buffer,
	SizeBuffer: buffer,
	DirectionsBuffer: buffer
): (boolean, number, number, number, number)
	const SizeX = buffer.readf32(SizeBuffer, CompOffset) :: number
	const SizeY = buffer.readf32(SizeBuffer, CompOffset + 4) :: number
	const SizeZ = buffer.readf32(SizeBuffer, CompOffset + 8) :: number
	if SizeX <= 0 or SizeY <= 0 or SizeZ <= 0 then
		return false, 0, 0, 0, 0
	end

	const DeltaX = BodyX - buffer.readf32(PositionBuffer, CompOffset) :: number
	const DeltaY = BodyY - buffer.readf32(PositionBuffer, CompOffset + 4) :: number
	const DeltaZ = BodyZ - buffer.readf32(PositionBuffer, CompOffset + 8) :: number

	const BroadphaseRadius = (SizeX + SizeY + SizeZ) * 0.5 :: number
	if
		math.abs(DeltaX) > BodyHalfSizeX + BroadphaseRadius
		or math.abs(DeltaY) > BodyHalfSizeY + BroadphaseRadius
		or math.abs(DeltaZ) > BodyHalfSizeZ + BroadphaseRadius
	then
		return false, 0, 0, 0, 0
	end

	local LookX = buffer.readf32(DirectionsBuffer, DirOffset) :: number
	local LookY = buffer.readf32(DirectionsBuffer, DirOffset + 4) :: number
	local LookZ = buffer.readf32(DirectionsBuffer, DirOffset + 8) :: number
	local UpX = buffer.readf32(DirectionsBuffer, DirOffset + 12) :: number
	local UpY = buffer.readf32(DirectionsBuffer, DirOffset + 16) :: number
	local UpZ = buffer.readf32(DirectionsBuffer, DirOffset + 20) :: number
	local RightX = buffer.readf32(DirectionsBuffer, DirOffset + 24) :: number
	local RightY = buffer.readf32(DirectionsBuffer, DirOffset + 28) :: number
	local RightZ = buffer.readf32(DirectionsBuffer, DirOffset + 32) :: number

	if RightX * RightX + RightY * RightY + RightZ * RightZ < 0.5 then
		LookX, LookY, LookZ = 0, 0, -1
		UpX, UpY, UpZ = 0, 1, 0
		RightX, RightY, RightZ = 1, 0, 0
	end

	const HalfSizeX: number, HalfSizeY: number, HalfSizeZ: number = SizeX * 0.5, SizeY * 0.5, SizeZ * 0.5
	const OverlapX = (BodyHalfSizeX + math.abs(RightX) * HalfSizeX + math.abs(UpX) * HalfSizeY + math.abs(LookX) * HalfSizeZ) - math.abs(DeltaX) :: number
	if OverlapX <= 0 then
		return false, 0, 0, 0, 0
	end
	const OverlapY = (BodyHalfSizeY + math.abs(RightY) * HalfSizeX + math.abs(UpY) * HalfSizeY + math.abs(LookY) * HalfSizeZ) - math.abs(DeltaY) :: number
	if OverlapY <= 0 then
		return false, 0, 0, 0, 0
	end
	const OverlapZ = (BodyHalfSizeZ + math.abs(RightZ) * HalfSizeX + math.abs(UpZ) * HalfSizeY + math.abs(LookZ) * HalfSizeZ) - math.abs(DeltaZ) :: number
	if OverlapZ <= 0 then
		return false, 0, 0, 0, 0
	end

	local MinOverlap = OverlapY :: number
	local BestNormalX = 0 :: number
	local BestNormalY = if DeltaY >= 0 then 1 else -1 :: number
	local BestNormalZ = 0 :: number

	if OverlapX < MinOverlap then
		MinOverlap = OverlapX
		BestNormalX = if DeltaX >= 0 then 1 else -1
		BestNormalY = 0
		BestNormalZ = 0
	end
	if OverlapZ < MinOverlap then
		MinOverlap = OverlapZ
		BestNormalX = 0
		BestNormalY = 0
		BestNormalZ = if DeltaZ >= 0 then 1 else -1
	end

	const UpAxisDistance = DeltaX * UpX + DeltaY * UpY + DeltaZ * UpZ :: number
	const OverlapUp = (math.abs(UpX) * BodyHalfSizeX + math.abs(UpY) * BodyHalfSizeY + math.abs(UpZ) * BodyHalfSizeZ + HalfSizeY) - math.abs(UpAxisDistance) :: number
	if OverlapUp <= 0 then
		return false, 0, 0, 0, 0
	end
	if OverlapUp < MinOverlap then
		const UpAxisSign = if UpAxisDistance >= 0 then 1 else -1 :: number
		MinOverlap = OverlapUp
		BestNormalX, BestNormalY, BestNormalZ = UpX * UpAxisSign, UpY * UpAxisSign, UpZ * UpAxisSign
	end

	const RightAxisDistance = DeltaX * RightX + DeltaY * RightY + DeltaZ * RightZ :: number
	const OverlapRight = (math.abs(RightX) * BodyHalfSizeX + math.abs(RightY) * BodyHalfSizeY + math.abs(RightZ) * BodyHalfSizeZ + HalfSizeX) - math.abs(RightAxisDistance) :: number
	if OverlapRight <= 0 then
		return false, 0, 0, 0, 0
	end
	if OverlapRight < MinOverlap then
		const RightAxisSign = if RightAxisDistance >= 0 then 1 else -1 :: number
		MinOverlap = OverlapRight
		BestNormalX, BestNormalY, BestNormalZ = RightX * RightAxisSign, RightY * RightAxisSign, RightZ * RightAxisSign
	end

	const LookAxisDistance = DeltaX * LookX + DeltaY * LookY + DeltaZ * LookZ :: number
	const OverlapLook = (math.abs(LookX) * BodyHalfSizeX + math.abs(LookY) * BodyHalfSizeY + math.abs(LookZ) * BodyHalfSizeZ + HalfSizeZ) - math.abs(LookAxisDistance) :: number
	if OverlapLook <= 0 then
		return false, 0, 0, 0, 0
	end
	if OverlapLook < MinOverlap then
		const LookAxisSign = if LookAxisDistance >= 0 then 1 else -1 :: number
		MinOverlap = OverlapLook
		BestNormalX, BestNormalY, BestNormalZ = LookX * LookAxisSign, LookY * LookAxisSign, LookZ * LookAxisSign
	end

	return true, BestNormalX, BestNormalY, BestNormalZ, MinOverlap
end

return PhysicsSATMath
