--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")

-- Libraries --
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
const PLAYER_EYE_OFFSET = SystemsConfigs.CameraPlayerEyeOffset :: number
const DEFAULT_CAMERA_FOV = SystemsConfigs.DefaultCameraFOV :: number
const OBSERVER_PAYLOAD_BYTES = 56 :: number
const OBSERVER_HEARTBEAT_INTERVAL = 0.5 :: number

-- Variables --
local HasSentObserver = false :: boolean
local LastSentClock = 0 :: number
local LastSentOriginX = 0 :: number
local LastSentOriginY = 0 :: number
local LastSentOriginZ = 0 :: number
local LastSentLookX = 0 :: number
local LastSentLookY = 0 :: number
local LastSentLookZ = -1 :: number
local LastSentFov = DEFAULT_CAMERA_FOV :: number

-- Tables --
local ViewObserverCodec = {
	ObserverPayloadBytes = OBSERVER_PAYLOAD_BYTES,
}

-- Functions --
-- ============================================================================
-- 1. CLIENT OBSERVER RESOLUTION & 56-BYTE BINARY STATE PACKER
-- ============================================================================

--[=[
	Resolves an optional observer BasePart from a player's character if still present in Workspace.
	@param TargetPlayer Player? -- Target player instance (defaults to LocalPlayer).
	@return BasePart? -- Observer BasePart instance (or nil if character was deleted).
]=]
function ViewObserverCodec.GetObserverHead(TargetPlayer: Player?): BasePart?
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
	Computes backward frustum padding from the camera position to the player's eye position.
	@param CamPos Vector3 -- Camera world position.
	@param PlayerPosition Vector3 -- Simulated player world position.
	@return number -- Scaled backward padding distance.
]=]
function ViewObserverCodec.ComputeBackPadding(CamPos: Vector3, PlayerPosition: Vector3): number
	const DiffX = CamPos.X - PlayerPosition.X :: number
	const DiffY = CamPos.Y - (PlayerPosition.Y + PLAYER_EYE_OFFSET) :: number
	const DiffZ = CamPos.Z - PlayerPosition.Z :: number
	return math.sqrt(DiffX * DiffX + DiffY * DiffY + DiffZ * DiffZ) * PADDING_AMOUNT
end

--[=[
	Packs the client's virtual observer state into a 56-byte buffer if the observer moved or rotated meaningfully.
	@param PayloadBuffer buffer -- Preallocated >= 56-byte target buffer.
	@param PlayerPosition Vector3 -- Simulated player world position.
	@return boolean -- True if observer changed and PayloadBuffer was updated.
]=]
function ViewObserverCodec.PackClientObserverState(PayloadBuffer: buffer, PlayerPosition: Vector3): boolean
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

	const ExtraBackPadding = ViewObserverCodec.ComputeBackPadding(CamPos, PlayerPosition)
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

return ViewObserverCodec
