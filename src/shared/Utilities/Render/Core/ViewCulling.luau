--!strict
--!native
--!optimize 2

--[=[
	@class ViewCulling
	Frustum plane calculation, dominant foreground occluder prepass, single-entity culling,
	and facade delegating BVH candidate filtering to ViewCullingBatchHelper.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ViewObserverCodec = require(script.Parent.ViewObserverCodec)
const ViewCullingBatchHelper = require(script.Parent.ViewCullingBatchHelper)
const CameraStore = if RunService:IsClient()
	then require(
		ReplicatedStorage:WaitForChild("Shared")
			:WaitForChild("Utilities")
			:WaitForChild("Render")
			:WaitForChild("Camera")
			:WaitForChild("CameraStore")
	)
	else nil

-- Configs --
const PADDING_AMOUNT = SystemsConfigs.CullingPaddingAmount :: number
const WIDTH = SystemsConfigs.RenderWidth :: number
const HEIGHT = SystemsConfigs.RenderHeight :: number
const ASPECT_RATIO = WIDTH / HEIGHT :: number
const BASE_TAN_Y = SystemsConfigs.CullingBaseTanY * PADDING_AMOUNT :: number
const BASE_TAN_X = BASE_TAN_Y * ASPECT_RATIO :: number
const BASE_BACK_PADDING = SystemsConfigs.CullingBaseBackPadding * PADDING_AMOUNT :: number
const RADIUS_PADDING_FACTOR = SystemsConfigs.CullingRadiusPaddingFactor * PADDING_AMOUNT :: number
const NEAR_CLIP = SystemsConfigs.CullingNearClip :: number
const FAR_CLIP = SystemsConfigs.CullingFarClip :: number
const OCCLUDER_INSCRIBED_FACTOR = SystemsConfigs.OccluderInscribedRadiusFactor :: number
const OCCLUDER_MIN_PROJ_RADIUS = SystemsConfigs.OccluderMinProjectedRadius :: number
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const DEFAULT_CAMERA_FOV = SystemsConfigs.DefaultCameraFOV :: number
const FLAG_IS_VISIBLE = bit32.lshift(1, 2) :: number

-- Variables --
local ViewOriginX, ViewOriginY, ViewOriginZ = 0 :: number, 0 :: number, 0 :: number
local ViewRightX, ViewRightY, ViewRightZ = 1 :: number, 0 :: number, 0 :: number
local ViewUpX, ViewUpY, ViewUpZ = 0 :: number, 1 :: number, 0 :: number
local ViewLookX, ViewLookY, ViewLookZ = 0 :: number, 0 :: number, -1 :: number
local ViewTanX = BASE_TAN_X :: number
local ViewTanY = BASE_TAN_Y :: number
local HasOccluder = false :: boolean
local OccFarZ = 0 :: number
local OccMinX, OccMaxX = 0 :: number, 0 :: number
local OccMinY, OccMaxY = 0 :: number, 0 :: number

-- Tables --
local ViewCulling = {
	ObserverPayloadBytes = ViewObserverCodec.ObserverPayloadBytes,
	GetObserverHead = ViewObserverCodec.GetObserverHead,
	ComputeBackPadding = ViewObserverCodec.ComputeBackPadding,
	PackClientObserverState = ViewObserverCodec.PackClientObserverState,
	StepObserverSync = ViewObserverCodec.StepObserverSync,
}

-- Functions --
-- ============================================================================
-- 1. FRUSTUM STATE UPDATES & PLANE PARAMETER ACCESSORS
-- ============================================================================

function ViewCulling.UpdateObserverFromVectors(
	OriginX: number, OriginY: number, OriginZ: number,
	LookX: number, LookY: number, LookZ: number,
	UpX: number, UpY: number, UpZ: number,
	RightX: number, RightY: number, RightZ: number,
	ExtraBackPadding: number, FovDegrees: number
)
	const FovScale = (if FovDegrees > 0 then FovDegrees else DEFAULT_CAMERA_FOV) / 70 :: number
	ViewTanY = BASE_TAN_Y * FovScale
	ViewTanX = ViewTanY * ASPECT_RATIO

	const TotalBackPadding = BASE_BACK_PADDING + math.max(0, ExtraBackPadding) :: number
	ViewOriginX = OriginX - LookX * TotalBackPadding
	ViewOriginY = OriginY - LookY * TotalBackPadding
	ViewOriginZ = OriginZ - LookZ * TotalBackPadding

	ViewRightX, ViewRightY, ViewRightZ = RightX, RightY, RightZ
	ViewUpX, ViewUpY, ViewUpZ = UpX, UpY, UpZ
	ViewLookX, ViewLookY, ViewLookZ = LookX, LookY, LookZ
	HasOccluder = false
end

function ViewCulling.GetFrustumParams(): (
	number, number, number,
	number, number, number,
	number, number, number,
	number, number, number,
	number, number, number, number
)
	return ViewOriginX, ViewOriginY, ViewOriginZ,
		ViewLookX, ViewLookY, ViewLookZ,
		ViewRightX, ViewRightY, ViewRightZ,
		ViewUpX, ViewUpY, ViewUpZ,
		ViewTanX, ViewTanY, NEAR_CLIP, FAR_CLIP
end

function ViewCulling.UpdateClientView(PlayerPosition: Vector3)
	if not CameraStore then
		return
	end
	const CamTable = CameraStore.GetCameraTable()
	const CamCFrame = CamTable.CameraCFrame :: CFrame
	const CamPos, Look, Up, Right = CamCFrame.Position, CamCFrame.LookVector, CamCFrame.UpVector, CamCFrame.RightVector
	ViewCulling.UpdateObserverFromVectors(
		CamPos.X, CamPos.Y, CamPos.Z, Look.X, Look.Y, Look.Z, Up.X, Up.Y, Up.Z, Right.X, Right.Y, Right.Z,
		ViewObserverCodec.ComputeBackPadding(CamPos, PlayerPosition), CamTable.CameraFOV or DEFAULT_CAMERA_FOV
	)
end

function ViewCulling.UpdateDynamicView(Head: BasePart?)
	if CameraStore then
		const CamTable = CameraStore.GetCameraTable()
		const CamCFrame = CamTable.CameraCFrame :: CFrame
		const CamPos, Look, Up, Right = CamCFrame.Position, CamCFrame.LookVector, CamCFrame.UpVector, CamCFrame.RightVector
		const ExtraBackPadding = if Head and Head.Parent then (CamPos - Head.Position).Magnitude * PADDING_AMOUNT else 0 :: number
		ViewCulling.UpdateObserverFromVectors(
			CamPos.X, CamPos.Y, CamPos.Z, Look.X, Look.Y, Look.Z, Up.X, Up.Y, Up.Z, Right.X, Right.Y, Right.Z,
			ExtraBackPadding, CamTable.CameraFOV or DEFAULT_CAMERA_FOV
		)
		return
	end
	if not Head then
		return
	end
	const HeadPos, HeadCF = Head.Position, Head.CFrame
	const Look, Up, Right = HeadCF.LookVector, HeadCF.UpVector, HeadCF.RightVector
	ViewCulling.UpdateObserverFromVectors(
		HeadPos.X, HeadPos.Y, HeadPos.Z, Look.X, Look.Y, Look.Z, Up.X, Up.Y, Up.Z, Right.X, Right.Y, Right.Z, 0, DEFAULT_CAMERA_FOV
	)
end

-- ============================================================================
-- 2. OCCLUDER PREPASS, BVH BATCH DELEGATION & SINGLE-ENTITY CULLING
-- ============================================================================

function ViewCulling.PrepassDominantOccluder(EntityCount: number, Positions: buffer, Sizes: buffer, Properties: buffer)
	HasOccluder = false
	local BestInscribedRadius = OCCLUDER_MIN_PROJ_RADIUS :: number
	const OrigX, OrigY, OrigZ = ViewOriginX, ViewOriginY, ViewOriginZ
	const LookX, LookY, LookZ = ViewLookX, ViewLookY, ViewLookZ
	const RightX, RightY, RightZ = ViewRightX, ViewRightY, ViewRightZ
	const UpX, UpY, UpZ = ViewUpX, ViewUpY, ViewUpZ

	for EntityIndex = 1, EntityCount do
		if not bit32.btest(buffer.readu32(Properties, (EntityIndex - 1) * PROPERTIES_STRIDE), FLAG_IS_VISIBLE) then
			continue
		end
		const Offset = (EntityIndex - 1) * COMPONENT_STRIDE :: number
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
		if InscribedRadius > BestInscribedRadius then
			const Radius = (SizeX + SizeY + SizeZ) * RADIUS_PADDING_FACTOR :: number
			const ProjX = (RelX * RightX + RelY * RightY + RelZ * RightZ) * InvZ :: number
			const ProjY = (RelX * UpX + RelY * UpY + RelZ * UpZ) * InvZ :: number
			BestInscribedRadius = InscribedRadius
			HasOccluder = true
			OccFarZ = ForwardZ + Radius
			OccMinX, OccMaxX = ProjX - InscribedRadius, ProjX + InscribedRadius
			OccMinY, OccMaxY = ProjY - InscribedRadius, ProjY + InscribedRadius
		end
	end
end

function ViewCulling.PrepassDominantOccluderCandidates(
	CandidateIds: buffer, CandidateCount: number, Positions: buffer, Sizes: buffer, Properties: buffer
)
	HasOccluder, OccFarZ, OccMinX, OccMaxX, OccMinY, OccMaxY = ViewCullingBatchHelper.PrepassCandidates(
		CandidateIds, CandidateCount, Positions, Sizes, Properties,
		ViewOriginX, ViewOriginY, ViewOriginZ,
		ViewLookX, ViewLookY, ViewLookZ,
		ViewRightX, ViewRightY, ViewRightZ,
		ViewUpX, ViewUpY, ViewUpZ
	)
end

function ViewCulling.FilterCandidatesFrontToBack(
	CandidateIds: buffer, CandidateCount: number, ActiveFlags: buffer,
	Positions: buffer, Sizes: buffer, Properties: buffer,
	OutObjectIds: buffer, OutDepths: buffer
): (number, boolean)
	return ViewCullingBatchHelper.FilterCandidatesFrontToBack(
		CandidateIds, CandidateCount, ActiveFlags, Positions, Sizes, Properties, OutObjectIds, OutDepths,
		ViewOriginX, ViewOriginY, ViewOriginZ,
		ViewLookX, ViewLookY, ViewLookZ,
		ViewRightX, ViewRightY, ViewRightZ,
		ViewUpX, ViewUpY, ViewUpZ,
		ViewTanX, ViewTanY, HasOccluder, OccFarZ, OccMinX, OccMaxX, OccMinY, OccMaxY
	)
end

function ViewCulling.IsEntityCulled(EntityIndex: number, Positions: buffer, Sizes: buffer): boolean
	const Offset = (EntityIndex - 1) * COMPONENT_STRIDE :: number
	if Offset < 0 or Offset + COMPONENT_STRIDE > buffer.len(Positions) or Offset + COMPONENT_STRIDE > buffer.len(Sizes) then
		return true
	end
	const RelX = buffer.readf32(Positions, Offset) - ViewOriginX :: number
	const RelY = buffer.readf32(Positions, Offset + 4) - ViewOriginY :: number
	const RelZ = buffer.readf32(Positions, Offset + 8) - ViewOriginZ :: number
	const SizeX = buffer.readf32(Sizes, Offset) :: number
	const SizeY = buffer.readf32(Sizes, Offset + 4) :: number
	const SizeZ = buffer.readf32(Sizes, Offset + 8) :: number

	const Radius = (SizeX + SizeY + SizeZ) * RADIUS_PADDING_FACTOR :: number
	const ForwardZ = RelX * ViewLookX + RelY * ViewLookY + RelZ * ViewLookZ :: number
	if ForwardZ + Radius < NEAR_CLIP or ForwardZ - Radius > FAR_CLIP then
		return true
	end

	const LocalX = RelX * ViewRightX + RelY * ViewRightY + RelZ * ViewRightZ :: number
	const LocalY = RelX * ViewUpX + RelY * ViewUpY + RelZ * ViewUpZ :: number
	if math.abs(LocalX) - Radius > ForwardZ * ViewTanX or math.abs(LocalY) - Radius > ForwardZ * ViewTanY then
		return true
	end

	if HasOccluder and ForwardZ - Radius > OccFarZ then
		const InvZ = 1 / math.max(NEAR_CLIP, ForwardZ) :: number
		const ProjRadius = Radius * InvZ :: number
		const ProjX = LocalX * InvZ :: number
		const ProjY = LocalY * InvZ :: number
		if
			ProjX - ProjRadius >= OccMinX
			and ProjX + ProjRadius <= OccMaxX
			and ProjY - ProjRadius >= OccMinY
			and ProjY + ProjRadius <= OccMaxY
		then
			return true
		end
	end

	return false
end

return ViewCulling
