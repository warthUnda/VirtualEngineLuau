--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))
const BVHHelper = require(script.Parent.BVHHelper)

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const MAX_ENTITIES = SystemsConfigs.ECSMaxEntities :: number
const STACK_CAPACITY = SystemsConfigs.BVHStackCapacity :: number

const NODE_STRIDE = 32 :: number
const ITEM_BOUNDS_STRIDE = 36 :: number
const CACHED_STATE_STRIDE = 28 :: number
const MAX_NODE_BYTES = MAX_ENTITIES * 2 * NODE_STRIDE :: number

const FLAG_CAN_COLLIDE = bit32.lshift(1, 1) :: number
const FLAG_ANCHORED = bit32.lshift(1, 3) :: number
const FLAG_HAS_DYNAMIC_ID = bit32.lshift(1, 4) :: number

-- Buffers
const NodeBuffer = buffer.create(MAX_NODE_BYTES) :: buffer
const ItemBoundsBuffer = buffer.create(MAX_ENTITIES * ITEM_BOUNDS_STRIDE) :: buffer
const CachedStateBuffer = buffer.create(MAX_ENTITIES * CACHED_STATE_STRIDE) :: buffer
const ItemIndicesBuffer = buffer.create(MAX_ENTITIES * 4) :: buffer
const DynamicEntitiesBuffer = buffer.create(MAX_ENTITIES * 4) :: buffer
const EntityIsDynamicBuffer = buffer.create(MAX_ENTITIES + 1) :: buffer
const TestedGenBuffer = buffer.create((MAX_ENTITIES + 1) * 4) :: buffer
const TraversalStackBuffer = buffer.create(STACK_CAPACITY * 4) :: buffer

-- Tables --
local BVHState = {
	NodeBuffer = NodeBuffer,
	ItemBoundsBuffer = ItemBoundsBuffer,
	CachedStateBuffer = CachedStateBuffer,
	ItemIndicesBuffer = ItemIndicesBuffer,
	DynamicEntitiesBuffer = DynamicEntitiesBuffer,
	EntityIsDynamicBuffer = EntityIsDynamicBuffer,
	TestedGenBuffer = TestedGenBuffer,
	TraversalStackBuffer = TraversalStackBuffer,
	ActiveStorage = nil :: ECSMain.ECSStorage?,
	AllocatedNodeBytes = 0 :: number,
	DynamicEntityCount = 0 :: number,
	LastBuiltEntityCount = -1 :: number,
	LastDynamicNextId = -1 :: number,
	LastDynamicActiveCount = -1 :: number,
	MutationScanCursor = 1 :: number,
	RayGeneration = 0 :: number,
}

-- Functions --
-- ============================================================================
-- 1. FLAT-BUFFER TREE BUILDER & FRESHNESS SYNCHRONIZATION
-- ============================================================================

