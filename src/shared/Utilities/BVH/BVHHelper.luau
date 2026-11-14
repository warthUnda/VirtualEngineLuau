--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")
const ServerScriptService = game:GetService("ServerScriptService")

-- Static References --
const IS_SERVER = RunService:IsServer() :: boolean
const SelfActor = script:GetActor() :: Actor?

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const MAX_ENTITIES = SystemsConfigs.ECSMaxEntities :: number
const STACK_CAPACITY = SystemsConfigs.BVHStackCapacity :: number
const MUTATION_SCAN_BUDGET = SystemsConfigs.BVHMutationScanBudget :: number

const NODE_STRIDE = 32 :: number
const ITEM_BOUNDS_STRIDE = 36 :: number
const CACHED_STATE_STRIDE = 28 :: number
const MAX_BVH_NODES = MAX_ENTITIES * 2 :: number
const MAX_NODE_BYTES = MAX_BVH_NODES * NODE_STRIDE :: number
const SAFE_BALANCED_DEPTH = math.max(16, STACK_CAPACITY - 16) :: number

-- Tables --
local DefaultServerStorage: ECSMain.ECSStorage? = nil
local DefaultClientStorage: ECSMain.ECSStorage? = nil
local DefaultRenderStorage: ECSMain.ECSStorage? = nil

local BVHHelper = {}

-- ============================================================================
-- 1. STORAGE RESOLUTION, MUTATION DETECTION & SUBTREE BUILDER HELPERS
-- ============================================================================

--[=[
	Validates whether a table matches the ECSStorage structure.
	@param Candidate any -- Object to validate.
	@return boolean -- True if table has required ECSStorage components.
]=]
function BVHHelper.IsECSStorage(Candidate: any): boolean
	return type(Candidate) == "table"
		and Candidate.ECSData ~= nil
		and Candidate.PositionData ~= nil
		and Candidate.SizeData ~= nil
		and Candidate.DirectionsData ~= nil
end

--[=[
	Resolves the appropriate active ECS storage instance on client or server.
	@param ProvidedStorage ECSMain.ECSStorage? -- Explicit storage override.
	@return ECSMain.ECSStorage? -- Resolved ECSStorage structure.
]=]
function BVHHelper.ResolveStorage(ProvidedStorage: ECSMain.ECSStorage?): ECSMain.ECSStorage?
	if ProvidedStorage and BVHHelper.IsECSStorage(ProvidedStorage) then
		return ProvidedStorage
	end

	if IS_SERVER then
		if not DefaultServerStorage then
			const ServerFolder = ServerScriptService:FindFirstChild("Server")
			const ObjectsFolder = if ServerFolder then ServerFolder:FindFirstChild("Objects") else nil
			const ObjectsECS = if ObjectsFolder then ObjectsFolder:FindFirstChild("ObjectsECS") else nil
			const StorageModule = if ObjectsECS then ObjectsECS:FindFirstChild("Storage") else nil
			if StorageModule and StorageModule:IsA("ModuleScript") then
				DefaultServerStorage = (require :: any)(StorageModule) :: ECSMain.ECSStorage
			end
		end
		return DefaultServerStorage
	end

	if not DefaultClientStorage then
		const ActorStorage = if SelfActor then SelfActor:FindFirstChild("ObjectStorage") else nil
		if ActorStorage and ActorStorage:IsA("ModuleScript") then
			DefaultClientStorage = (require :: any)(ActorStorage) :: ECSMain.ECSStorage
		else
			const LocalPlayer = Players.LocalPlayer :: Player?
			const PlayerScripts = if LocalPlayer then LocalPlayer:FindFirstChild("PlayerScripts") else nil
			const ControllerActor = if PlayerScripts then PlayerScripts:FindFirstChild("Controller") else nil
			const ControllerStorage = if ControllerActor then ControllerActor:FindFirstChild("ObjectStorage") else nil
			const ClientFolder = if PlayerScripts then PlayerScripts:FindFirstChild("Client") else nil
			const ObjectsFolder = if ClientFolder then ClientFolder:FindFirstChild("Objects") else nil
			const ObjStorage = if ObjectsFolder then ObjectsFolder:FindFirstChild("ObjectStorage") else nil

			if ControllerStorage and ControllerStorage:IsA("ModuleScript") then
				DefaultClientStorage = (require :: any)(ControllerStorage) :: ECSMain.ECSStorage
			elseif ObjStorage and ObjStorage:IsA("ModuleScript") then
				DefaultClientStorage = (require :: any)(ObjStorage) :: ECSMain.ECSStorage
			end
		end
	end

	if DefaultClientStorage and DefaultClientStorage.ECSData.GetCounts().EntityECSCount > 0 then
		return DefaultClientStorage
	end

	if not DefaultRenderStorage then
		const SharedFolder = ReplicatedStorage:FindFirstChild("Shared")
		const UtilitiesFolder = if SharedFolder then SharedFolder:FindFirstChild("Utilities") else nil
		const RenderFolder = if UtilitiesFolder then UtilitiesFolder:FindFirstChild("Render") else nil
		const RenderStorageModule = if RenderFolder then RenderFolder:FindFirstChild("ECSStorage") else nil
		if RenderStorageModule and RenderStorageModule:IsA("ModuleScript") then
			DefaultRenderStorage = (require :: any)(RenderStorageModule) :: ECSMain.ECSStorage
		end
	end

	return DefaultRenderStorage or DefaultClientStorage
