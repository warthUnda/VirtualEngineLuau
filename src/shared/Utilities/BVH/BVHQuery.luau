--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))
const BVHState = require(script.Parent.BVHState)

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const STACK_CAPACITY = SystemsConfigs.BVHStackCapacity :: number
const FLAG_CAN_COLLIDE = bit32.lshift(1, 1) :: number

-- Tables --
local BVHQuery = {}

-- Buffers
const TableQueryScratch = buffer.create(SystemsConfigs.ECSMaxEntities * 4) :: buffer

-- Functions --
-- ============================================================================
-- 1. ALLOCATION-FREE SCALAR & VECTOR3 AABB OVERLAP QUERIES
-- ============================================================================

--[=[
	Allocation-free scalar AABB overlap query writing candidate entity IDs into a pre-allocated u32 buffer.
]=]
function BVHQuery.QueryAABBScalar(
	MinX: number, MinY: number, MinZ: number,
	MaxX: number, MaxY: number, MaxZ: number,
	ResultsBuffer: buffer,
	MaxResults: number,
	ProvidedStorage: ECSMain.ECSStorage?,
	SkipNeedsRebuild: boolean?
): number
	const Storage, EntityCount = BVHState.EnsureFreshAndResolve(ProvidedStorage, SkipNeedsRebuild)
	if not Storage then
		return 0
	end

	const QueryMinX = math.min(MinX, MaxX) :: number
	const QueryMinY = math.min(MinY, MaxY) :: number
	const QueryMinZ = math.min(MinZ, MaxZ) :: number
	const QueryMaxX = math.max(MinX, MaxX) :: number
	const QueryMaxY = math.max(MinY, MaxY) :: number
	const QueryMaxZ = math.max(MinZ, MaxZ) :: number

	local ResultCount = 0 :: number
	const NodeBuffer = BVHState.NodeBuffer
	const TraversalStackBuffer = BVHState.TraversalStackBuffer

	if BVHState.AllocatedNodeBytes > 0 then
		local StackTop = 1 :: number
		buffer.writeu32(TraversalStackBuffer, 0, 0)

		while StackTop > 0 do
			StackTop -= 1
			const NodeOffset = buffer.readu32(TraversalStackBuffer, StackTop * 4) :: number
			if
				buffer.readf32(NodeBuffer, NodeOffset) > QueryMaxX
				or buffer.readf32(NodeBuffer, NodeOffset + 16) < QueryMinX
				or buffer.readf32(NodeBuffer, NodeOffset + 4) > QueryMaxY
				or buffer.readf32(NodeBuffer, NodeOffset + 20) < QueryMinY
				or buffer.readf32(NodeBuffer, NodeOffset + 8) > QueryMaxZ
				or buffer.readf32(NodeBuffer, NodeOffset + 24) < QueryMinZ
			then
				continue
			end

			const RightOffset = buffer.readu32(NodeBuffer, NodeOffset + 28) :: number
			if RightOffset == 0 then
				const EntityId = buffer.readu32(NodeBuffer, NodeOffset + 12) :: number
				if EntityId >= 1 and EntityId <= EntityCount and ResultCount < MaxResults then
					buffer.writeu32(ResultsBuffer, ResultCount * 4, EntityId)
					ResultCount += 1
				end
			elseif StackTop + 2 <= STACK_CAPACITY then
				const LeftOffset = buffer.readu32(NodeBuffer, NodeOffset + 12) :: number
				buffer.writeu32(TraversalStackBuffer, StackTop * 4, LeftOffset)
				buffer.writeu32(TraversalStackBuffer, (StackTop + 1) * 4, RightOffset)
				StackTop += 2
			end
		end
	end

	const PositionBuffer = Storage.PositionData.GetData() :: buffer
	const SizeBuffer = Storage.SizeData.GetData() :: buffer
	const DirectionsBuffer = Storage.DirectionsData.GetData() :: buffer
	const PropertiesBuffer = Storage.PropertiesData.GetData() :: buffer
	const DynamicEntitiesBuffer = BVHState.DynamicEntitiesBuffer

	for i = 0, BVHState.DynamicEntityCount - 1 do
		const EntityId = buffer.readu32(DynamicEntitiesBuffer, i * 4) :: number
		if EntityId < 1 or EntityId > EntityCount then
			continue
		end

		const PropRegister = buffer.readu32(PropertiesBuffer, (EntityId - 1) * PROPERTIES_STRIDE) :: number
		if PropRegister ~= 0 and not bit32.btest(PropRegister, FLAG_CAN_COLLIDE) then
			continue
		end

		const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
		const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
		const PositionX = buffer.readf32(PositionBuffer, CompOffset) :: number
		const PositionY = buffer.readf32(PositionBuffer, CompOffset + 4) :: number
		const PositionZ = buffer.readf32(PositionBuffer, CompOffset + 8) :: number
		const HalfSizeX = math.abs(buffer.readf32(SizeBuffer, CompOffset)) * 0.5 :: number
		const HalfSizeY = math.abs(buffer.readf32(SizeBuffer, CompOffset + 4)) * 0.5 :: number
		const HalfSizeZ = math.abs(buffer.readf32(SizeBuffer, CompOffset + 8)) * 0.5 :: number

		local LookX, LookY, LookZ = buffer.readf32(DirectionsBuffer, DirOffset), buffer.readf32(DirectionsBuffer, DirOffset + 4), buffer.readf32(DirectionsBuffer, DirOffset + 8)
		local UpX, UpY, UpZ = buffer.readf32(DirectionsBuffer, DirOffset + 12), buffer.readf32(DirectionsBuffer, DirOffset + 16), buffer.readf32(DirectionsBuffer, DirOffset + 20)
		local RightX, RightY, RightZ = buffer.readf32(DirectionsBuffer, DirOffset + 24), buffer.readf32(DirectionsBuffer, DirOffset + 28), buffer.readf32(DirectionsBuffer, DirOffset + 32)
		if RightX * RightX + RightY * RightY + RightZ * RightZ < 0.5 then
			LookX, LookY, LookZ = 0, 0, -1
			UpX, UpY, UpZ = 0, 1, 0
			RightX, RightY, RightZ = 1, 0, 0
		end

		const WorldExtentX = math.abs(RightX) * HalfSizeX + math.abs(UpX) * HalfSizeY + math.abs(LookX) * HalfSizeZ :: number
		const WorldExtentY = math.abs(RightY) * HalfSizeX + math.abs(UpY) * HalfSizeY + math.abs(LookY) * HalfSizeZ :: number
		const WorldExtentZ = math.abs(RightZ) * HalfSizeX + math.abs(UpZ) * HalfSizeY + math.abs(LookZ) * HalfSizeZ :: number

		if
			PositionX - WorldExtentX <= QueryMaxX and PositionX + WorldExtentX >= QueryMinX
			and PositionY - WorldExtentY <= QueryMaxY and PositionY + WorldExtentY >= QueryMinY
			and PositionZ - WorldExtentZ <= QueryMaxZ and PositionZ + WorldExtentZ >= QueryMinZ
		then
			if ResultCount < MaxResults then
				buffer.writeu32(ResultsBuffer, ResultCount * 4, EntityId)
				ResultCount += 1
			end
		end
	end

	return ResultCount
end

--[=[
	Queries the spatial tree for all entities whose bounding boxes overlap the given Vector3 AABB.
]=]
function BVHQuery.QueryAABB(
	QueryMin: Vector3,
	QueryMax: Vector3,
	ResultsTable: { number }?,
	ProvidedStorage: ECSMain.ECSStorage?
): number
	if typeof(QueryMin) ~= "Vector3" or typeof(QueryMax) ~= "Vector3" then
		return 0
	end

	const Count = BVHQuery.QueryAABBScalar(
		QueryMin.X, QueryMin.Y, QueryMin.Z,
		QueryMax.X, QueryMax.Y, QueryMax.Z,
		TableQueryScratch, SystemsConfigs.ECSMaxEntities, ProvidedStorage, false
	)
	if ResultsTable then
		for i = 1, Count do
			ResultsTable[i] = buffer.readu32(TableQueryScratch, (i - 1) * 4)
		end
	end
	return Count
end

return BVHQuery
