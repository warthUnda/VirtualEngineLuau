--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const FLAG_CAN_COLLIDE = bit32.lshift(1, 1) :: number

-- Tables --
local BVHMath = {}

-- Functions --

-- ============================================================================
-- 1. SCALAR RAY-AABB & RAY-OBB INTERSECTION KERNELS
-- ============================================================================

--[=[
	Tests ray intersection against an axis-aligned bounding box node in the BVH tree buffer.
]=]
function BVHMath.TestNodeAABB(
	NodeBuffer: buffer,
	NodeOffset: number,
	OriginX: number, OriginY: number, OriginZ: number,
	InverseDirectionX: number, InverseDirectionY: number, InverseDirectionZ: number,
	MaxDistance: number
): (boolean, number)
	const MinX = buffer.readf32(NodeBuffer, NodeOffset) :: number
	const MinY = buffer.readf32(NodeBuffer, NodeOffset + 4) :: number
	const MinZ = buffer.readf32(NodeBuffer, NodeOffset + 8) :: number
	const MaxX = buffer.readf32(NodeBuffer, NodeOffset + 16) :: number
	const MaxY = buffer.readf32(NodeBuffer, NodeOffset + 20) :: number
	const MaxZ = buffer.readf32(NodeBuffer, NodeOffset + 24) :: number

	const SlabEnterX = (MinX - OriginX) * InverseDirectionX :: number
	const SlabExitX = (MaxX - OriginX) * InverseDirectionX :: number
	local NearHitDistance = math.min(SlabEnterX, SlabExitX) :: number
	local FarHitDistance = math.max(SlabEnterX, SlabExitX) :: number

	const SlabEnterY = (MinY - OriginY) * InverseDirectionY :: number
	const SlabExitY = (MaxY - OriginY) * InverseDirectionY :: number
	NearHitDistance = math.max(NearHitDistance, math.min(SlabEnterY, SlabExitY))
	FarHitDistance = math.min(FarHitDistance, math.max(SlabEnterY, SlabExitY))

	const SlabEnterZ = (MinZ - OriginZ) * InverseDirectionZ :: number
	const SlabExitZ = (MaxZ - OriginZ) * InverseDirectionZ :: number
	NearHitDistance = math.max(NearHitDistance, math.min(SlabEnterZ, SlabExitZ))
	FarHitDistance = math.min(FarHitDistance, math.max(SlabEnterZ, SlabExitZ))

	const EntryDistance = math.max(0, NearHitDistance) :: number
	return (FarHitDistance >= EntryDistance) and (EntryDistance < MaxDistance), EntryDistance
end

--[=[
	Calculates exact ray intersection, hit distance, and outward normal against an oriented bounding box (OBB).
]=]
function BVHMath.TestBoxOBB(
	OriginX: number, OriginY: number, OriginZ: number,
	DirectionX: number, DirectionY: number, DirectionZ: number,
	PositionX: number, PositionY: number, PositionZ: number,
	HalfSizeX: number, HalfSizeY: number, HalfSizeZ: number,
	RightX: number, RightY: number, RightZ: number,
	UpX: number, UpY: number, UpZ: number,
	LookX: number, LookY: number, LookZ: number,
	MaxDistance: number
): (boolean, number, number, number, number)
	const DeltaX = OriginX - PositionX :: number
	const DeltaY = OriginY - PositionY :: number
	const DeltaZ = OriginZ - PositionZ :: number

	const LocalOriginX = DeltaX * RightX + DeltaY * RightY + DeltaZ * RightZ :: number
	const LocalOriginY = DeltaX * UpX + DeltaY * UpY + DeltaZ * UpZ :: number
	const LocalOriginZ = DeltaX * LookX + DeltaY * LookY + DeltaZ * LookZ :: number

	const LocalDirectionX = DirectionX * RightX + DirectionY * RightY + DirectionZ * RightZ :: number
	const LocalDirectionY = DirectionX * UpX + DirectionY * UpY + DirectionZ * UpZ :: number
	const LocalDirectionZ = DirectionX * LookX + DirectionY * LookY + DirectionZ * LookZ :: number

	const InverseLocalX = if math.abs(LocalDirectionX) > 1e-8 then 1 / LocalDirectionX else (if LocalDirectionX >= 0 then 1e30 else -1e30) :: number
	const InverseLocalY = if math.abs(LocalDirectionY) > 1e-8 then 1 / LocalDirectionY else (if LocalDirectionY >= 0 then 1e30 else -1e30) :: number
	const InverseLocalZ = if math.abs(LocalDirectionZ) > 1e-8 then 1 / LocalDirectionZ else (if LocalDirectionZ >= 0 then 1e30 else -1e30) :: number

	const SlabEnterX = (-HalfSizeX - LocalOriginX) * InverseLocalX :: number
	const SlabExitX = (HalfSizeX - LocalOriginX) * InverseLocalX :: number
	local NearHitDistance = math.min(SlabEnterX, SlabExitX) :: number
	local FarHitDistance = math.max(SlabEnterX, SlabExitX) :: number
	local HitAxis = 0 :: number

	const SlabEnterY = (-HalfSizeY - LocalOriginY) * InverseLocalY :: number
	const SlabExitY = (HalfSizeY - LocalOriginY) * InverseLocalY :: number
	const SlabMinY = math.min(SlabEnterY, SlabExitY) :: number
	const SlabMaxY = math.max(SlabEnterY, SlabExitY) :: number
	if SlabMinY > NearHitDistance then
		NearHitDistance = SlabMinY
		HitAxis = 1
	end
	if SlabMaxY < FarHitDistance then
		FarHitDistance = SlabMaxY
	end

	const SlabEnterZ = (-HalfSizeZ - LocalOriginZ) * InverseLocalZ :: number
	const SlabExitZ = (HalfSizeZ - LocalOriginZ) * InverseLocalZ :: number
	const SlabMinZ = math.min(SlabEnterZ, SlabExitZ) :: number
	const SlabMaxZ = math.max(SlabEnterZ, SlabExitZ) :: number
	if SlabMinZ > NearHitDistance then
		NearHitDistance = SlabMinZ
		HitAxis = 2
	end
	if SlabMaxZ < FarHitDistance then
		FarHitDistance = SlabMaxZ
	end

	const EntryDistance = math.max(0, NearHitDistance) :: number
	if FarHitDistance < EntryDistance or EntryDistance >= MaxDistance then
		return false, MaxDistance, 0, 0, 0
	end

	if HitAxis == 0 then
		const AxisSign = if LocalDirectionX > 0 then -1 else 1 :: number
		return true, EntryDistance, RightX * AxisSign, RightY * AxisSign, RightZ * AxisSign
	elseif HitAxis == 1 then
		const AxisSign = if LocalDirectionY > 0 then -1 else 1 :: number
		return true, EntryDistance, UpX * AxisSign, UpY * AxisSign, UpZ * AxisSign
	end
	const AxisSign = if LocalDirectionZ > 0 then -1 else 1 :: number
	return true, EntryDistance, LookX * AxisSign, LookY * AxisSign, LookZ * AxisSign