end

--[=[
	Checks whether the BVH hierarchy requires a rebuild due to count or entity transform mutations.
	@param Storage ECSMain.ECSStorage -- Active ECS storage.
	@param ActiveStorage ECSMain.ECSStorage? -- Last built storage reference.
	@param EntityCount number -- Current entity count.
	@param LastBuiltEntityCount number -- Entity count from last build.
	@param LastDynamicActiveCount number -- Dynamic count from last build.
	@param LastDynamicNextId number -- Dynamic NextId from last build.
	@param MutationScanCursor number -- Scanning cursor offset.
	@param CachedStateBuffer buffer -- Cached entity transform buffer.
	@param EntityIsDynamicBuffer buffer -- Dynamic entity boolean buffer.
	@param ItemBoundsBuffer buffer -- Item bounding boxes buffer.
	@return (boolean, number) -- NeedsRebuild, NextMutationScanCursor.
]=]
function BVHHelper.NeedsRebuild(
	Storage: ECSMain.ECSStorage,
	ActiveStorage: ECSMain.ECSStorage?,
	EntityCount: number,
	LastBuiltEntityCount: number,
	LastDynamicActiveCount: number,
	LastDynamicNextId: number,
	MutationScanCursor: number,
	CachedStateBuffer: buffer,
	EntityIsDynamicBuffer: buffer,
	ItemBoundsBuffer: buffer
): (boolean, number)
	if Storage ~= ActiveStorage or EntityCount ~= LastBuiltEntityCount then
		return true, MutationScanCursor
	end

	const DynList = Storage.DynamicObjectsList
	if DynList then
		if DynList.Counts.ActiveCount ~= LastDynamicActiveCount or DynList.Counts.NextId ~= LastDynamicNextId then
			return true, MutationScanCursor
		end
	end

	if EntityCount <= 0 then
		return false, MutationScanCursor
	end

	const PositionBuffer = Storage.PositionData.GetData() :: buffer
	const SizeBuffer = Storage.SizeData.GetData() :: buffer
	const DirectionsBuffer = Storage.DirectionsData.GetData() :: buffer
	const PropertiesBuffer = Storage.PropertiesData.GetData() :: buffer

	const CheckCount = math.min(EntityCount, MUTATION_SCAN_BUDGET) :: number
	local EntityId = MutationScanCursor :: number
	if EntityId < 1 or EntityId > EntityCount then
		EntityId = 1
	end

	for _ = 1, CheckCount do
		const StateOffset = (EntityId - 1) * CACHED_STATE_STRIDE :: number
		const PropOffset = (EntityId - 1) * PROPERTIES_STRIDE :: number
		const CurrentProp = buffer.readu32(PropertiesBuffer, PropOffset) :: number

		if CurrentProp ~= buffer.readu32(CachedStateBuffer, StateOffset + 24) then
			return true, EntityId
		end

		if buffer.readu8(EntityIsDynamicBuffer, EntityId) == 0 then
			const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
			const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
			const BoundsOffset = (EntityId - 1) * ITEM_BOUNDS_STRIDE :: number

			if
				buffer.readf32(PositionBuffer, CompOffset) ~= buffer.readf32(ItemBoundsBuffer, BoundsOffset + 24)
				or buffer.readf32(PositionBuffer, CompOffset + 4) ~= buffer.readf32(ItemBoundsBuffer, BoundsOffset + 28)
				or buffer.readf32(PositionBuffer, CompOffset + 8) ~= buffer.readf32(ItemBoundsBuffer, BoundsOffset + 32)
				or buffer.readf32(SizeBuffer, CompOffset) ~= buffer.readf32(CachedStateBuffer, StateOffset)
				or buffer.readf32(SizeBuffer, CompOffset + 4) ~= buffer.readf32(CachedStateBuffer, StateOffset + 4)
				or buffer.readf32(SizeBuffer, CompOffset + 8) ~= buffer.readf32(CachedStateBuffer, StateOffset + 8)
				or buffer.readf32(DirectionsBuffer, DirOffset) ~= buffer.readf32(CachedStateBuffer, StateOffset + 12)
				or buffer.readf32(DirectionsBuffer, DirOffset + 16) ~= buffer.readf32(
					CachedStateBuffer,
					StateOffset + 16
				)
				or buffer.readf32(DirectionsBuffer, DirOffset + 32)
					~= buffer.readf32(CachedStateBuffer, StateOffset + 20)
			then
				return true, EntityId
			end
		end

		EntityId += 1
		if EntityId > EntityCount then
			EntityId = 1
		end
	end

	return false, EntityId
