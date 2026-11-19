--!strict
--!native
--!optimize 2

--[=[
	@class RenderBVHHelper
	Visible-entity spatial BVH acceleration structure for client render frustum culling.
	Reuses BVHSubtreeBuilder to index all active visible static parts (including non-collidable parts)
	and traverses the flat 32-byte node hierarchy using exact 6-plane AABB p-vertex frustum tests.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const UtilitiesFolder = SharedFolder:WaitForChild("Utilities")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
const BVHSubtreeBuilder = require(UtilitiesFolder:WaitForChild("BVH"):WaitForChild("BVHSubtreeBuilder"))
const ViewCulling = require(UtilitiesFolder:WaitForChild("Render"):WaitForChild("Core"):WaitForChild("ViewCulling"))

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const STACK_CAPACITY = SystemsConfigs.BVHStackCapacity :: number
const NODE_STRIDE = 32 :: number
const ITEM_BOUNDS_STRIDE = 24 :: number
const FLAG_IS_VISIBLE = bit32.lshift(1, 2) :: number
const FLAG_ANCHORED = bit32.lshift(1, 3) :: number
const FLAG_HAS_DYNAMIC_ID = bit32.lshift(1, 4) :: number

export type RenderBVHState = {
	MaxEntities: number,
	NodeBuffer: buffer,
	ItemBoundsBuffer: buffer,
	ItemIndicesBuffer: buffer,
	DynamicVisibleIds: buffer,
	StaticMembership: buffer,
	TraversalStack: buffer,
	AllocatedNodeBytes: number,
	DynamicVisibleCount: number,
	LastEntityCount: number,
	LastActiveCount: number,
}

-- Tables --
local RenderBVHHelper = {}

-- Functions --
-- ============================================================================
-- 1. VISIBLE-ENTITY BVH CONSTRUCTION & 6-PLANE FRUSTUM TRAVERSAL
-- ============================================================================

--[=[
	Allocates reusable flat buffers for a visible-entity render BVH sized to MaxEntities.
	@param MaxEntities number -- Maximum entity capacity of the bound ECS storage.
	@return RenderBVHState -- Pre-allocated zero-runtime-allocation render BVH state.
]=]
function RenderBVHHelper.CreateState(MaxEntities: number): RenderBVHState
	const SafeCap = math.max(1, MaxEntities) :: number
	return {
		MaxEntities = SafeCap,
		NodeBuffer = buffer.create(SafeCap * 2 * NODE_STRIDE),
		ItemBoundsBuffer = buffer.create(SafeCap * ITEM_BOUNDS_STRIDE),
		ItemIndicesBuffer = buffer.create(SafeCap * 4),
		DynamicVisibleIds = buffer.create(SafeCap * 4),
		StaticMembership = buffer.create(SafeCap + 1),
		TraversalStack = buffer.create(STACK_CAPACITY * 4),
		AllocatedNodeBytes = 0,
		DynamicVisibleCount = 0,
		LastEntityCount = -1,
		LastActiveCount = -1,
	}
end

--[=[
	Rebuilds the render BVH over all active visible entities in ObjectStorage (ignoring CanCollide).
	Static anchored entities enter the flat binary tree; dynamic/unanchored entities populate DynamicVisibleIds.
	@param State RenderBVHState -- Target render BVH state.
	@param ObjectStorage ECSMain.ECSStorage -- Source world ECS storage.
]=]
function RenderBVHHelper.Rebuild(State: RenderBVHState, ObjectStorage: ECSMain.ECSStorage)
	const Counts = ObjectStorage.ECSData.GetCounts()
	const EntityCount = math.clamp(Counts.EntityECSCount :: number, 0, State.MaxEntities) :: number
	State.LastEntityCount = EntityCount
	State.LastActiveCount = Counts.ActiveEntityCount :: number
	State.AllocatedNodeBytes = 0
	State.DynamicVisibleCount = 0

	if EntityCount <= 0 or Counts.ActiveEntityCount <= 0 then
		return
	end

	const ActiveFlags = ObjectStorage.ECSData.GetActiveFlags() :: buffer
	const Positions = ObjectStorage.PositionData.GetData() :: buffer
	const Sizes = ObjectStorage.SizeData.GetData() :: buffer
	const Directions = ObjectStorage.DirectionsData.GetData() :: buffer
	const Properties = ObjectStorage.PropertiesData.GetData() :: buffer
	const StaticData = ObjectStorage.ECSData.GetStaticData() :: buffer?
	const ItemBounds = State.ItemBoundsBuffer :: buffer
	const ItemIndices = State.ItemIndicesBuffer :: buffer
	const DynamicIds = State.DynamicVisibleIds :: buffer
	const StaticMembership = State.StaticMembership :: buffer

	local StaticCount = 0 :: number
	local DynamicCount = 0 :: number

	for EntityId = 1, EntityCount do
		if buffer.readu8(ActiveFlags, EntityId - 1) == 0 then
			buffer.writeu8(StaticMembership, EntityId, 0)
			continue
		end

		const PropReg = buffer.readu32(Properties, (EntityId - 1) * PROPERTIES_STRIDE) :: number
		if not bit32.btest(PropReg, FLAG_IS_VISIBLE) then
			buffer.writeu8(StaticMembership, EntityId, 0)
			continue
		end

		const IsDynamic = (
			bit32.btest(PropReg, FLAG_HAS_DYNAMIC_ID)
			or (StaticData ~= nil and buffer.readu8(StaticData, EntityId - 1) == 0)
		) :: boolean

		if IsDynamic then
			buffer.writeu8(StaticMembership, EntityId, 2)
			buffer.writeu32(DynamicIds, DynamicCount * 4, EntityId)
			DynamicCount += 1
			continue
		end

		buffer.writeu8(StaticMembership, EntityId, 1)
		const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
		const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
		const PosX = buffer.readf32(Positions, CompOffset) :: number
		const PosY = buffer.readf32(Positions, CompOffset + 4) :: number
		const PosZ = buffer.readf32(Positions, CompOffset + 8) :: number
		const HalfX = math.abs(buffer.readf32(Sizes, CompOffset)) * 0.5 :: number
		const HalfY = math.abs(buffer.readf32(Sizes, CompOffset + 4)) * 0.5 :: number
		const HalfZ = math.abs(buffer.readf32(Sizes, CompOffset + 8)) * 0.5 :: number

		local LookX = buffer.readf32(Directions, DirOffset) :: number
		local LookY = buffer.readf32(Directions, DirOffset + 4) :: number
		local LookZ = buffer.readf32(Directions, DirOffset + 8) :: number
		local UpX = buffer.readf32(Directions, DirOffset + 12) :: number
		local UpY = buffer.readf32(Directions, DirOffset + 16) :: number
		local UpZ = buffer.readf32(Directions, DirOffset + 20) :: number
		local RightX = buffer.readf32(Directions, DirOffset + 24) :: number
		local RightY = buffer.readf32(Directions, DirOffset + 28) :: number
		local RightZ = buffer.readf32(Directions, DirOffset + 32) :: number
		if RightX * RightX + RightY * RightY + RightZ * RightZ < 0.5 then
			LookX, LookY, LookZ = 0, 0, -1
			UpX, UpY, UpZ = 0, 1, 0
			RightX, RightY, RightZ = 1, 0, 0
		end

		const ExtX = math.abs(RightX) * HalfX + math.abs(UpX) * HalfY + math.abs(LookX) * HalfZ :: number
		const ExtY = math.abs(RightY) * HalfX + math.abs(UpY) * HalfY + math.abs(LookY) * HalfZ :: number
		const ExtZ = math.abs(RightZ) * HalfX + math.abs(UpZ) * HalfY + math.abs(LookZ) * HalfZ :: number

		const BoundsOffset = (EntityId - 1) * ITEM_BOUNDS_STRIDE :: number
		buffer.writef32(ItemBounds, BoundsOffset, PosX - ExtX)
		buffer.writef32(ItemBounds, BoundsOffset + 4, PosY - ExtY)
		buffer.writef32(ItemBounds, BoundsOffset + 8, PosZ - ExtZ)
		buffer.writef32(ItemBounds, BoundsOffset + 12, PosX + ExtX)
		buffer.writef32(ItemBounds, BoundsOffset + 16, PosY + ExtY)
		buffer.writef32(ItemBounds, BoundsOffset + 20, PosZ + ExtZ)

		StaticCount += 1
		buffer.writeu32(ItemIndices, (StaticCount - 1) * 4, EntityId)
	end

	State.DynamicVisibleCount = DynamicCount
	if StaticCount > 0 then
		const _, NextBytes = BVHSubtreeBuilder.BuildSubtree(
			State.NodeBuffer, ItemBounds, ItemIndices, 0, 1, StaticCount, 0
		)
		State.AllocatedNodeBytes = NextBytes
	end
end

--[=[
	Checks if the render BVH requires rebuilding due to entity count, active count, or dirty static flags.
	@param State RenderBVHState -- Render BVH state.
	@param ObjectStorage ECSMain.ECSStorage -- Source world ECS storage.
	@return boolean -- True if any entity was dirty or tree was rebuilt.
]=]
function RenderBVHHelper.EnsureFresh(State: RenderBVHState, ObjectStorage: ECSMain.ECSStorage): boolean
	const Counts = ObjectStorage.ECSData.GetCounts()
	const EntityCount = math.clamp(Counts.EntityECSCount :: number, 0, State.MaxEntities) :: number
	const ActiveCount = Counts.ActiveEntityCount :: number

	if EntityCount ~= State.LastEntityCount or ActiveCount ~= State.LastActiveCount then
		RenderBVHHelper.Rebuild(State, ObjectStorage)
		return true
	end

	const DirtyFlags = ObjectStorage.ECSData.GetDirtyFlags() :: buffer
	const Properties = ObjectStorage.PropertiesData.GetData() :: buffer
	const StaticMembership = State.StaticMembership :: buffer
	const DynamicIds = State.DynamicVisibleIds :: buffer
	local DynamicCount = State.DynamicVisibleCount :: number
	local AnyDirty = false :: boolean
	local StaticMutated = false :: boolean

	for EntityId = 1, EntityCount do
		if buffer.readu8(DirtyFlags, EntityId - 1) ~= 0 then
			AnyDirty = true
			const MemberKind = buffer.readu8(StaticMembership, EntityId) :: number
			if MemberKind == 1 then
				const PropReg = buffer.readu32(Properties, (EntityId - 1) * PROPERTIES_STRIDE) :: number
				const CanDemote = (not bit32.btest(PropReg, FLAG_ANCHORED)) or bit32.btest(PropReg, FLAG_HAS_DYNAMIC_ID)
				if CanDemote and DynamicCount < 64 then
					buffer.writeu8(StaticMembership, EntityId, 2)
					buffer.writeu32(DynamicIds, DynamicCount * 4, EntityId)
					DynamicCount += 1
				else
					StaticMutated = true
					break
				end
			elseif MemberKind == 0 then
				StaticMutated = true
				break
			end
		end
	end
	State.DynamicVisibleCount = DynamicCount

	if StaticMutated then
		RenderBVHHelper.Rebuild(State, ObjectStorage)
	end
	return AnyDirty
end

--[=[
	Traverses the render BVH against the 6 active ViewCulling frustum planes (exact p-vertex AABB test)
	and writes all potentially visible entity IDs (static tree hits + dynamic visible entities) into OutCandidateIds.
	@param State RenderBVHState -- Active render BVH state.
	@param OutCandidateIds buffer -- Pre-allocated u32 output buffer of 1-based ObjectIds.
	@return number -- Total candidate entity IDs written.
]=]
function RenderBVHHelper.QueryFrustumCandidates(State: RenderBVHState, OutCandidateIds: buffer): number
	const OrigX, OrigY, OrigZ, LookX, LookY, LookZ, RightX, RightY, RightZ, UpX, UpY, UpZ, TanX, TanY, NearClip, FarClip =
		ViewCulling.GetFrustumParams()

	-- 6 inward-pointing frustum plane normals: dot(P - Orig, N) + D >= 0
	const LeftNX = RightX + LookX * TanX :: number
	const LeftNY = RightY + LookY * TanX :: number
	const LeftNZ = RightZ + LookZ * TanX :: number

	const RightNX = -RightX + LookX * TanX :: number
	const RightNY = -RightY + LookY * TanX :: number
	const RightNZ = -RightZ + LookZ * TanX :: number

	const BotNX = UpX + LookX * TanY :: number
	const BotNY = UpY + LookY * TanY :: number
	const BotNZ = UpZ + LookZ * TanY :: number

	const TopNX = -UpX + LookX * TanY :: number
	const TopNY = -UpY + LookY * TanY :: number
	const TopNZ = -UpZ + LookZ * TanY :: number

	const NodeBuffer = State.NodeBuffer :: buffer
	const StaticMembership = State.StaticMembership :: buffer
	const Stack = State.TraversalStack :: buffer
	const MaxOut = buffer.len(OutCandidateIds) // 4 :: number
	local CandidateCount = 0 :: number

	if State.AllocatedNodeBytes > 0 then
		local StackTop = 1 :: number
		buffer.writeu32(Stack, 0, 0)

		while StackTop > 0 do
			StackTop -= 1
			const NodeOff = buffer.readu32(Stack, StackTop * 4) :: number
			const MinX = buffer.readf32(NodeBuffer, NodeOff) - OrigX :: number
			const MinY = buffer.readf32(NodeBuffer, NodeOff + 4) - OrigY :: number
			const MinZ = buffer.readf32(NodeBuffer, NodeOff + 8) - OrigZ :: number
			const MaxX = buffer.readf32(NodeBuffer, NodeOff + 16) - OrigX :: number
			const MaxY = buffer.readf32(NodeBuffer, NodeOff + 20) - OrigY :: number
			const MaxZ = buffer.readf32(NodeBuffer, NodeOff + 24) - OrigZ :: number

			-- Near plane: dot(P - Orig, Look) >= NearClip
			if (if LookX >= 0 then MaxX else MinX) * LookX + (if LookY >= 0 then MaxY else MinY) * LookY + (if LookZ >= 0 then MaxZ else MinZ) * LookZ < NearClip then
				continue
			end
			-- Far plane: dot(P - Orig, Look) <= FarClip (using n-vertex for -Look)
			if (if LookX >= 0 then MinX else MaxX) * LookX + (if LookY >= 0 then MinY else MaxY) * LookY + (if LookZ >= 0 then MinZ else MaxZ) * LookZ > FarClip then
				continue
			end
			-- Left, Right, Bottom, Top planes (p-vertex dot >= 0)
			if (if LeftNX >= 0 then MaxX else MinX) * LeftNX + (if LeftNY >= 0 then MaxY else MinY) * LeftNY + (if LeftNZ >= 0 then MaxZ else MinZ) * LeftNZ < 0 then
				continue
			end
			if (if RightNX >= 0 then MaxX else MinX) * RightNX + (if RightNY >= 0 then MaxY else MinY) * RightNY + (if RightNZ >= 0 then MaxZ else MinZ) * RightNZ < 0 then
				continue
			end
			if (if BotNX >= 0 then MaxX else MinX) * BotNX + (if BotNY >= 0 then MaxY else MinY) * BotNY + (if BotNZ >= 0 then MaxZ else MinZ) * BotNZ < 0 then
				continue
			end
			if (if TopNX >= 0 then MaxX else MinX) * TopNX + (if TopNY >= 0 then MaxY else MinY) * TopNY + (if TopNZ >= 0 then MaxZ else MinZ) * TopNZ < 0 then
				continue
			end

			const RightOff = buffer.readu32(NodeBuffer, NodeOff + 28) :: number
			if RightOff == 0 then
				const LeafId = buffer.readu32(NodeBuffer, NodeOff + 12) :: number
				if buffer.readu8(StaticMembership, LeafId) == 1 and CandidateCount < MaxOut then
					buffer.writeu32(OutCandidateIds, CandidateCount * 4, LeafId)
					CandidateCount += 1
				end
			elseif StackTop + 2 <= STACK_CAPACITY then
				buffer.writeu32(Stack, StackTop * 4, buffer.readu32(NodeBuffer, NodeOff + 12))
				buffer.writeu32(Stack, (StackTop + 1) * 4, RightOff)
				StackTop += 2
			end
		end
	end

	const DynamicCount = State.DynamicVisibleCount :: number
	if DynamicCount > 0 then
		const Remaining = math.min(DynamicCount, MaxOut - CandidateCount) :: number
		if Remaining > 0 then
			buffer.copy(OutCandidateIds, CandidateCount * 4, State.DynamicVisibleIds, 0, Remaining * 4)
			CandidateCount += Remaining
		end
	end

	return CandidateCount
end

return RenderBVHHelper
