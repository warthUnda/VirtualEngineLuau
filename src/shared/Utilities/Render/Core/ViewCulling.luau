--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
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
const PLAYER_EYE_OFFSET = SystemsConfigs.CameraPlayerEyeOffset :: number
const DEFAULT_CAMERA_FOV = SystemsConfigs.DefaultCameraFOV :: number
const OBSERVER_PAYLOAD_BYTES = 56 :: number
const OBSERVER_HEARTBEAT_INTERVAL = 0.5 :: number

-- Tables --
local ViewOriginX = 0 :: number
local ViewOriginY = 0 :: number
local ViewOriginZ = 0 :: number

local ViewRightX = 1 :: number
local ViewRightY = 0 :: number
local ViewRightZ = 0 :: number

local ViewUpX = 0 :: number
local ViewUpY = 1 :: number
local ViewUpZ = 0 :: number

local ViewLookX = 0 :: number
local ViewLookY = 0 :: number
local ViewLookZ = -1 :: number

local ViewTanX = BASE_TAN_X :: number
local ViewTanY = BASE_TAN_Y :: number

local HasOccluder = false :: boolean
local OccFarZ = 0 :: number
local OccMinX = 0 :: number
local OccMaxX = 0 :: number
local OccMinY = 0 :: number
local OccMaxY = 0 :: number

local HasSentObserver = false :: boolean
local LastSentClock = 0 :: number
local LastSentOriginX = 0 :: number
local LastSentOriginY = 0 :: number
local LastSentOriginZ = 0 :: number
local LastSentLookX = 0 :: number
local LastSentLookY = 0 :: number
local LastSentLookZ = -1 :: number
local LastSentFov = DEFAULT_CAMERA_FOV :: number

local ViewCulling = {
	ObserverPayloadBytes = OBSERVER_PAYLOAD_BYTES,
}

-- ============================================================================
-- 1. CULLING FUNCTIONS - FRUSTUM & DOMINANT OCCLUDER
-- ============================================================================

--[=[
	Resolves an optional observer BasePart from a player's character if still present in Workspace.
	@param TargetPlayer Player? -- Target player instance (defaults to LocalPlayer).
	@return BasePart? -- Observer BasePart instance (or nil if character was deleted).
]=]
function ViewCulling.GetObserverHead(TargetPlayer: Player?): BasePart?
	const ResolvedPlayer = TargetPlayer or Players.LocalPlayer :: Player?
	if not ResolvedPlayer then
		return nil
	end

	const Character = ResolvedPlayer.Character :: Model?
	if not Character or not Character.Parent then
		return nil
	end

	const Candidate = Character:FindFirstChild("Head")
		or Character:FindFirstChild("HumanoidRootPart")
		or Character.PrimaryPart
		or Character:FindFirstChildWhichIsA("BasePart")
	if Candidate and Candidate:IsA("BasePart") then
		return Candidate
	end

	return nil
end

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
	@param ExtraBackPadding number -- Additional backward origin shift (e.g. third-person zoom distance).
	@param FovDegrees number -- Active vertical FOV in degrees.
]=]
function ViewCulling.UpdateObserverFromVectors(
	OriginX: number,
	OriginY: number,
	OriginZ: number,
	LookX: number,
	LookY: number,
	LookZ: number,
	UpX: number,
	UpY: number,
	UpZ: number,
	RightX: number,
	RightY: number,
	RightZ: number,
	ExtraBackPadding: number,
	FovDegrees: number
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
	Computes backward frustum padding from the camera position to the player's eye position.
	@param CamPos Vector3 -- Camera world position.
	@param PlayerPosition Vector3 -- Simulated player world position.
	@return number -- Scaled backward padding distance.
]=]
function ViewCulling.ComputeBackPadding(CamPos: Vector3, PlayerPosition: Vector3): number
	const DiffX = CamPos.X - PlayerPosition.X :: number
	const DiffY = CamPos.Y - (PlayerPosition.Y + PLAYER_EYE_OFFSET) :: number
	const DiffZ = CamPos.Z - PlayerPosition.Z :: number
	return math.sqrt(DiffX * DiffX + DiffY * DiffY + DiffZ * DiffZ) * PADDING_AMOUNT
end

