--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))
const ViewObserverCodec = require(script.Parent.ViewObserverCodec)
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
-- 1. FRUSTUM & DOMINANT OCCLUDER CULLING FACADE
-- ============================================================================

--[=[
	Updates the active frustum origin, basis axes, and FOV tangents directly from scalar observer parameters.
	@param OriginX number -- Observer camera origin X.
	@param OriginY number -- Observer camera origin Y.
	@param OriginZ number -- Observer camera origin Z.
	@param LookX number -- Forward basis X.
	@param LookY number -- Forward basis Y.
	@param LookZ number -- Forward basis Z.
	@param UpX number -- Upward basis X.
	@param UpY number -- Upward basis Y.
	@param UpZ number -- Upward basis Z.
	@param RightX number -- Rightward basis X.
	@param RightY number -- Rightward basis Y.
	@param RightZ number -- Rightward basis Z.
	@param ExtraBackPadding number -- Additional backward origin shift.
	@param FovDegrees number -- Active vertical FOV in degrees.
]=]
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

--[=[
	Updates the client frustum directly from CameraStore and simulated player position without requiring a Character.
	@param PlayerPosition Vector3 -- Simulated player world position.
]=]
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

--[=[
	Pulls the frustum origin backward behind the camera based on Head-to-Camera distance (or CameraStore directly).
	@param Head BasePart? -- Optional observer BasePart providing fallback position and orientation.
]=]
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

--[=[
	Pre-scans entities to select the closest dominant foreground occluder before per-entity culling.
	@param EntityCount number -- Number of entities to scan.
	@param Positions buffer -- Positions buffer.
	@param Sizes buffer -- Sizes buffer.
	@param Properties buffer -- Properties buffer.
]=]
function ViewCulling.PrepassDominantOccluder(EntityCount: number, Positions: buffer, Sizes: buffer, Properties: buffer)
	HasOccluder = false
	local BestInscribedRadius = OCCLUDER_MIN_PROJ_RADIUS :: number

	for EntityIndex = 1, EntityCount do
		const PropertiesRegister = buffer.readu32(Properties, (EntityIndex - 1) * PROPERTIES_STRIDE) :: number
		if not ECSMain.IsEntityVisible(PropertiesRegister) then
			continue
		end

		const Offset = (EntityIndex - 1) * COMPONENT_STRIDE :: number
		const RelX = buffer.readf32(Positions, Offset) - ViewOriginX :: number
		const RelY = buffer.readf32(Positions, Offset + 4) - ViewOriginY :: number
		const RelZ = buffer.readf32(Positions, Offset + 8) - ViewOriginZ :: number
		const ForwardZ = RelX * ViewLookX + RelY * ViewLookY + RelZ * ViewLookZ :: number
		if ForwardZ <= NEAR_CLIP or ForwardZ > FAR_CLIP then
			continue
		end

		const SizeX = buffer.readf32(Sizes, Offset) :: number
		const SizeY = buffer.readf32(Sizes, Offset + 4) :: number
		const SizeZ = buffer.readf32(Sizes, Offset + 8) :: number
		const InvZ = 1 / math.max(NEAR_CLIP, ForwardZ) :: number
		const InscribedRadius = math.min(SizeX, SizeY, SizeZ) * OCCLUDER_INSCRIBED_FACTOR * InvZ :: number
		if InscribedRadius > BestInscribedRadius then
			const Radius = (SizeX + SizeY + SizeZ) * RADIUS_PADDING_FACTOR :: number
			const ProjX = (RelX * ViewRightX + RelY * ViewRightY + RelZ * ViewRightZ) * InvZ :: number
			const ProjY = (RelX * ViewUpX + RelY * ViewUpY + RelZ * ViewUpZ) * InvZ :: number
			BestInscribedRadius = InscribedRadius
			HasOccluder = true
			OccFarZ = ForwardZ + Radius
			OccMinX = ProjX - InscribedRadius
			OccMaxX = ProjX + InscribedRadius
			OccMinY = ProjY - InscribedRadius
			OccMaxY = ProjY + InscribedRadius
		end
	end
end

--[=[
	Evaluates whether an entity is outside the view frustum or occluded by a dominant occluder.
	@param EntityIndex number -- 1-based ECS entity index.
	@param Positions buffer -- Positions buffer.
	@param Sizes buffer -- Sizes buffer.
	@return boolean -- True if the entity is culled (not visible).
]=]
function ViewCulling.IsEntityCulled(EntityIndex: number, Positions: buffer, Sizes: buffer): boolean
	const Offset = (EntityIndex - 1) * COMPONENT_STRIDE :: number
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

	const InvZ = 1 / math.max(NEAR_CLIP, ForwardZ) :: number
	const ProjRadius = Radius * InvZ :: number
	const ProjX = LocalX * InvZ :: number
	const ProjY = LocalY * InvZ :: number

	if HasOccluder and ForwardZ - Radius > OccFarZ
		and ProjX - ProjRadius >= OccMinX and ProjX + ProjRadius <= OccMaxX
		and ProjY - ProjRadius >= OccMinY and ProjY + ProjRadius <= OccMaxY
	then
		return true
	end

	const InscribedRadius = math.min(SizeX, SizeY, SizeZ) * OCCLUDER_INSCRIBED_FACTOR * InvZ :: number
	if
		InscribedRadius > OCCLUDER_MIN_PROJ_RADIUS
		and (not HasOccluder or (ForwardZ + Radius < OccFarZ and InscribedRadius >= (OccMaxX - OccMinX) * 0.5))
	then
		HasOccluder = true
		OccFarZ = ForwardZ + Radius
		OccMinX, OccMaxX = ProjX - InscribedRadius, ProjX + InscribedRadius
		OccMinY, OccMaxY = ProjY - InscribedRadius, ProjY + InscribedRadius
	end

	return false
end

return ViewCulling
