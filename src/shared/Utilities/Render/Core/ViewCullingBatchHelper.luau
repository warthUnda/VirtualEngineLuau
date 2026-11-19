--!strict
--!native
--!optimize 2

--[=[
	@class ViewCullingBatchHelper
	Register-cached batch dominant-occluder prepass and front-to-back candidate filtering
	operating directly over BVH frustum candidate ID buffers.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const PADDING_AMOUNT = SystemsConfigs.CullingPaddingAmount :: number
const RADIUS_PADDING_FACTOR = SystemsConfigs.CullingRadiusPaddingFactor * PADDING_AMOUNT :: number
const NEAR_CLIP = SystemsConfigs.CullingNearClip :: number
const FAR_CLIP = SystemsConfigs.CullingFarClip :: number
const OCCLUDER_INSCRIBED_FACTOR = SystemsConfigs.OccluderInscribedRadiusFactor :: number
const OCCLUDER_MIN_PROJ_RADIUS = SystemsConfigs.OccluderMinProjectedRadius :: number
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const FLAG_IS_VISIBLE = bit32.lshift(1, 2) :: number

-- Tables --
local ViewCullingBatchHelper = {}

-- Functions --
-- ============================================================================
-- 1. CANDIDATE DOMINANT OCCLUDER PREPASS & FRONT-TO-BACK FILTERING
-- ============================================================================

--[=[
	Pre-scans only BVH frustum candidate IDs to select the dominant foreground occluder.
	@return (boolean, number, number, number, number, number) -- HasOccluder, OccFarZ, OccMinX, OccMaxX, OccMinY, OccMaxY.
]=]
function ViewCullingBatchHelper.PrepassCandidates(
	CandidateIds: buffer,
	CandidateCount: number,
	Positions: buffer,
	Sizes: buffer,
	Properties: buffer,
	OrigX: number, OrigY: number, OrigZ: number,
	LookX: number, LookY: number, LookZ: number,
	RightX: number, RightY: number, RightZ: number,
	UpX: number, UpY: number, UpZ: number
): (boolean, number, number, number, number, number)
	local HasOcc = false :: boolean
	local BestRadius = OCCLUDER_MIN_PROJ_RADIUS :: number
	local FarZ, MinX, MaxX, MinY, MaxY = 0, 0, 0, 0, 0

	for idx = 0, CandidateCount - 1 do
		const EntityId = buffer.readu32(CandidateIds, idx * 4) :: number
		if not bit32.btest(buffer.readu32(Properties, (EntityId - 1) * PROPERTIES_STRIDE), FLAG_IS_VISIBLE) then
			continue
		end
		const Offset = (EntityId - 1) * COMPONENT_STRIDE :: number
		const RelX = buffer.readf32(Positions, Offset) - OrigX :: number
		const RelY = buffer.readf32(Positions, Offset + 4) - OrigY :: number
		const RelZ = buffer.readf32(Positions, Offset + 8) - OrigZ :: number
		const ForwardZ = RelX * LookX + RelY * LookY + RelZ * LookZ :: number
		if ForwardZ <= NEAR_CLIP or ForwardZ > FAR_CLIP then
			continue
		end

		const SizeX = buffer.readf32(Sizes, Offset) :: number
		const SizeY = buffer.readf32(Sizes, Offset + 4) :: number
		const SizeZ = buffer.readf32(Sizes, Offset + 8) :: number
		const InvZ = 1 / ForwardZ :: number
		const InscribedRadius = math.min(SizeX, SizeY, SizeZ) * OCCLUDER_INSCRIBED_FACTOR * InvZ :: number
		if InscribedRadius > BestRadius then
			const Radius = (SizeX + SizeY + SizeZ) * RADIUS_PADDING_FACTOR :: number
			const ProjX = (RelX * RightX + RelY * RightY + RelZ * RightZ) * InvZ :: number
			const ProjY = (RelX * UpX + RelY * UpY + RelZ * UpZ) * InvZ :: number
			BestRadius = InscribedRadius
			HasOcc = true
			FarZ = ForwardZ + Radius
			MinX, MaxX = ProjX - InscribedRadius, ProjX + InscribedRadius
			MinY, MaxY = ProjY - InscribedRadius, ProjY + InscribedRadius
		end
	end

	return HasOcc, FarZ, MinX, MaxX, MinY, MaxY
end

--[=[
	Filters BVH frustum candidates using register-cached frustum & guarded occluder tests,
	emitting visible ObjectIds and ascending front-to-back depth keys (ForwardZ - Radius).
	@return (number, boolean) -- VisibleCount and true when ascending depth sort is required.
]=]
function ViewCullingBatchHelper.FilterCandidatesFrontToBack(
	CandidateIds: buffer,
	CandidateCount: number,
	ActiveFlags: buffer,
	Positions: buffer,
	Sizes: buffer,
	Properties: buffer,
	OutObjectIds: buffer,
	OutDepths: buffer,
	OrigX: number, OrigY: number, OrigZ: number,
	LookX: number, LookY: number, LookZ: number,
	RightX: number, RightY: number, RightZ: number,
	UpX: number, UpY: number, UpZ: number,
	TanX: number, TanY: number,
	ActiveOccluder: boolean,
	CurOccFarZ: number,
	CurOccMinX: number, CurOccMaxX: number,
	CurOccMinY: number, CurOccMaxY: number
): (number, boolean)
	local VisibleCount = 0 :: number
	local PrevDepth = -math.huge :: number
	local PrevId = 0 :: number
	local NeedsSort = false :: boolean

	for idx = 0, CandidateCount - 1 do
		const ObjId = buffer.readu32(CandidateIds, idx * 4) :: number
		if buffer.readu8(ActiveFlags, ObjId - 1) == 0 then
			continue
		end
		if not bit32.btest(buffer.readu32(Properties, (ObjId - 1) * PROPERTIES_STRIDE), FLAG_IS_VISIBLE) then
			continue
		end

		const Offset = (ObjId - 1) * COMPONENT_STRIDE :: number
		const RelX = buffer.readf32(Positions, Offset) - OrigX :: number
		const RelY = buffer.readf32(Positions, Offset + 4) - OrigY :: number
		const RelZ = buffer.readf32(Positions, Offset + 8) - OrigZ :: number
		const SizeX = buffer.readf32(Sizes, Offset) :: number
		const SizeY = buffer.readf32(Sizes, Offset + 4) :: number
		const SizeZ = buffer.readf32(Sizes, Offset + 8) :: number

		const Radius = (SizeX + SizeY + SizeZ) * RADIUS_PADDING_FACTOR :: number
		const ForwardZ = RelX * LookX + RelY * LookY + RelZ * LookZ :: number
		if ForwardZ + Radius < NEAR_CLIP or ForwardZ - Radius > FAR_CLIP then
			continue
		end

		const LocalX = RelX * RightX + RelY * RightY + RelZ * RightZ :: number
		const LocalY = RelX * UpX + RelY * UpY + RelZ * UpZ :: number
		if math.abs(LocalX) - Radius > ForwardZ * TanX or math.abs(LocalY) - Radius > ForwardZ * TanY then
			continue
		end

		const FrontDepth = ForwardZ - Radius :: number
		if ActiveOccluder and FrontDepth > CurOccFarZ then
			const InvZ = 1 / math.max(NEAR_CLIP, ForwardZ) :: number
			const ProjRadius = Radius * InvZ :: number
			const ProjX = LocalX * InvZ :: number
			const ProjY = LocalY * InvZ :: number
			if
				ProjX - ProjRadius >= CurOccMinX
				and ProjX + ProjRadius <= CurOccMaxX
				and ProjY - ProjRadius >= CurOccMinY
				and ProjY + ProjRadius <= CurOccMaxY
			then
				continue
			end
		end

		if FrontDepth < PrevDepth or (FrontDepth == PrevDepth and ObjId < PrevId) then
			NeedsSort = true
		end
		PrevDepth = FrontDepth
		PrevId = ObjId

		const WriteOffset = VisibleCount * 4 :: number
		buffer.writeu32(OutObjectIds, WriteOffset, ObjId)
		buffer.writef32(OutDepths, WriteOffset, FrontDepth)
		VisibleCount += 1
	end

	return VisibleCount, NeedsSort
end

return ViewCullingBatchHelper
