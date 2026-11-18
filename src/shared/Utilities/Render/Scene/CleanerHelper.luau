--!strict
--!native
--!optimize 2

--[=[
	@class CleanerHelper
	Synchronizes visible, unculled client entities from ObjectStorage into the renderer
	culling ECS (RenderECSStorage) ordered strictly from largest part to smallest part.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const RenderRoot = SharedFolder:WaitForChild("Utilities"):WaitForChild("Render")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
const ViewCulling = require(RenderRoot:WaitForChild("Core"):WaitForChild("ViewCulling"))
const CleanerSortHelper = require(script.Parent:WaitForChild("CleanerSortHelper"))

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const SORT_STACK_BYTES = 64 * 8 :: number

export type CleanerState = {
	ObjectStorage: ECSMain.ECSStorage,
	RenderStorage: ECSMain.ECSStorage,
	MaxEntities: number,
	PreviousVisibleCount: number,
	RenderSlotByObjectId: buffer,
	ObjectIdByRenderSlot: buffer,
	SortedObjectIds: buffer,
	SortedSizes: buffer,
	SortStack: buffer,
}

-- Tables --
local CleanerHelper = {}

-- Functions --
-- ============================================================================
-- 1. RENDER ENTITY SLOT REMOVAL & DESCENDING-SIZE CULLING ECS SYNCHRONIZATION
-- ============================================================================

--[=[
	Frees a despawned or culled entity's render slot in place without moving any other render slots.
	@param RenderECSData any -- Render ECS data component interface.
	@param _RenderCounts any -- Render entity count table (unused under stable free-list slots).
	@param RenderSlotByObjectId buffer -- Mapping buffer from ObjectId to RenderSlot.
	@param ObjectIdByRenderSlot buffer -- Mapping buffer from RenderSlot to ObjectId.
	@param ObjectId number -- Client ObjectStorage entity ID being evicted from render storage.
	@param RenderSlot number -- Active client render slot being vacated.
]=]
function CleanerHelper.RemoveRenderEntity(
	RenderECSData: any,
	_RenderCounts: any,
	RenderSlotByObjectId: buffer,
	ObjectIdByRenderSlot: buffer,
	ObjectId: number,
	RenderSlot: number
)
	buffer.writeu32(RenderSlotByObjectId, ObjectId * 4, 0)
	buffer.writeu32(ObjectIdByRenderSlot, RenderSlot * 4, 0)
	RenderECSData.DeleteEntity(RenderSlot)
end

--[=[
	Pre-allocates reusable mapping and sorting buffers for synchronizing ObjectStorage into RenderStorage.
	@param ObjectStorage ECSMain.ECSStorage -- Source replicated client world ECS storage.
	@param RenderStorage ECSMain.ECSStorage -- Target renderer culling ECS storage.
	@return CleanerState -- Initialized zero-allocation cleaner state.
]=]
function CleanerHelper.CreateCleanerState(
	ObjectStorage: ECSMain.ECSStorage,
	RenderStorage: ECSMain.ECSStorage
): CleanerState
	const ObjectPositions = ObjectStorage.PositionData.GetData() :: buffer
	const RenderPositions = RenderStorage.PositionData.GetData() :: buffer
	const MaxEntities = math.min(buffer.len(ObjectPositions), buffer.len(RenderPositions)) // COMPONENT_STRIDE :: number

	return {
		ObjectStorage = ObjectStorage,
		RenderStorage = RenderStorage,
		MaxEntities = MaxEntities,
		PreviousVisibleCount = -1,
		RenderSlotByObjectId = buffer.create((MaxEntities + 1) * 4),
		ObjectIdByRenderSlot = buffer.create((MaxEntities + 1) * 4),
		SortedObjectIds = buffer.create(MaxEntities * 4),
		SortedSizes = buffer.create(MaxEntities * 4),
		SortStack = buffer.create(SORT_STACK_BYTES),
	}
end

--[=[
	Scans `1..ObjectEntityCount` in ObjectStorage, collecting visible unculled entities and tracking sort order.
	@param State CleanerState -- Active cleaner state with pre-allocated scratch buffers.
	@param ObjectEntityCount number -- Clamped source entity high-water count.
	@return (number, boolean) -- Active visible entity count and true when descending-size sort is required.
]=]
function CleanerHelper.GatherVisibleEntities(State: CleanerState, ObjectEntityCount: number): (number, boolean)
	const ObjectStorage = State.ObjectStorage
	const ObjectActiveFlags = ObjectStorage.ECSData.GetActiveFlags() :: buffer
	const ObjectPositions = ObjectStorage.PositionData.GetData() :: buffer
	const ObjectSizes = ObjectStorage.SizeData.GetData() :: buffer
	const ObjectProperties = ObjectStorage.PropertiesData.GetData() :: buffer
	const SortedObjectIds = State.SortedObjectIds :: buffer
	const SortedSizes = State.SortedSizes :: buffer

	local VisibleCount = 0 :: number
	local PreviousSizeScore = math.huge :: number
	local NeedsSort = false :: boolean

	for ObjectId = 1, ObjectEntityCount do
		if buffer.readu8(ObjectActiveFlags, ObjectId - 1) == 0 then
			continue
		end

		const PropReg = buffer.readu32(ObjectProperties, (ObjectId - 1) * PROPERTIES_STRIDE) :: number
		if not ECSMain.IsEntityVisible(PropReg) or ViewCulling.IsEntityCulled(ObjectId, ObjectPositions, ObjectSizes) then
			continue
		end

		const ComponentOffset = (ObjectId - 1) * COMPONENT_STRIDE :: number
		const SizeScore = CleanerSortHelper.ComputeEntitySizeScore(ObjectSizes, ComponentOffset) :: number
		if SizeScore > PreviousSizeScore then
			NeedsSort = true
		end
		PreviousSizeScore = SizeScore

		const WriteOffset = VisibleCount * 4 :: number
		buffer.writeu32(SortedObjectIds, WriteOffset, ObjectId)
		buffer.writef32(SortedSizes, WriteOffset, SizeScore)
		VisibleCount += 1
	end

	return VisibleCount, NeedsSort
end

--[=[
	Copies all 5 ECS component slices for `ObjectId` into `RenderSlot` and clears its source dirty flag.
	@param State CleanerState -- Active cleaner state.
	@param ObjectId number -- 1-based source entity slot in ObjectStorage.
	@param RenderSlot number -- 1-based destination entity slot in RenderStorage.
]=]
function CleanerHelper.CopyEntityToRenderSlot(State: CleanerState, ObjectId: number, RenderSlot: number)
	const ObjectStorage = State.ObjectStorage
	const RenderStorage = State.RenderStorage

	const SourceIndex = ObjectId - 1 :: number
	const TargetIndex = RenderSlot - 1 :: number
	const SourceCompOffset = SourceIndex * COMPONENT_STRIDE :: number
	const TargetCompOffset = TargetIndex * COMPONENT_STRIDE :: number

	buffer.copy(
		RenderStorage.PositionData.GetData(),
		TargetCompOffset,
		ObjectStorage.PositionData.GetData(),
		SourceCompOffset,
		COMPONENT_STRIDE
	)
	buffer.copy(
		RenderStorage.VisualData.GetData(),
		TargetIndex * VISUAL_STRIDE,
		ObjectStorage.VisualData.GetData(),
		SourceIndex * VISUAL_STRIDE,
		VISUAL_STRIDE
	)
	buffer.copy(
		RenderStorage.SizeData.GetData(),
		TargetCompOffset,
		ObjectStorage.SizeData.GetData(),
		SourceCompOffset,
		COMPONENT_STRIDE
	)
	buffer.copy(
		RenderStorage.DirectionsData.GetData(),
		TargetIndex * DIRECTION_STRIDE,
		ObjectStorage.DirectionsData.GetData(),
		SourceIndex * DIRECTION_STRIDE,
		DIRECTION_STRIDE
	)
	buffer.copy(
		RenderStorage.PropertiesData.GetData(),
		TargetIndex * PROPERTIES_STRIDE,
		ObjectStorage.PropertiesData.GetData(),
		SourceIndex * PROPERTIES_STRIDE,
		PROPERTIES_STRIDE
	)
	ObjectStorage.ECSData.ClearDirty(ObjectId)
end

--[=[
	Clears vacated trailing render slots `[StartSlot..EndSlot]` after visible entity count shrinks.
	@param State CleanerState -- Active cleaner state.
	@param StartSlot number -- First vacated 1-based render slot.
	@param EndSlot number -- Last vacated 1-based render slot.
]=]
function CleanerHelper.ReleaseTrailingSlots(State: CleanerState, StartSlot: number, EndSlot: number)
	const RenderSlotByObjectId = State.RenderSlotByObjectId :: buffer
	const ObjectIdByRenderSlot = State.ObjectIdByRenderSlot :: buffer
	const RenderProperties = State.RenderStorage.PropertiesData.GetData() :: buffer

	for Slot = StartSlot, EndSlot do
		const SlotMapOffset = Slot * 4 :: number
		const PrevObjId = buffer.readu32(ObjectIdByRenderSlot, SlotMapOffset) :: number
		if PrevObjId > 0 and buffer.readu32(RenderSlotByObjectId, PrevObjId * 4) == Slot then
			buffer.writeu32(RenderSlotByObjectId, PrevObjId * 4, 0)
		end
		buffer.writeu32(ObjectIdByRenderSlot, SlotMapOffset, 0)
	end

	const TrailingBytes = (EndSlot - StartSlot + 1) * PROPERTIES_STRIDE :: number
	buffer.fill(RenderProperties, (StartSlot - 1) * PROPERTIES_STRIDE, 0, TrailingBytes)
end

--[=[
	Culls ObjectStorage entities and synchronizes RenderStorage densely ordered from biggest part (slot 1)
	down to smallest part (slot VisibleCount), skipping buffer copies for unchanged slot assignments.
	@param State CleanerState -- Active cleaner state.
	@return number -- Total visible entities written into RenderStorage (`1..VisibleCount`).
]=]
function CleanerHelper.SyncRenderStorage(State: CleanerState): number
	const ObjectStorage = State.ObjectStorage
	const RenderStorage = State.RenderStorage
	const ObjectEntityCount = math.clamp(ObjectStorage.ECSData.GetCounts().EntityECSCount, 0, State.MaxEntities) :: number

	local VisibleCount = 0 :: number
	local NeedsSort = false :: boolean
	if ObjectEntityCount > 0 then
		ViewCulling.PrepassDominantOccluder(
			ObjectEntityCount,
			ObjectStorage.PositionData.GetData(),
			ObjectStorage.SizeData.GetData(),
			ObjectStorage.PropertiesData.GetData()
		)
		VisibleCount, NeedsSort = CleanerHelper.GatherVisibleEntities(State, ObjectEntityCount)
	end

	if NeedsSort then
		CleanerSortHelper.SortDescendingBySize(
			State.SortedSizes,
			State.SortedObjectIds,
			VisibleCount,
			State.SortStack
		)
	end

	const PrevVisible = State.PreviousVisibleCount :: number
	if VisibleCount ~= PrevVisible then
		RenderStorage.ECSData.SetEntityCount(VisibleCount)
	end

	const SortedObjectIds = State.SortedObjectIds :: buffer
	const RenderSlotByObjectId = State.RenderSlotByObjectId :: buffer
	const ObjectIdByRenderSlot = State.ObjectIdByRenderSlot :: buffer
	const ObjectDirtyFlags = ObjectStorage.ECSData.GetDirtyFlags() :: buffer

	for RenderSlot = 1, VisibleCount do
		const ObjId = buffer.readu32(SortedObjectIds, (RenderSlot - 1) * 4) :: number
		const SlotMapOffset = RenderSlot * 4 :: number
		const PrevObjId = buffer.readu32(ObjectIdByRenderSlot, SlotMapOffset) :: number
		const SlotChanged = (PrevObjId ~= ObjId) :: boolean

		if SlotChanged then
			if PrevObjId > 0 and buffer.readu32(RenderSlotByObjectId, PrevObjId * 4) == RenderSlot then
				buffer.writeu32(RenderSlotByObjectId, PrevObjId * 4, 0)
			end
			buffer.writeu32(ObjectIdByRenderSlot, SlotMapOffset, ObjId)
			buffer.writeu32(RenderSlotByObjectId, ObjId * 4, RenderSlot)
		end

		if SlotChanged or buffer.readu8(ObjectDirtyFlags, ObjId - 1) ~= 0 then
			CleanerHelper.CopyEntityToRenderSlot(State, ObjId, RenderSlot)
		end
	end

	if PrevVisible > VisibleCount then
		CleanerHelper.ReleaseTrailingSlots(State, VisibleCount + 1, PrevVisible)
	end

	State.PreviousVisibleCount = VisibleCount
	return VisibleCount
end

return CleanerHelper
