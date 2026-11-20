--!strict
--!native
--!optimize 2

--[=[
	@class CleanerSubdivideHelper
	Subdivides oversized axis-aligned Cube and Plane entities during the render-culling pass
	into temporary mean-sized RenderECSStorage sub-parts without mutating ObjectStorage.
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

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const RADIUS_PADDING_FACTOR = SystemsConfigs.CullingRadiusPaddingFactor * SystemsConfigs.CullingPaddingAmount :: number
const FLAG_IS_VISIBLE = bit32.lshift(1, 2) :: number
const VIRTUAL_SUB_BIT = 0x80000000 :: number
const SUB_INDEX_MASK = 0x7FFFFFFF :: number
const PLANE_MAX_AXIS_SPLITS = 6 :: number
const PLANE_TRIGGER_MULT = 3.0 :: number
const CUBE_MAX_AXIS_SPLITS = 2 :: number
const CUBE_TRIGGER_MULT = 12.0 :: number
const AXIS_SPLIT_MULT = 1.5 :: number
const SHAPE_CUBE = 0 :: number
const SHAPE_PLANE = 4 :: number

export type SubdivideState = {
	MaxSubParts: number,
	LastEntityCount: number,
	LastActiveCount: number,
	MeanPartSize: number,
	SubPositions: buffer,
	SubSizes: buffer,
	SubParentIds: buffer,
	MassiveDepths: buffer,
}

-- Tables --
local CleanerSubdivideHelper = {
	VirtualSubBit = VIRTUAL_SUB_BIT,
}

-- Functions --
-- ============================================================================
-- 1. STATE ALLOCATION & O(1) CACHED MEAN PART SIZE
-- ============================================================================

--[=[
	Allocates pre-sized scratch buffers for temporary subdivided render entities.
	@param MaxEntities number -- Maximum render slot capacity.
	@return SubdivideState -- Initialized zero-allocation subdivision state.
]=]
function CleanerSubdivideHelper.CreateState(MaxEntities: number): SubdivideState
	const SafeCap = math.max(1, MaxEntities) :: number
	return {
		MaxSubParts = SafeCap,
		LastEntityCount = -1,
		LastActiveCount = -1,
		MeanPartSize = 8,
		SubPositions = buffer.create(SafeCap * COMPONENT_STRIDE),
		SubSizes = buffer.create(SafeCap * COMPONENT_STRIDE),
		SubParentIds = buffer.create(SafeCap * 4),
		MassiveDepths = buffer.create(SafeCap * 4),
	}
end

--[=[
	Returns the cached arithmetic mean axis size across active visible parts, recomputing only when counts change.
	@param SubState SubdivideState -- Cached subdivision state.
	@param ObjectStorage ECSMain.ECSStorage -- Authoritative client object storage (read-only).
	@param MaxEntities number -- Upper entity scan bound.
	@return number -- Mean axis size in studs.
]=]
function CleanerSubdivideHelper.GetMeanPartSize(
	SubState: SubdivideState,
	ObjectStorage: ECSMain.ECSStorage,
	MaxEntities: number
): number
	const Counts = ObjectStorage.ECSData.GetCounts()
	const EntityCount = math.clamp(Counts.EntityECSCount :: number, 0, MaxEntities) :: number
	const ActiveCount = Counts.ActiveEntityCount :: number
	if EntityCount == SubState.LastEntityCount and ActiveCount == SubState.LastActiveCount then
		return SubState.MeanPartSize
	end

	SubState.LastEntityCount = EntityCount
	SubState.LastActiveCount = ActiveCount
	if EntityCount <= 0 or ActiveCount <= 0 then
		SubState.MeanPartSize = 8
		return 8
	end

	const ActiveFlags = ObjectStorage.ECSData.GetActiveFlags() :: buffer
	const Sizes = ObjectStorage.SizeData.GetData() :: buffer
	const Properties = ObjectStorage.PropertiesData.GetData() :: buffer
	local SumAxes = 0 :: number
	local VisibleTotal = 0 :: number

	for EntityId = 1, EntityCount do
		if buffer.readu8(ActiveFlags, EntityId - 1) == 0 then
			continue
		end
		if not bit32.btest(buffer.readu32(Properties, (EntityId - 1) * PROPERTIES_STRIDE), FLAG_IS_VISIBLE) then
			continue
		end
		const CompOff = (EntityId - 1) * COMPONENT_STRIDE :: number
		SumAxes += math.abs(buffer.readf32(Sizes, CompOff))
			+ math.abs(buffer.readf32(Sizes, CompOff + 4))
			+ math.abs(buffer.readf32(Sizes, CompOff + 8))
		VisibleTotal += 1
	end

	const ComputedMean = if VisibleTotal > 0 then math.max(1, SumAxes / (VisibleTotal * 3)) else 8 :: number
	SubState.MeanPartSize = ComputedMean
	return ComputedMean
end

-- ============================================================================
-- 2. MASSIVE PART FRUSTUM SUBDIVISION & RENDER SLOT POPULATION
-- ============================================================================

--[=[
	Replaces oversized Cube/Plane candidates with frustum-culled mean-sized virtual sub-parts before depth sorting.
	@param SubState SubdivideState -- Subdivision scratch buffers.
	@param ObjectStorage ECSMain.ECSStorage -- Authoritative client object storage (read-only).
	@param BaseVisibleCount number -- Count of visible entities written by FilterCandidatesFrontToBack.
	@param BaseNeedsSort boolean -- Initial sort flag from FilterCandidatesFrontToBack.
	@param SortedObjectIds buffer -- In/out u32 entity or virtual-sub key buffer.
	@param SortedDepths buffer -- In/out f32 front-depth buffer.
	@param ScratchMassiveIds buffer -- Reusable u32 buffer (CandidateIds) for staging massive entity IDs.
	@param MaxEntities number -- Maximum render entity capacity.
	@return (number, boolean) -- Expanded visible render count and updated sort flag.
]=]
function CleanerSubdivideHelper.ExpandMassiveCandidates(
	SubState: SubdivideState, ObjectStorage: ECSMain.ECSStorage,
	BaseVisibleCount: number, BaseNeedsSort: boolean,
	SortedObjectIds: buffer, SortedDepths: buffer, ScratchMassiveIds: buffer, MaxEntities: number
): (number, boolean)
	if BaseVisibleCount <= 0 then
		return 0, BaseNeedsSort
	end

	const MeanSize = CleanerSubdivideHelper.GetMeanPartSize(SubState, ObjectStorage, MaxEntities) :: number
	const PlaneTriggerSize = MeanSize * PLANE_TRIGGER_MULT :: number
	const CubeTriggerSize = MeanSize * CUBE_TRIGGER_MULT :: number
	const AxisSplitMin = MeanSize * AXIS_SPLIT_MULT :: number
	const InvMeanSize = 1 / MeanSize :: number
	const ObjPositions = ObjectStorage.PositionData.GetData() :: buffer
	const ObjSizes = ObjectStorage.SizeData.GetData() :: buffer
	const ObjDirections = ObjectStorage.DirectionsData.GetData() :: buffer
	const ObjProperties = ObjectStorage.PropertiesData.GetData() :: buffer
	const MassiveDepths = SubState.MassiveDepths :: buffer
	local KeptCount = 0 :: number
	local MassiveCount = 0 :: number

	for idx = 0, BaseVisibleCount - 1 do
		const ReadOff = idx * 4 :: number
		const ObjId = buffer.readu32(SortedObjectIds, ReadOff) :: number
		const OrigDepth = buffer.readf32(SortedDepths, ReadOff) :: number
		const ShapeId = bit32.band(bit32.rshift(buffer.readu32(ObjProperties, (ObjId - 1) * PROPERTIES_STRIDE), 13), 7) :: number
		const CompOff = (ObjId - 1) * COMPONENT_STRIDE :: number
		const TriggerLimit = if ShapeId == SHAPE_PLANE then PlaneTriggerSize elseif ShapeId == SHAPE_CUBE then CubeTriggerSize else math.huge :: number
		const IsSubdividable = math.max(math.abs(buffer.readf32(ObjSizes, CompOff)), math.abs(buffer.readf32(ObjSizes, CompOff + 4)), math.abs(buffer.readf32(ObjSizes, CompOff + 8))) > TriggerLimit

		if IsSubdividable then
			const MOff = MassiveCount * 4 :: number
			buffer.writeu32(ScratchMassiveIds, MOff, ObjId)
			buffer.writef32(MassiveDepths, MOff, OrigDepth)
			MassiveCount += 1
		else
			if KeptCount ~= idx then
				const WriteOff = KeptCount * 4 :: number
				buffer.writeu32(SortedObjectIds, WriteOff, ObjId)
				buffer.writef32(SortedDepths, WriteOff, OrigDepth)
			end
			KeptCount += 1
		end
	end

	if MassiveCount == 0 then
		return BaseVisibleCount, BaseNeedsSort
	end

	const OrigX, OrigY, OrigZ, CamLookX, CamLookY, CamLookZ, CamRightX, CamRightY, CamRightZ, CamUpX, CamUpY, CamUpZ, TanX, TanY, NearClip, FarClip =
		ViewCulling.GetFrustumParams()
	const SubPositions, SubSizes, SubParentIds = SubState.SubPositions, SubState.SubSizes, SubState.SubParentIds
	const MaxSubParts = SubState.MaxSubParts :: number
	local OutCount = KeptCount :: number
	local SubCount = 0 :: number

	for m = 0, MassiveCount - 1 do
		const MOff = m * 4 :: number
		const ObjId = buffer.readu32(ScratchMassiveIds, MOff) :: number
		const OrigDepth = buffer.readf32(MassiveDepths, MOff) :: number
		const ShapeId = bit32.band(bit32.rshift(buffer.readu32(ObjProperties, (ObjId - 1) * PROPERTIES_STRIDE), 13), 7) :: number
		const CompOff = (ObjId - 1) * COMPONENT_STRIDE :: number
		const SizeX = math.abs(buffer.readf32(ObjSizes, CompOff)) :: number
		const SizeY = math.abs(buffer.readf32(ObjSizes, CompOff + 4)) :: number
		const SizeZ = math.abs(buffer.readf32(ObjSizes, CompOff + 8)) :: number

		const MaxAxisSplits = if ShapeId == SHAPE_PLANE then PLANE_MAX_AXIS_SPLITS else CUBE_MAX_AXIS_SPLITS :: number
		const SplitsX = if SizeX > AxisSplitMin then math.clamp(math.floor(SizeX * InvMeanSize + 0.5), 1, MaxAxisSplits) else 1 :: number
		const SplitsY = if ShapeId ~= SHAPE_PLANE and SizeY > AxisSplitMin then math.clamp(math.floor(SizeY * InvMeanSize + 0.5), 1, MaxAxisSplits) else 1 :: number
		const SplitsZ = if SizeZ > AxisSplitMin then math.clamp(math.floor(SizeZ * InvMeanSize + 0.5), 1, MaxAxisSplits) else 1 :: number
		const TotalCells = SplitsX * SplitsY * SplitsZ :: number

		if TotalCells <= 1 or OutCount + TotalCells > MaxEntities or SubCount + TotalCells > MaxSubParts then
			if OutCount < MaxEntities then
				const WriteOff = OutCount * 4 :: number
				buffer.writeu32(SortedObjectIds, WriteOff, ObjId)
				buffer.writef32(SortedDepths, WriteOff, OrigDepth)
				OutCount += 1
			end
			continue
		end

		const PosX, PosY, PosZ = buffer.readf32(ObjPositions, CompOff), buffer.readf32(ObjPositions, CompOff + 4), buffer.readf32(ObjPositions, CompOff + 8)
		const DirOff = (ObjId - 1) * DIRECTION_STRIDE :: number
		local LookX, LookY, LookZ = buffer.readf32(ObjDirections, DirOff), buffer.readf32(ObjDirections, DirOff + 4), buffer.readf32(ObjDirections, DirOff + 8)
		local UpX, UpY, UpZ = buffer.readf32(ObjDirections, DirOff + 12), buffer.readf32(ObjDirections, DirOff + 16), buffer.readf32(ObjDirections, DirOff + 20)
		local RightX, RightY, RightZ = buffer.readf32(ObjDirections, DirOff + 24), buffer.readf32(ObjDirections, DirOff + 28), buffer.readf32(ObjDirections, DirOff + 32)
		if RightX * RightX + RightY * RightY + RightZ * RightZ < 0.5 then
			LookX, LookY, LookZ, UpX, UpY, UpZ, RightX, RightY, RightZ = 0, 0, -1, 0, 1, 0, 1, 0, 0
		end

		const SubSX, SubSY, SubSZ = SizeX / SplitsX, SizeY / SplitsY, SizeZ / SplitsZ
		const SubRadius = (SubSX + SubSY + SubSZ) * RADIUS_PADDING_FACTOR :: number
		const StartLX, StartLY, StartLZ = -0.5 * SizeX + 0.5 * SubSX, -0.5 * SizeY + 0.5 * SubSY, -0.5 * SizeZ + 0.5 * SubSZ
		const HollowInterior = (ShapeId == SHAPE_CUBE and SplitsX > 2 and SplitsY > 2 and SplitsZ > 2) :: boolean

		for ix = 0, SplitsX - 1 do
			const OffLX = StartLX + ix * SubSX :: number
			const BaseX, BaseY, BaseZ = PosX + RightX * OffLX, PosY + RightY * OffLX, PosZ + RightZ * OffLX
			const InnerX = (HollowInterior and ix > 0 and ix < SplitsX - 1) :: boolean

			for iy = 0, SplitsY - 1 do
				const OffLY = StartLY + iy * SubSY :: number
				const RowX, RowY, RowZ = BaseX + UpX * OffLY, BaseY + UpY * OffLY, BaseZ + UpZ * OffLY
				const InnerXY = (InnerX and iy > 0 and iy < SplitsY - 1) :: boolean

				for iz = 0, SplitsZ - 1 do
					if InnerXY and iz > 0 and iz < SplitsZ - 1 then
						continue
					end
					const OffLZ = StartLZ + iz * SubSZ :: number
					const SubPX, SubPY, SubPZ = RowX + LookX * OffLZ, RowY + LookY * OffLZ, RowZ + LookZ * OffLZ
					const RelX, RelY, RelZ = SubPX - OrigX, SubPY - OrigY, SubPZ - OrigZ
					const ForwardZ = RelX * CamLookX + RelY * CamLookY + RelZ * CamLookZ :: number
					if ForwardZ + SubRadius < NearClip or ForwardZ - SubRadius > FarClip then
						continue
					end
					const LocalX = RelX * CamRightX + RelY * CamRightY + RelZ * CamRightZ :: number
					const LocalY = RelX * CamUpX + RelY * CamUpY + RelZ * CamUpZ :: number
					if math.abs(LocalX) - SubRadius > ForwardZ * TanX or math.abs(LocalY) - SubRadius > ForwardZ * TanY then
						continue
					end

					const SubCompOff = SubCount * COMPONENT_STRIDE :: number
					buffer.writef32(SubPositions, SubCompOff, SubPX)
					buffer.writef32(SubPositions, SubCompOff + 4, SubPY)
					buffer.writef32(SubPositions, SubCompOff + 8, SubPZ)
					buffer.writef32(SubSizes, SubCompOff, SubSX)
					buffer.writef32(SubSizes, SubCompOff + 4, SubSY)
					buffer.writef32(SubSizes, SubCompOff + 8, SubSZ)
					buffer.writeu32(SubParentIds, SubCount * 4, ObjId)
					SubCount += 1

					const OutOff = OutCount * 4 :: number
					buffer.writeu32(SortedObjectIds, OutOff, bit32.bor(VIRTUAL_SUB_BIT, SubCount))
					buffer.writef32(SortedDepths, OutOff, ForwardZ - SubRadius)
					OutCount += 1
				end
			end
		end
	end

	return OutCount, true
end

--[=[
	Writes a temporary subdivided render entity into RenderECSStorage without touching ObjectStorage.
	@param SubState SubdivideState -- Subdivision scratch buffers.
	@param SortedKey number -- Virtual sub-part key (VIRTUAL_SUB_BIT | 1-based SubIdx).
	@param RenderSlot number -- 1-based target slot in RenderECSStorage.
	@param RenderSlotByObjectId buffer -- Mapping from ObjectId to RenderSlot.
	@param ObjectIdByRenderSlot buffer -- Mapping from RenderSlot to ObjectId.
	@param ObjDirections buffer -- Source ObjectStorage Directions buffer.
	@param ObjVisuals buffer -- Source ObjectStorage Visual buffer.
	@param ObjProperties buffer -- Source ObjectStorage Properties buffer.
	@param RenPositions buffer -- Target RenderStorage Position buffer.
	@param RenSizes buffer -- Target RenderStorage Size buffer.
	@param RenDirections buffer -- Target RenderStorage Directions buffer.
	@param RenVisuals buffer -- Target RenderStorage Visual buffer.
	@param RenProperties buffer -- Target RenderStorage Properties buffer.
]=]
function CleanerSubdivideHelper.WriteVirtualRenderSlot(
	SubState: SubdivideState, SortedKey: number, RenderSlot: number,
	RenderSlotByObjectId: buffer, ObjectIdByRenderSlot: buffer,
	ObjDirections: buffer, ObjVisuals: buffer, ObjProperties: buffer,
	RenPositions: buffer, RenSizes: buffer, RenDirections: buffer, RenVisuals: buffer, RenProperties: buffer
)
	const SlotMapOffset = RenderSlot * 4 :: number
	const PrevObjId = buffer.readu32(ObjectIdByRenderSlot, SlotMapOffset) :: number
	if PrevObjId > 0 then
		if buffer.readu32(RenderSlotByObjectId, PrevObjId * 4) == RenderSlot then
			buffer.writeu32(RenderSlotByObjectId, PrevObjId * 4, 0)
		end
		buffer.writeu32(ObjectIdByRenderSlot, SlotMapOffset, 0)
	end

	const SubIdx = bit32.band(SortedKey, SUB_INDEX_MASK) - 1 :: number
	const SrcIdx = buffer.readu32(SubState.SubParentIds, SubIdx * 4) - 1 :: number
	const SubCompOff = SubIdx * COMPONENT_STRIDE :: number
	const DstIdx = RenderSlot - 1 :: number
	const DstComp = DstIdx * COMPONENT_STRIDE :: number

	buffer.copy(RenPositions, DstComp, SubState.SubPositions, SubCompOff, COMPONENT_STRIDE)
	buffer.copy(RenSizes, DstComp, SubState.SubSizes, SubCompOff, COMPONENT_STRIDE)
	buffer.copy(RenDirections, DstIdx * DIRECTION_STRIDE, ObjDirections, SrcIdx * DIRECTION_STRIDE, DIRECTION_STRIDE)
	buffer.copy(RenVisuals, DstIdx * VISUAL_STRIDE, ObjVisuals, SrcIdx * VISUAL_STRIDE, VISUAL_STRIDE)
	buffer.copy(RenProperties, DstIdx * PROPERTIES_STRIDE, ObjProperties, SrcIdx * PROPERTIES_STRIDE, PROPERTIES_STRIDE)
end

return CleanerSubdivideHelper