end

--[=[
	Casts a ray against an ECS entity's OBB using bounding sphere early-out.
]=]
function BVHMath.TestEntityOBB(
	EntityId: number,
	OriginX: number, OriginY: number, OriginZ: number,
	DirectionX: number, DirectionY: number, DirectionZ: number,
	MaxDistance: number,
	PositionBuffer: buffer,
	SizeBuffer: buffer,
	DirectionsBuffer: buffer,
	PropertiesBuffer: buffer
): (boolean, number, number, number, number)
	const PropRegister = buffer.readu32(PropertiesBuffer, (EntityId - 1) * PROPERTIES_STRIDE) :: number
	if PropRegister ~= 0 and not bit32.btest(PropRegister, FLAG_CAN_COLLIDE) then
		return false, MaxDistance, 0, 0, 0
	end

	const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
	const PositionX = buffer.readf32(PositionBuffer, CompOffset) :: number
	const PositionY = buffer.readf32(PositionBuffer, CompOffset + 4) :: number
	const PositionZ = buffer.readf32(PositionBuffer, CompOffset + 8) :: number
	const HalfSizeX = math.abs(buffer.readf32(SizeBuffer, CompOffset)) * 0.5 :: number
	const HalfSizeY = math.abs(buffer.readf32(SizeBuffer, CompOffset + 4)) * 0.5 :: number
	const HalfSizeZ = math.abs(buffer.readf32(SizeBuffer, CompOffset + 8)) * 0.5 :: number

	const RelativeX = PositionX - OriginX :: number
	const RelativeY = PositionY - OriginY :: number
	const RelativeZ = PositionZ - OriginZ :: number
	const BoundingRadiusSquared = HalfSizeX * HalfSizeX + HalfSizeY * HalfSizeY + HalfSizeZ * HalfSizeZ :: number
	const RayProjection = RelativeX * DirectionX + RelativeY * DirectionY + RelativeZ * DirectionZ :: number
	const PerpendicularDistanceSquared = (RelativeX * RelativeX + RelativeY * RelativeY + RelativeZ * RelativeZ) - (RayProjection * RayProjection) :: number
	if PerpendicularDistanceSquared > BoundingRadiusSquared + 1e-5 then
		return false, MaxDistance, 0, 0, 0
	end

	const BoundingRadius = math.sqrt(BoundingRadiusSquared) :: number
	if RayProjection < -BoundingRadius or (RayProjection - BoundingRadius) >= MaxDistance then
		return false, MaxDistance, 0, 0, 0
	end

	const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
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

	return BVHMath.TestBoxOBB(
		OriginX, OriginY, OriginZ, DirectionX, DirectionY, DirectionZ,
		PositionX, PositionY, PositionZ, HalfSizeX, HalfSizeY, HalfSizeZ,
		RightX, RightY, RightZ, UpX, UpY, UpZ, LookX, LookY, LookZ, MaxDistance
	)
end

return BVHMath
