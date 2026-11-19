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
	if math.min(SizeX, SizeY, SizeZ) <= 0 then
		return false, 0, 0, 0, 0
	end

	const HalfSizeX = SizeX * 0.5 :: number
	const HalfSizeY = SizeY * 0.5 :: number
	const HalfSizeZ = SizeZ * 0.5 :: number
	const DeltaX = BodyX - buffer.readf32(PositionBuffer, CompOffset) :: number
	const DeltaY = BodyY - buffer.readf32(PositionBuffer, CompOffset + 4) :: number
	const DeltaZ = BodyZ - buffer.readf32(PositionBuffer, CompOffset + 8) :: number
	const AbsDeltaX = math.abs(DeltaX) :: number
	const AbsDeltaY = math.abs(DeltaY) :: number
	const AbsDeltaZ = math.abs(DeltaZ) :: number

	const BroadphaseRadius = HalfSizeX + HalfSizeY + HalfSizeZ :: number
	if math.max(AbsDeltaX - BodyHalfSizeX, AbsDeltaY - BodyHalfSizeY, AbsDeltaZ - BodyHalfSizeZ) > BroadphaseRadius then
		return false, 0, 0, 0, 0
	end

	const LookX = buffer.readf32(DirectionsBuffer, DirOffset) :: number
	const LookY = buffer.readf32(DirectionsBuffer, DirOffset + 4) :: number
	const LookZ = buffer.readf32(DirectionsBuffer, DirOffset + 8) :: number
	const UpX = buffer.readf32(DirectionsBuffer, DirOffset + 12) :: number
	const UpY = buffer.readf32(DirectionsBuffer, DirOffset + 16) :: number
	const UpZ = buffer.readf32(DirectionsBuffer, DirOffset + 20) :: number
	const RightX = buffer.readf32(DirectionsBuffer, DirOffset + 24) :: number
	const RightY = buffer.readf32(DirectionsBuffer, DirOffset + 28) :: number
	const RightZ = buffer.readf32(DirectionsBuffer, DirOffset + 32) :: number

	const AbsRightX = math.abs(RightX) :: number
	const AbsUpY = math.abs(UpY) :: number
	const AbsLookZ = math.abs(LookZ) :: number
	const IsDegenerate = (RightX * RightX + RightY * RightY + RightZ * RightZ < 0.5) :: boolean

	-- Fast path for world-aligned OBBs (and degenerate identity basis): OBB local axes coincide with world X/Y/Z.
	if IsDegenerate or (AbsRightX >= 0.999999 and AbsUpY >= 0.999999 and AbsLookZ >= 0.999999) then
		const OverlapX = (BodyHalfSizeX + HalfSizeX) - AbsDeltaX :: number
		const OverlapY = (BodyHalfSizeY + HalfSizeY) - AbsDeltaY :: number
		const OverlapZ = (BodyHalfSizeZ + HalfSizeZ) - AbsDeltaZ :: number
		if math.min(OverlapX, OverlapY, OverlapZ) <= 0 then
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
		end
		if OverlapZ < MinOverlap then
			MinOverlap = OverlapZ
			BestNormalX = 0
			BestNormalY = 0
			BestNormalZ = if DeltaZ >= 0 then 1 else -1
		end
		return true, BestNormalX, BestNormalY, BestNormalZ, MinOverlap
	end

	const AbsRightY = math.abs(RightY) :: number
	const AbsRightZ = math.abs(RightZ) :: number
	const AbsUpX = math.abs(UpX) :: number
	const AbsUpZ = math.abs(UpZ) :: number
	const AbsLookX = math.abs(LookX) :: number
	const AbsLookY = math.abs(LookY) :: number

	const OverlapX = (BodyHalfSizeX + AbsRightX * HalfSizeX + AbsUpX * HalfSizeY + AbsLookX * HalfSizeZ) - AbsDeltaX :: number
	const OverlapY = (BodyHalfSizeY + AbsRightY * HalfSizeX + AbsUpY * HalfSizeY + AbsLookY * HalfSizeZ) - AbsDeltaY :: number
	const OverlapZ = (BodyHalfSizeZ + AbsRightZ * HalfSizeX + AbsUpZ * HalfSizeY + AbsLookZ * HalfSizeZ) - AbsDeltaZ :: number
	if math.min(OverlapX, OverlapY, OverlapZ) <= 0 then
		return false, 0, 0, 0, 0
	end

	const UpAxisDistance = DeltaX * UpX + DeltaY * UpY + DeltaZ * UpZ :: number
	const RightAxisDistance = DeltaX * RightX + DeltaY * RightY + DeltaZ * RightZ :: number
	const LookAxisDistance = DeltaX * LookX + DeltaY * LookY + DeltaZ * LookZ :: number

	const OverlapUp = (AbsUpX * BodyHalfSizeX + AbsUpY * BodyHalfSizeY + AbsUpZ * BodyHalfSizeZ + HalfSizeY) - math.abs(UpAxisDistance) :: number
	const OverlapRight = (AbsRightX * BodyHalfSizeX + AbsRightY * BodyHalfSizeY + AbsRightZ * BodyHalfSizeZ + HalfSizeX) - math.abs(RightAxisDistance) :: number
	const OverlapLook = (AbsLookX * BodyHalfSizeX + AbsLookY * BodyHalfSizeY + AbsLookZ * BodyHalfSizeZ + HalfSizeZ) - math.abs(LookAxisDistance) :: number
	if math.min(OverlapUp, OverlapRight, OverlapLook) <= 0 then
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
	if OverlapUp < MinOverlap then
		const UpAxisSign = if UpAxisDistance >= 0 then 1 else -1 :: number
		MinOverlap = OverlapUp
		BestNormalX, BestNormalY, BestNormalZ = UpX * UpAxisSign, UpY * UpAxisSign, UpZ * UpAxisSign
	end
	if OverlapRight < MinOverlap then
		const RightAxisSign = if RightAxisDistance >= 0 then 1 else -1 :: number
		MinOverlap = OverlapRight
		BestNormalX, BestNormalY, BestNormalZ = RightX * RightAxisSign, RightY * RightAxisSign, RightZ * RightAxisSign
	end
	if OverlapLook < MinOverlap then
		const LookAxisSign = if LookAxisDistance >= 0 then 1 else -1 :: number
		MinOverlap = OverlapLook
		BestNormalX, BestNormalY, BestNormalZ = LookX * LookAxisSign, LookY * LookAxisSign, LookZ * LookAxisSign
	end

	return true, BestNormalX, BestNormalY, BestNormalZ, MinOverlap
end

return PhysicsSATMath