--[=[
	Rebuilds the static and dynamic BVH hierarchy over the given ECS storage.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional override ECS storage (used for tests or isolated VM contexts).
]=]
function BVHState.Rebuild(ProvidedStorage: ECSMain.ECSStorage?)
	const Storage = BVHHelper.ResolveStorage(ProvidedStorage)
	if not Storage then
		return
	end

	const EntityCount = math.clamp(Storage.ECSData.GetCounts().EntityECSCount :: number, 0, MAX_ENTITIES) :: number
	BVHState.ActiveStorage = Storage
	BVHState.LastBuiltEntityCount = EntityCount
	BVHState.AllocatedNodeBytes = 0
	BVHState.DynamicEntityCount = 0
	BVHState.MutationScanCursor = 1

	const DynList = Storage.DynamicObjectsList
	BVHState.LastDynamicActiveCount = if DynList then DynList.Counts.ActiveCount else 0
	BVHState.LastDynamicNextId = if DynList then DynList.Counts.NextId else 0

	if EntityCount <= 0 then
		return
	end

	const PositionBuffer = Storage.PositionData.GetData() :: buffer
	const SizeBuffer = Storage.SizeData.GetData() :: buffer
	const DirectionsBuffer = Storage.DirectionsData.GetData() :: buffer
	const PropertiesBuffer = Storage.PropertiesData.GetData() :: buffer
	const StaticBuffer = Storage.ECSData.GetStaticData() :: buffer?

	local StaticItemCount = 0 :: number
	local DynamicCount = 0 :: number

	for EntityId = 1, EntityCount do
		const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
		const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
		const PropRegister = buffer.readu32(PropertiesBuffer, (EntityId - 1) * PROPERTIES_STRIDE) :: number
		const StateOffset = (EntityId - 1) * CACHED_STATE_STRIDE :: number

		const RawSizeX = buffer.readf32(SizeBuffer, CompOffset) :: number
		const RawSizeY = buffer.readf32(SizeBuffer, CompOffset + 4) :: number
		const RawSizeZ = buffer.readf32(SizeBuffer, CompOffset + 8) :: number

		buffer.writef32(CachedStateBuffer, StateOffset, RawSizeX)
		buffer.writef32(CachedStateBuffer, StateOffset + 4, RawSizeY)
		buffer.writef32(CachedStateBuffer, StateOffset + 8, RawSizeZ)
		buffer.writef32(CachedStateBuffer, StateOffset + 12, buffer.readf32(DirectionsBuffer, DirOffset))
		buffer.writef32(CachedStateBuffer, StateOffset + 16, buffer.readf32(DirectionsBuffer, DirOffset + 16))
		buffer.writef32(CachedStateBuffer, StateOffset + 20, buffer.readf32(DirectionsBuffer, DirOffset + 32))
		buffer.writeu32(CachedStateBuffer, StateOffset + 24, PropRegister)

		if PropRegister ~= 0 and not bit32.btest(PropRegister, FLAG_CAN_COLLIDE) then
			buffer.writeu8(EntityIsDynamicBuffer, EntityId, 1)
			continue
		end

		const IsDynamic = (
			bit32.btest(PropRegister, FLAG_HAS_DYNAMIC_ID)
			or (StaticBuffer ~= nil and buffer.readu8(StaticBuffer, EntityId - 1) == 0)
			or (PropRegister ~= 0 and not bit32.btest(PropRegister, FLAG_ANCHORED))
		) :: boolean

		if IsDynamic then
			buffer.writeu8(EntityIsDynamicBuffer, EntityId, 1)
			buffer.writeu32(DynamicEntitiesBuffer, DynamicCount * 4, EntityId)
			DynamicCount += 1
		else
			buffer.writeu8(EntityIsDynamicBuffer, EntityId, 0)
		end

		const PositionX = buffer.readf32(PositionBuffer, CompOffset) :: number
		const PositionY = buffer.readf32(PositionBuffer, CompOffset + 4) :: number
		const PositionZ = buffer.readf32(PositionBuffer, CompOffset + 8) :: number
		const HalfSizeX: number, HalfSizeY: number, HalfSizeZ: number = math.abs(RawSizeX) * 0.5, math.abs(RawSizeY) * 0.5, math.abs(RawSizeZ) * 0.5

		local LookX: number, LookY: number, LookZ: number = buffer.readf32(DirectionsBuffer, DirOffset), buffer.readf32(DirectionsBuffer, DirOffset + 4), buffer.readf32(DirectionsBuffer, DirOffset + 8)
		local UpX: number, UpY: number, UpZ: number = buffer.readf32(DirectionsBuffer, DirOffset + 12), buffer.readf32(DirectionsBuffer, DirOffset + 16), buffer.readf32(DirectionsBuffer, DirOffset + 20)
		local RightX: number, RightY: number, RightZ: number = buffer.readf32(DirectionsBuffer, DirOffset + 24), buffer.readf32(DirectionsBuffer, DirOffset + 28), buffer.readf32(DirectionsBuffer, DirOffset + 32)
		if RightX * RightX + RightY * RightY + RightZ * RightZ < 0.5 then
			LookX, LookY, LookZ = 0, 0, -1
			UpX, UpY, UpZ = 0, 1, 0
			RightX, RightY, RightZ = 1, 0, 0
		end

		const WorldExtentX = math.abs(RightX) * HalfSizeX + math.abs(UpX) * HalfSizeY + math.abs(LookX) * HalfSizeZ :: number
		const WorldExtentY = math.abs(RightY) * HalfSizeX + math.abs(UpY) * HalfSizeY + math.abs(LookY) * HalfSizeZ :: number
		const WorldExtentZ = math.abs(RightZ) * HalfSizeX + math.abs(UpZ) * HalfSizeY + math.abs(LookZ) * HalfSizeZ :: number

		const BoundsOffset = (EntityId - 1) * ITEM_BOUNDS_STRIDE :: number
		buffer.writef32(ItemBoundsBuffer, BoundsOffset, PositionX - WorldExtentX)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 4, PositionY - WorldExtentY)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 8, PositionZ - WorldExtentZ)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 12, PositionX + WorldExtentX)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 16, PositionY + WorldExtentY)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 20, PositionZ + WorldExtentZ)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 24, PositionX)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 28, PositionY)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 32, PositionZ)

		if not IsDynamic then
			StaticItemCount += 1
			buffer.writeu32(ItemIndicesBuffer, (StaticItemCount - 1) * 4, EntityId)
		end
	end

	BVHState.DynamicEntityCount = DynamicCount
	if StaticItemCount > 0 then
		const _, NextBytes = BVHHelper.BuildSubtree(NodeBuffer, ItemBoundsBuffer, ItemIndicesBuffer, 0, 1, StaticItemCount, 0)
		BVHState.AllocatedNodeBytes = NextBytes
	end
end

--[=[
	Ensures the BVH is up-to-date for the current frame/substep and returns the resolved Storage + EntityCount.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional override ECS storage.
	@param SkipNeedsRebuild boolean? -- Whether to bypass mutation freshness checking.
	@return (ECSMain.ECSStorage?, number) -- The active storage and total entity count.
]=]
function BVHState.EnsureFreshAndResolve(ProvidedStorage: ECSMain.ECSStorage?, SkipNeedsRebuild: boolean?): (ECSMain.ECSStorage?, number)
	const Storage = BVHHelper.ResolveStorage(ProvidedStorage)
	if not Storage then
		return nil, 0
	end

	const EntityCount = math.clamp(Storage.ECSData.GetCounts().EntityECSCount :: number, 0, MAX_ENTITIES) :: number
	if not SkipNeedsRebuild then
		local ShouldRebuild: boolean
		ShouldRebuild, BVHState.MutationScanCursor = BVHHelper.NeedsRebuild(
			Storage,
			BVHState.ActiveStorage,
			EntityCount,
			BVHState.LastBuiltEntityCount,
			BVHState.LastDynamicActiveCount,
			BVHState.LastDynamicNextId,
			BVHState.MutationScanCursor,
			CachedStateBuffer,
			EntityIsDynamicBuffer,
			ItemBoundsBuffer
		)
		if ShouldRebuild then
			BVHState.Rebuild(Storage)
		end
	end
	return Storage, EntityCount
end

return BVHState
