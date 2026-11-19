--!strict
--!native
--!optimize 2

--[=[
	@class CleanerHelper
	Synchronizes visible, BVH frustum-culled client entities from ObjectStorage into RenderECSStorage
	ordered strictly front-to-back (`ForwardZ - Radius` ascending) for Early-Z and Tile Hi-Z rejection.
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
const RenderBVHHelper = require(script.Parent:WaitForChild("RenderBVHHelper"))

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const SORT_STACK_BYTES = 64 * 8 :: number

export type CleanerState = {
	ObjectStorage: ECSMain.ECSStorage,
	RenderStorage: ECSMain.ECSStorage,
	RenderBVH: RenderBVHHelper.RenderBVHState,
	MaxEntities: number,
	PreviousVisibleCount: number,
	RenderSlotByObjectId: buffer,
	ObjectIdByRenderSlot: buffer,
	CandidateIds: buffer,
	SortedObjectIds: buffer,
	SortedDepths: buffer,
	SortStack: buffer,
	LastCamCFrame: CFrame?,
	LastCamFOV: number,
	LastPlayerPos: Vector3,
	LastEntityCount: number,
	LastActiveCount: number,
}

-- Tables --
local CleanerHelper = {}

-- Functions --
-- ============================================================================
-- 1. RENDER ENTITY SLOT REMOVAL & BVH FRONT-TO-BACK CULLING SYNCHRONIZATION
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
	Pre-allocates reusable BVH, mapping, and front-to-back sorting buffers for synchronizing ObjectStorage into RenderStorage.
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
		RenderBVH = RenderBVHHelper.CreateState(MaxEntities),
		MaxEntities = MaxEntities,
		PreviousVisibleCount = -1,
		RenderSlotByObjectId = buffer.create((MaxEntities + 1) * 4),
		ObjectIdByRenderSlot = buffer.create((MaxEntities + 1) * 4),
		CandidateIds = buffer.create(MaxEntities * 4),
		SortedObjectIds = buffer.create(MaxEntities * 4),
		SortedDepths = buffer.create(MaxEntities * 4),
		SortStack = buffer.create(SORT_STACK_BYTES),
		LastCamCFrame = nil,
		LastCamFOV = -1,
		LastPlayerPos = Vector3.zero,
		LastEntityCount = -1,
		LastActiveCount = -1,
	}
end

--[=[
	Returns true when camera parameters, player offset, entity counts, dynamic parts, or dirty flags changed
	since the previous cleaner pass, allowing stationary frames to skip culling completely.
	@param State CleanerState -- Active cleaner state.
	@param CamCFrame CFrame -- Current active camera CFrame.
	@param CamFOV number -- Current active camera FOV.
	@param PlayerPos Vector3 -- Current simulated player position.
	@return boolean -- True if a culling/sync pass is required this tick.
]=]
function CleanerHelper.NeedsSync(
	State: CleanerState,
	CamCFrame: CFrame,
	CamFOV: number,
	PlayerPos: Vector3
): boolean
	const ObjectStorage = State.ObjectStorage
	const Counts = ObjectStorage.ECSData.GetCounts()
	const EntityCount = math.clamp(Counts.EntityECSCount :: number, 0, State.MaxEntities) :: number
	const ActiveCount = Counts.ActiveEntityCount :: number

	if
		State.LastCamCFrame ~= CamCFrame
		or State.LastCamFOV ~= CamFOV
		or (State.LastPlayerPos - PlayerPos).Magnitude > 1e-3
		or State.LastEntityCount ~= EntityCount
		or State.LastActiveCount ~= ActiveCount
	then
		State.LastCamCFrame = CamCFrame
		State.LastCamFOV = CamFOV
		State.LastPlayerPos = PlayerPos
		State.LastEntityCount = EntityCount
		State.LastActiveCount = ActiveCount
		return true
	end

	const DirtyFlags = ObjectStorage.ECSData.GetDirtyFlags() :: buffer
	const WordLimit = (EntityCount // 4) * 4 :: number
	for WordOff = 0, WordLimit - 4, 4 do
		if buffer.readu32(DirtyFlags, WordOff) ~= 0 then
			return true
		end
	end
	for Idx = WordLimit, EntityCount - 1 do
		if buffer.readu8(DirtyFlags, Idx) ~= 0 then
			return true
		end
	end

	return false
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
	Queries the visible-entity BVH with active frustum planes, runs candidate dominant-occluder prepass
	and register-cached front-to-back filtering, sorts ascending by depth, and copies changed/dirty slots
	using hoisted ECS buffer pointers.
	@param State CleanerState -- Active cleaner state.
	@return number -- Total visible entities written into RenderStorage (`1..VisibleCount`).
]=]
function CleanerHelper.SyncRenderStorage(State: CleanerState): number
	const ObjectStorage = State.ObjectStorage
	const RenderStorage = State.RenderStorage
	const ObjectEntityCount = math.clamp(ObjectStorage.ECSData.GetCounts().EntityECSCount, 0, State.MaxEntities) :: number

	const ObjActiveFlags = ObjectStorage.ECSData.GetActiveFlags() :: buffer
	const ObjDirtyFlags = ObjectStorage.ECSData.GetDirtyFlags() :: buffer
	const ObjPositions = ObjectStorage.PositionData.GetData() :: buffer
	const ObjSizes = ObjectStorage.SizeData.GetData() :: buffer
	const ObjDirections = ObjectStorage.DirectionsData.GetData() :: buffer
	const ObjVisuals = ObjectStorage.VisualData.GetData() :: buffer
	const ObjProperties = ObjectStorage.PropertiesData.GetData() :: buffer

	local VisibleCount = 0 :: number
	local NeedsSort = false :: boolean
	if ObjectEntityCount > 0 then
		RenderBVHHelper.EnsureFresh(State.RenderBVH, ObjectStorage)
		const CandidateCount = RenderBVHHelper.QueryFrustumCandidates(State.RenderBVH, State.CandidateIds) :: number
		if CandidateCount > 0 then
			ViewCulling.PrepassDominantOccluderCandidates(
				State.CandidateIds, CandidateCount, ObjPositions, ObjSizes, ObjProperties
			)
			VisibleCount, NeedsSort = ViewCulling.FilterCandidatesFrontToBack(
				State.CandidateIds, CandidateCount, ObjActiveFlags,
				ObjPositions, ObjSizes, ObjProperties,
				State.SortedObjectIds, State.SortedDepths
			)
		end
	end

	if NeedsSort then
		CleanerSortHelper.SortAscendingByDepth(State.SortedDepths, State.SortedObjectIds, VisibleCount, State.SortStack)
	end

	const PrevVisible = State.PreviousVisibleCount :: number
	if VisibleCount ~= PrevVisible then
		RenderStorage.ECSData.SetEntityCount(VisibleCount)
	end

	const RenPositions = RenderStorage.PositionData.GetData() :: buffer
	const RenSizes = RenderStorage.SizeData.GetData() :: buffer
	const RenDirections = RenderStorage.DirectionsData.GetData() :: buffer
	const RenVisuals = RenderStorage.VisualData.GetData() :: buffer
	const RenProperties = RenderStorage.PropertiesData.GetData() :: buffer
	const SortedObjectIds = State.SortedObjectIds :: buffer
	const RenderSlotByObjectId = State.RenderSlotByObjectId :: buffer
	const ObjectIdByRenderSlot = State.ObjectIdByRenderSlot :: buffer

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

		if SlotChanged or buffer.readu8(ObjDirtyFlags, ObjId - 1) ~= 0 then
			const SrcIdx = ObjId - 1 :: number
			const DstIdx = RenderSlot - 1 :: number
			const SrcComp = SrcIdx * COMPONENT_STRIDE :: number
			const DstComp = DstIdx * COMPONENT_STRIDE :: number
			buffer.copy(RenPositions, DstComp, ObjPositions, SrcComp, COMPONENT_STRIDE)
			buffer.copy(RenSizes, DstComp, ObjSizes, SrcComp, COMPONENT_STRIDE)
			buffer.copy(RenDirections, DstIdx * DIRECTION_STRIDE, ObjDirections, SrcIdx * DIRECTION_STRIDE, DIRECTION_STRIDE)
			buffer.copy(RenVisuals, DstIdx * VISUAL_STRIDE, ObjVisuals, SrcIdx * VISUAL_STRIDE, VISUAL_STRIDE)
			buffer.copy(RenProperties, DstIdx * PROPERTIES_STRIDE, ObjProperties, SrcIdx * PROPERTIES_STRIDE, PROPERTIES_STRIDE)
			buffer.writeu8(ObjDirtyFlags, SrcIdx, 0)
		end
	end

	if PrevVisible > VisibleCount then
		CleanerHelper.ReleaseTrailingSlots(State, VisibleCount + 1, PrevVisible)
	end
	if ObjectEntityCount > 0 then
		buffer.fill(ObjDirtyFlags, 0, 0, ObjectEntityCount)
	end

	State.PreviousVisibleCount = VisibleCount
	return VisibleCount
end

return CleanerHelper