--[=[
	Updates the client frustum directly from CameraStore and the simulated player physics position without requiring a Character.
	@param PlayerPosition Vector3 -- Simulated player world position.
]=]
function ViewCulling.UpdateClientView(PlayerPosition: Vector3)
	if not CameraStore then
		return
	end

	const CamTable = CameraStore.GetCameraTable()
	const CamCFrame = CamTable.CameraCFrame :: CFrame
	const CamPos = CamCFrame.Position :: Vector3
	const Look = CamCFrame.LookVector :: Vector3
	const Up = CamCFrame.UpVector :: Vector3
	const Right = CamCFrame.RightVector :: Vector3
	const ExtraBackPadding = ViewCulling.ComputeBackPadding(CamPos, PlayerPosition)

	ViewCulling.UpdateObserverFromVectors(
		CamPos.X,
		CamPos.Y,
		CamPos.Z,
		Look.X,
		Look.Y,
		Look.Z,
		Up.X,
		Up.Y,
		Up.Z,
		Right.X,
		Right.Y,
		Right.Z,
		ExtraBackPadding,
		CamTable.CameraFOV or DEFAULT_CAMERA_FOV
	)
end

--[=[
	Packs the client's virtual observer state into a 56-byte buffer if the observer moved or rotated meaningfully.
	@param PayloadBuffer buffer -- Preallocated >= 56-byte target buffer.
	@param PlayerPosition Vector3 -- Simulated player world position.
	@return boolean -- True if observer changed and PayloadBuffer was updated.
]=]
function ViewCulling.PackClientObserverState(PayloadBuffer: buffer, PlayerPosition: Vector3): boolean
	if not CameraStore or buffer.len(PayloadBuffer) < OBSERVER_PAYLOAD_BYTES then
		return false
	end

	const CamTable = CameraStore.GetCameraTable()
	const CamCFrame = CamTable.CameraCFrame :: CFrame
	const CamPos = CamCFrame.Position :: Vector3
	const Look = CamCFrame.LookVector :: Vector3
	const Up = CamCFrame.UpVector :: Vector3
	const Right = CamCFrame.RightVector :: Vector3
	const CamFov = (CamTable.CameraFOV or DEFAULT_CAMERA_FOV) :: number

	const DeltaPosX = CamPos.X - LastSentOriginX :: number
	const DeltaPosY = CamPos.Y - LastSentOriginY :: number
	const DeltaPosZ = CamPos.Z - LastSentOriginZ :: number
	const PosDistSq = DeltaPosX * DeltaPosX + DeltaPosY * DeltaPosY + DeltaPosZ * DeltaPosZ :: number

	const DeltaLookX = Look.X - LastSentLookX :: number
	const DeltaLookY = Look.Y - LastSentLookY :: number
	const DeltaLookZ = Look.Z - LastSentLookZ :: number
	const LookDiffSq = DeltaLookX * DeltaLookX + DeltaLookY * DeltaLookY + DeltaLookZ * DeltaLookZ :: number

	const NowClock = os.clock() :: number
	if
		HasSentObserver
		and (NowClock - LastSentClock) < OBSERVER_HEARTBEAT_INTERVAL
		and PosDistSq < 0.0025
		and LookDiffSq < 1e-5
		and math.abs(CamFov - LastSentFov) < 0.1
	then
		return false
	end

	HasSentObserver = true
	LastSentClock = NowClock
	LastSentOriginX, LastSentOriginY, LastSentOriginZ = CamPos.X, CamPos.Y, CamPos.Z
	LastSentLookX, LastSentLookY, LastSentLookZ = Look.X, Look.Y, Look.Z
	LastSentFov = CamFov

	const ExtraBackPadding = ViewCulling.ComputeBackPadding(CamPos, PlayerPosition)

	buffer.writef32(PayloadBuffer, 0, CamPos.X)
	buffer.writef32(PayloadBuffer, 4, CamPos.Y)
	buffer.writef32(PayloadBuffer, 8, CamPos.Z)
	buffer.writef32(PayloadBuffer, 12, Look.X)
	buffer.writef32(PayloadBuffer, 16, Look.Y)
	buffer.writef32(PayloadBuffer, 20, Look.Z)
	buffer.writef32(PayloadBuffer, 24, Up.X)
	buffer.writef32(PayloadBuffer, 28, Up.Y)
	buffer.writef32(PayloadBuffer, 32, Up.Z)
	buffer.writef32(PayloadBuffer, 36, Right.X)
	buffer.writef32(PayloadBuffer, 40, Right.Y)
	buffer.writef32(PayloadBuffer, 44, Right.Z)
	buffer.writef32(PayloadBuffer, 48, ExtraBackPadding)
	buffer.writef32(PayloadBuffer, 52, CamFov)

	return true
