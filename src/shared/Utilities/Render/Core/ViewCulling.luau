--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const RunService = game:GetService("RunService") :: RunService

-- Modules --
const RenderConfigs = require(ReplicatedStorage.Shared.Utilities.Render.RenderConfigs)
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
const PADDING_AMOUNT = 1.0 :: number -- Increase to make culling looser (more padding), decrease to make it tighter

const WIDTH: number, HEIGHT: number = RenderConfigs.GetDimensions2D()
const ASPECT_RATIO = WIDTH / HEIGHT :: number
const BASE_TAN_Y = 0.70 * PADDING_AMOUNT :: number
const BASE_TAN_X = BASE_TAN_Y * ASPECT_RATIO :: number

const BASE_BACK_PADDING = 10 * PADDING_AMOUNT :: number
const RADIUS_PADDING_FACTOR = 0.35 * PADDING_AMOUNT :: number
const NEAR_CLIP = 0.4 :: number
const FAR_CLIP = 200 :: number
const COMPONENT_STRIDE = 12 :: number

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

local ViewCulling = {}

-- ============================================================================
-- 1. CULLING FUNCTIONS - FRUSTUM & DOMINANT OCCLUDER
-- ============================================================================

function ViewCulling.GetObserverHead(TargetPlayer: Player?): BasePart?
	const ResolvedPlayer = TargetPlayer or Players.LocalPlayer :: Player?
	if not ResolvedPlayer then
		return nil
	end

	const Character = ResolvedPlayer.Character :: Model?
	if not Character then
		return nil
	end

	const Head = Character:FindFirstChild("Head") :: Instance?
	if Head and Head:IsA("BasePart") then
		return Head
	end

	return nil
end

-- Pulls the frustum origin backward behind the camera based on Head-to-Camera distance.
-- This naturally pads both the immediate surroundings and the frustum cone without trig.
function ViewCulling.UpdateDynamicView(Head: BasePart)
	const HeadPos = Head.Position :: Vector3
	local Origin = HeadPos
	local Right = Head.CFrame.RightVector :: Vector3
	local Up = Head.CFrame.UpVector :: Vector3
	local Look = Head.CFrame.LookVector :: Vector3
	local BackPadding = BASE_BACK_PADDING :: number

	if CameraStore then
		const CamTable = CameraStore.GetCameraTable()
		const CamCFrame = CamTable.CameraCFrame :: CFrame
		const CamPos = CamCFrame.Position :: Vector3

		Origin = CamPos
		Right = CamCFrame.RightVector
		Up = CamCFrame.UpVector
		Look = CamCFrame.LookVector
		BackPadding += (CamPos - HeadPos).Magnitude * PADDING_AMOUNT

		const FovScale = (CamTable.CameraFOV or 70) / 70 :: number
		ViewTanY = BASE_TAN_Y * FovScale
		ViewTanX = ViewTanY * ASPECT_RATIO
	end

	ViewOriginX = Origin.X - Look.X * BackPadding
	ViewOriginY = Origin.Y - Look.Y * BackPadding
	ViewOriginZ = Origin.Z - Look.Z * BackPadding

	ViewRightX, ViewRightY, ViewRightZ = Right.X, Right.Y, Right.Z
	ViewUpX, ViewUpY, ViewUpZ = Up.X, Up.Y, Up.Z
	ViewLookX, ViewLookY, ViewLookZ = Look.X, Look.Y, Look.Z

	HasOccluder = false
end

-- O(1) Frustum + Dominant Occluder check per entity (no sqrt, no nested loop).
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
	const InscribedRadius = math.min(SizeX, SizeY, SizeZ) * 0.35 * InvZ :: number
	if InscribedRadius > 0.25 and (not HasOccluder or ForwardZ < OccFarZ) then
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