end

--[=[
	Recursively partitions entity bounding boxes and builds a flat binary BVH subtree into the node buffer.
	@param NodeBuffer buffer -- Destination BVH tree node buffer.
	@param ItemBoundsBuffer buffer -- Item bounding boxes buffer.
	@param ItemIndicesBuffer buffer -- Array of entity indices being partitioned.
	@param AllocatedNodeBytes number -- Current byte offset in node buffer.
	@param StartIdx number -- Start index in item indices buffer.
	@param EndIdx number -- End index in item indices buffer.
	@param Depth number -- Current tree recursion depth.
	@return (number, number) -- NodeOffset, NextAllocatedBytes.
]=]
function BVHHelper.BuildSubtree(
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

	local MinX = math.huge :: number
	local MinY = math.huge :: number
	local MinZ = math.huge :: number
	local MaxX = -math.huge :: number
	local MaxY = -math.huge :: number
	local MaxZ = -math.huge :: number
	local CenterMinX = math.huge :: number
	local CenterMinY = math.huge :: number
	local CenterMinZ = math.huge :: number
	local CenterMaxX = -math.huge :: number
	local CenterMaxY = -math.huge :: number
	local CenterMaxZ = -math.huge :: number

	for i = StartIdx, EndIdx do
		const EntityId = buffer.readu32(ItemIndicesBuffer, (i - 1) * 4) :: number
		const BoundsOffset = (EntityId - 1) * ITEM_BOUNDS_STRIDE :: number

		const ItemMinX = buffer.readf32(ItemBoundsBuffer, BoundsOffset) :: number
		const ItemMinY = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 4) :: number
		const ItemMinZ = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 8) :: number
		const ItemMaxX = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 12) :: number
		const ItemMaxY = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 16) :: number
		const ItemMaxZ = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 20) :: number
		const ItemCenterX = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 24) :: number
		const ItemCenterY = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 28) :: number
		const ItemCenterZ = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 32) :: number

		if ItemMinX < MinX then
			MinX = ItemMinX
		end
		if ItemMinY < MinY then
			MinY = ItemMinY
		end
		if ItemMinZ < MinZ then
			MinZ = ItemMinZ
		end
		if ItemMaxX > MaxX then
			MaxX = ItemMaxX
		end
		if ItemMaxY > MaxY then
			MaxY = ItemMaxY
		end
		if ItemMaxZ > MaxZ then
			MaxZ = ItemMaxZ
		end
		if ItemCenterX < CenterMinX then
			CenterMinX = ItemCenterX
		end
		if ItemCenterY < CenterMinY then
			CenterMinY = ItemCenterY
		end
		if ItemCenterZ < CenterMinZ then
			CenterMinZ = ItemCenterZ
		end
		if ItemCenterX > CenterMaxX then
			CenterMaxX = ItemCenterX
		end
		if ItemCenterY > CenterMaxY then
			CenterMaxY = ItemCenterY
		end
		if ItemCenterZ > CenterMaxZ then
			CenterMaxZ = ItemCenterZ
		end
	end

	buffer.writef32(NodeBuffer, NodeOffset, MinX)
	buffer.writef32(NodeBuffer, NodeOffset + 4, MinY)
	buffer.writef32(NodeBuffer, NodeOffset + 8, MinZ)
	buffer.writef32(NodeBuffer, NodeOffset + 16, MaxX)
	buffer.writef32(NodeBuffer, NodeOffset + 20, MaxY)
	buffer.writef32(NodeBuffer, NodeOffset + 24, MaxZ)

	if StartIdx >= EndIdx or NextAllocatedBytes + (NODE_STRIDE * 2) > MAX_NODE_BYTES then
		const LeafEntityId = buffer.readu32(ItemIndicesBuffer, (StartIdx - 1) * 4) :: number
		buffer.writeu32(NodeBuffer, NodeOffset + 12, LeafEntityId)
		buffer.writeu32(NodeBuffer, NodeOffset + 28, 0)
		return NodeOffset, NextAllocatedBytes
	end

	const ExtentX = CenterMaxX - CenterMinX :: number
	const ExtentY = CenterMaxY - CenterMinY :: number
	const ExtentZ = CenterMaxZ - CenterMinZ :: number

	local AxisOffset = 24 :: number
	local SplitPosition = (CenterMinX + CenterMaxX) * 0.5 :: number
	local MaxExtent = ExtentX :: number

	if ExtentY > MaxExtent then
		AxisOffset = 28
		SplitPosition = (CenterMinY + CenterMaxY) * 0.5
		MaxExtent = ExtentY
	end
	if ExtentZ > MaxExtent then
		AxisOffset = 32
		SplitPosition = (CenterMinZ + CenterMaxZ) * 0.5
		MaxExtent = ExtentZ
	end

	local MidIndex = (StartIdx + EndIdx) // 2 :: number
	if MaxExtent > 1e-4 and Depth < SAFE_BALANCED_DEPTH then
		local LeftIndex = StartIdx :: number
		local RightIndex = EndIdx :: number

		while LeftIndex <= RightIndex do
			const LeftEntity = buffer.readu32(ItemIndicesBuffer, (LeftIndex - 1) * 4) :: number
			const CenterValue =
				buffer.readf32(ItemBoundsBuffer, (LeftEntity - 1) * ITEM_BOUNDS_STRIDE + AxisOffset) :: number
			if CenterValue < SplitPosition then
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
	LeftNodeOffset, NextAllocatedBytes = BVHHelper.BuildSubtree(
		NodeBuffer,
		ItemBoundsBuffer,
		ItemIndicesBuffer,
		NextAllocatedBytes,
		StartIdx,
		MidIndex,
		NextDepth
	)

	local RightNodeOffset: number
	RightNodeOffset, NextAllocatedBytes = BVHHelper.BuildSubtree(
		NodeBuffer,
		ItemBoundsBuffer,
		ItemIndicesBuffer,
		NextAllocatedBytes,
		MidIndex + 1,
		EndIdx,
		NextDepth
	)

	buffer.writeu32(NodeBuffer, NodeOffset + 12, LeftNodeOffset)
	buffer.writeu32(NodeBuffer, NodeOffset + 28, RightNodeOffset)

	return NodeOffset, NextAllocatedBytes
end

--[=[
	Evaluates whether an entity or OOP object matches an ignore filter.
	@param EntityId number -- Target ECS entity ID.
	@param DynObject any -- Bound OOP object reference (or nil).
	@param IgnoredId number -- Single explicit ignored entity ID.
	@param IgnoreFilter any -- Ignore filter (nil, number, OOP object, or table).
	@return boolean -- True if entity/object should be skipped.
]=]
function BVHHelper.IsIgnored(EntityId: number, DynObject: any, IgnoredId: number, IgnoreFilter: any): boolean
	if EntityId > 0 and EntityId == IgnoredId then
		return true
	end
	if IgnoreFilter == nil then
		return false
	end
	if DynObject ~= nil and IgnoreFilter == DynObject then
		return true
	end
	if type(IgnoreFilter) == "table" then
		if EntityId > 0 and IgnoreFilter[EntityId] == true then
			return true
		end
		for _, Item in ipairs(IgnoreFilter) do
			if (EntityId > 0 and Item == EntityId) or (DynObject ~= nil and Item == DynObject) then
				return true
			end
		end
	end
	return false
end

return BVHHelper