end

--[=[
	Pulls the frustum origin backward behind the camera based on Head-to-Camera distance (or CameraStore directly if Head is nil).
	@param Head BasePart? -- Optional observer BasePart providing fallback position and orientation.
]=]
function ViewCulling.UpdateDynamicView(Head: BasePart?)
	if CameraStore then
		const CamTable = CameraStore.GetCameraTable()
		const CamCFrame = CamTable.CameraCFrame :: CFrame
		const CamPos = CamCFrame.Position :: Vector3
		const Look = CamCFrame.LookVector :: Vector3
		const Up = CamCFrame.UpVector :: Vector3
		const Right = CamCFrame.RightVector :: Vector3
		const ExtraBackPadding = if Head and Head.Parent
			then (CamPos - Head.Position).Magnitude * PADDING_AMOUNT
			else 0 :: number

		ViewCulling.UpdateObserverFromVectors(
			CamPos.X,
			CamPos.Y,
			CamPos.Z,
			Look.X,
			Look.Y,
			Look.Z,
			Up.X,
			Up.Y,
			Up.Z,
			Right.X,
			Right.Y,
			Right.Z,
			ExtraBackPadding,
			CamTable.CameraFOV or DEFAULT_CAMERA_FOV
		)
		return
	end

	if not Head then
		return
	end

	const HeadPos = Head.Position :: Vector3
	const HeadCF = Head.CFrame :: CFrame
	const Look = HeadCF.LookVector :: Vector3
	const Up = HeadCF.UpVector :: Vector3
	const Right = HeadCF.RightVector :: Vector3

	ViewCulling.UpdateObserverFromVectors(
		HeadPos.X,
		HeadPos.Y,
		HeadPos.Z,
		Look.X,
		Look.Y,
		Look.Z,
		Up.X,
		Up.Y,
		Up.Z,
		Right.X,
		Right.Y,
		Right.Z,
		0,
		DEFAULT_CAMERA_FOV
	)
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

	-- 1. Near / Far plane check
	if ForwardZ + Radius < NEAR_CLIP or ForwardZ - Radius > FAR_CLIP then
		return true
	end

	const LocalX = RelX * ViewRightX + RelY * ViewRightY + RelZ * ViewRightZ :: number
	const LocalY = RelX * ViewUpX + RelY * ViewUpY + RelZ * ViewUpZ :: number

	-- 2. Horizontal / Vertical frustum cone check
	if math.abs(LocalX) - Radius > ForwardZ * ViewTanX then
		return true
	end

	if math.abs(LocalY) - Radius > ForwardZ * ViewTanY then
		return true
	end

	-- 3. O(1) Occlusion check against cached foreground occluder
	const InvZ = 1 / math.max(NEAR_CLIP, ForwardZ) :: number
	const ProjRadius = Radius * InvZ :: number
	const ProjX = LocalX * InvZ :: number
	const ProjY = LocalY * InvZ :: number

	if
		HasOccluder
		and ForwardZ - Radius > OccFarZ
		and ProjX - ProjRadius >= OccMinX
		and ProjX + ProjRadius <= OccMaxX
		and ProjY - ProjRadius >= OccMinY
		and ProjY + ProjRadius <= OccMaxY
	then
		return true
	end

	-- Register large close entities as the foreground occluder for subsequent checks
	const InscribedRadius = math.min(SizeX, SizeY, SizeZ) * OCCLUDER_INSCRIBED_FACTOR * InvZ :: number
	if InscribedRadius > OCCLUDER_MIN_PROJ_RADIUS and (not HasOccluder or ForwardZ < OccFarZ) then
		HasOccluder = true
		OccFarZ = ForwardZ + Radius
		OccMinX = ProjX - InscribedRadius
		OccMaxX = ProjX + InscribedRadius
		OccMinY = ProjY - InscribedRadius
		OccMaxY = ProjY + InscribedRadius
	end

	return false
end

return ViewCulling
