--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const MAX_ENTITIES = SystemsConfigs.ECSMaxEntities :: number
const STACK_CAPACITY = SystemsConfigs.BVHStackCapacity :: number
const NODE_STRIDE = 32 :: number
const ITEM_BOUNDS_STRIDE = 24 :: number
const MAX_NODE_BYTES = MAX_ENTITIES * 2 * NODE_STRIDE :: number
const SAFE_BALANCED_DEPTH = math.max(16, STACK_CAPACITY - 16) :: number

-- Tables --
local BVHSubtreeBuilder = {}

-- Functions --
-- ============================================================================
-- 1. FLAT-BUFFER SPATIAL MEDIAN BVH SUBTREE BUILDER
-- ============================================================================

--[=[
	Recursively partitions entity bounding boxes and builds a flat binary BVH subtree into NodeBuffer.
	@return (number, number) -- NodeOffset, NextAllocatedBytes.
]=]
function BVHSubtreeBuilder.BuildSubtree(
	NodeBuffer: buffer,
	ItemBoundsBuffer: buffer,
	ItemIndicesBuffer: buffer,
	AllocatedNodeBytes: number,
	StartIdx: number,
	EndIdx: number,
	Depth: number
): (number, number)
	const NodeOffset = AllocatedNodeBytes :: number
	local NextAllocatedBytes = AllocatedNodeBytes + NODE_STRIDE :: number

	local MinX, MinY, MinZ = math.huge, math.huge, math.huge
	local MaxX, MaxY, MaxZ = -math.huge, -math.huge, -math.huge
	local CenterMinX, CenterMinY, CenterMinZ = math.huge, math.huge, math.huge
	local CenterMaxX, CenterMaxY, CenterMaxZ = -math.huge, -math.huge, -math.huge

	for i = StartIdx, EndIdx do
		const EntityId = buffer.readu32(ItemIndicesBuffer, (i - 1) * 4) :: number
		const BoundsOffset = (EntityId - 1) * ITEM_BOUNDS_STRIDE :: number

		const ItemMinX = buffer.readf32(ItemBoundsBuffer, BoundsOffset) :: number
		const ItemMinY = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 4) :: number
		const ItemMinZ = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 8) :: number
		const ItemMaxX = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 12) :: number
		const ItemMaxY = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 16) :: number
		const ItemMaxZ = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 20) :: number
		const ItemCenterX = (ItemMinX + ItemMaxX) * 0.5 :: number
		const ItemCenterY = (ItemMinY + ItemMaxY) * 0.5 :: number
		const ItemCenterZ = (ItemMinZ + ItemMaxZ) * 0.5 :: number

		MinX = math.min(MinX, ItemMinX)
		MinY = math.min(MinY, ItemMinY)
		MinZ = math.min(MinZ, ItemMinZ)
		MaxX = math.max(MaxX, ItemMaxX)
		MaxY = math.max(MaxY, ItemMaxY)
		MaxZ = math.max(MaxZ, ItemMaxZ)
		CenterMinX = math.min(CenterMinX, ItemCenterX)
		CenterMinY = math.min(CenterMinY, ItemCenterY)
		CenterMinZ = math.min(CenterMinZ, ItemCenterZ)
		CenterMaxX = math.max(CenterMaxX, ItemCenterX)
		CenterMaxY = math.max(CenterMaxY, ItemCenterY)
		CenterMaxZ = math.max(CenterMaxZ, ItemCenterZ)
	end

	buffer.writef32(NodeBuffer, NodeOffset, MinX)
	buffer.writef32(NodeBuffer, NodeOffset + 4, MinY)
	buffer.writef32(NodeBuffer, NodeOffset + 8, MinZ)
	buffer.writef32(NodeBuffer, NodeOffset + 16, MaxX)
	buffer.writef32(NodeBuffer, NodeOffset + 20, MaxY)
	buffer.writef32(NodeBuffer, NodeOffset + 24, MaxZ)

	if StartIdx >= EndIdx or NextAllocatedBytes + (NODE_STRIDE * 2) > MAX_NODE_BYTES then
		buffer.writeu32(NodeBuffer, NodeOffset + 12, buffer.readu32(ItemIndicesBuffer, (StartIdx - 1) * 4))
		buffer.writeu32(NodeBuffer, NodeOffset + 28, 0)
		return NodeOffset, NextAllocatedBytes
	end

	const ExtentX = CenterMaxX - CenterMinX :: number
	const ExtentY = CenterMaxY - CenterMinY :: number
	const ExtentZ = CenterMaxZ - CenterMinZ :: number

	local AxisOffset = 0 :: number
	local SplitDouble = CenterMinX + CenterMaxX :: number
	local MaxExtent = ExtentX :: number
	if ExtentY > MaxExtent then
		AxisOffset = 4
		SplitDouble = CenterMinY + CenterMaxY
		MaxExtent = ExtentY
	end
	if ExtentZ > MaxExtent then
		AxisOffset = 8
		SplitDouble = CenterMinZ + CenterMaxZ
		MaxExtent = ExtentZ
	end

	local MidIndex = (StartIdx + EndIdx) // 2 :: number
	if MaxExtent > 1e-4 and Depth < SAFE_BALANCED_DEPTH then
		local LeftIndex = StartIdx :: number
		local RightIndex = EndIdx :: number
		while LeftIndex <= RightIndex do
			const LeftEntity = buffer.readu32(ItemIndicesBuffer, (LeftIndex - 1) * 4) :: number
			const LeftBounds = (LeftEntity - 1) * ITEM_BOUNDS_STRIDE + AxisOffset :: number
			if buffer.readf32(ItemBoundsBuffer, LeftBounds) + buffer.readf32(ItemBoundsBuffer, LeftBounds + 12) < SplitDouble then
				LeftIndex += 1
			else
				const RightEntity = buffer.readu32(ItemIndicesBuffer, (RightIndex - 1) * 4) :: number
				buffer.writeu32(ItemIndicesBuffer, (LeftIndex - 1) * 4, RightEntity)
				buffer.writeu32(ItemIndicesBuffer, (RightIndex - 1) * 4, LeftEntity)
				RightIndex -= 1
			end
		end
		if LeftIndex > StartIdx and LeftIndex <= EndIdx then
			MidIndex = LeftIndex - 1
		end
	end

	const NextDepth = Depth + 1 :: number
	local LeftNodeOffset: number
	LeftNodeOffset, NextAllocatedBytes = BVHSubtreeBuilder.BuildSubtree(
		NodeBuffer, ItemBoundsBuffer, ItemIndicesBuffer, NextAllocatedBytes, StartIdx, MidIndex, NextDepth
	)
	local RightNodeOffset: number
	RightNodeOffset, NextAllocatedBytes = BVHSubtreeBuilder.BuildSubtree(
		NodeBuffer, ItemBoundsBuffer, ItemIndicesBuffer, NextAllocatedBytes, MidIndex + 1, EndIdx, NextDepth
	)

	buffer.writeu32(NodeBuffer, NodeOffset + 12, LeftNodeOffset)
	buffer.writeu32(NodeBuffer, NodeOffset + 28, RightNodeOffset)
	return NodeOffset, NextAllocatedBytes
end

return BVHSubtreeBuilder
