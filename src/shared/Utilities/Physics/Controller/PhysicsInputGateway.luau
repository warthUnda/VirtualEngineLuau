--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")
const ServerScriptService = game:GetService("ServerScriptService")
const UserInputService = game:GetService("UserInputService")

-- Static References --
const IS_CLIENT = RunService:IsClient() :: boolean
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const UtilitiesFolder = SharedFolder:WaitForChild("Utilities")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const CameraStore = if IS_CLIENT
	then require(UtilitiesFolder:WaitForChild("Render"):WaitForChild("Camera"):WaitForChild("CameraStore"))
	else nil

-- Configs --
const PLAYER_MAX_WISH_SCALE = SystemsConfigs.PlayerMaxWishScale :: number

-- Tables --
local PhysicsInputGateway = {}

-- Functions --

-- ============================================================================
-- 1. STORAGE RESOLUTION, CHARACTER SEEDING & KEYBOARD WISH INPUT GATEWAY
-- ============================================================================

--[=[
	Resolves the active client or server ObjectStorage module reference.
]=]
function PhysicsInputGateway.ResolveObjectStorage(): Instance?
	if not IS_CLIENT then
		const ServerFolder = ServerScriptService:FindFirstChild("Server")
		const ObjectsFolder = if ServerFolder then ServerFolder:FindFirstChild("Objects") else nil
		const ObjectsECS = if ObjectsFolder then ObjectsFolder:FindFirstChild("ObjectsECS") else nil
		return if ObjectsECS then ObjectsECS:FindFirstChild("Storage") else nil
	end

	const LocalPlayer = Players.LocalPlayer :: Player?
	if not LocalPlayer then
		return nil
	end

	const PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts") :: PlayerScripts
	const ControllerActor = PlayerScripts:FindFirstChild("Controller") :: Actor?
	if ControllerActor then
		const ActorStorage = ControllerActor:FindFirstChild("ObjectStorage")
		if ActorStorage then
			return ActorStorage
		end
	end

	return PlayerScripts:WaitForChild("Client"):WaitForChild("Objects"):WaitForChild("ObjectStorage")
end

--[=[
	Extracts an initial spawn position and optional root BasePart from a character model without requiring a Humanoid.
]=]
function PhysicsInputGateway.ConfigureCharacterInstance(Character: Model): (BasePart?, number, number, number)
	const Humanoid = Character:FindFirstChildWhichIsA("Humanoid") :: Humanoid?
	if Humanoid then
		Humanoid.PlatformStand = true
	end

	for _, Descendant: Instance in ipairs(Character:GetDescendants()) do
		if Descendant:IsA("BasePart") then
			Descendant.CanCollide = false
		end
	end

	const RootPartCandidate = Character:FindFirstChild("HumanoidRootPart")
		or Character.PrimaryPart
		or Character:FindFirstChildWhichIsA("BasePart")
	if RootPartCandidate and RootPartCandidate:IsA("BasePart") then
		const RootPart = RootPartCandidate :: BasePart
		RootPart.Anchored = true
		RootPart.CanCollide = false
		const StartPos = RootPart.Position :: Vector3
		return RootPart, StartPos.X, StartPos.Y + 0.5, StartPos.Z
	end

	const PivotPos = Character:GetPivot().Position :: Vector3
	return nil, PivotPos.X, PivotPos.Y + 0.5, PivotPos.Z
end

--[=[
	Waits briefly for a live Workspace character model's root BasePart to replicate before seeding spawn coordinates.
]=]
function PhysicsInputGateway.AwaitCharacterRoot(Character: Model)
	if not Character.Parent then
		return
	end
	const ExistingRoot = Character:FindFirstChild("HumanoidRootPart")
		or Character.PrimaryPart
		or Character:FindFirstChildWhichIsA("BasePart")
	if not ExistingRoot then
		Character:WaitForChild("HumanoidRootPart", 2)
	end
end

--[=[
	Samples WASD and Space keyboard inputs relative to camera orientation.
]=]
function PhysicsInputGateway.SampleKeyboardInput(
	PendingWishX: number,
	PendingWishZ: number,
	PendingMaxScale: number,
	PendingJumpRequested: boolean
): (number, number, number, boolean)
	if not IS_CLIENT or not CameraStore or UserInputService:GetFocusedTextBox() ~= nil then
		return PendingWishX, PendingWishZ, PendingMaxScale, PendingJumpRequested
	end

	const CamLook = CameraStore.GetCameraLook() :: Vector3
	const CamRight = CameraStore.GetCameraRight() :: Vector3
	local ForwardX: number, ForwardZ: number = CamLook.X, CamLook.Z
	const ForwardLen = math.sqrt(ForwardX * ForwardX + ForwardZ * ForwardZ) :: number
	if ForwardLen > 1e-5 then
		ForwardX /= ForwardLen
		ForwardZ /= ForwardLen
	end

	local RightX: number, RightZ: number = CamRight.X, CamRight.Z
	const RightLen = math.sqrt(RightX * RightX + RightZ * RightZ) :: number
	if RightLen > 1e-5 then
		RightX /= RightLen
		RightZ /= RightLen
	end

	local MoveX = 0 :: number
	local MoveZ = 0 :: number
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then
		MoveX += ForwardX
		MoveZ += ForwardZ
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then
		MoveX -= ForwardX
		MoveZ -= ForwardZ
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then
		MoveX += RightX
		MoveZ += RightZ
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then
		MoveX -= RightX
		MoveZ -= RightZ
	end

	local NextWishX = PendingWishX :: number
	local NextWishZ = PendingWishZ :: number
	local NextMaxScale = PendingMaxScale :: number
	local NextJumpRequested = PendingJumpRequested :: boolean

	const MoveLen = math.sqrt(MoveX * MoveX + MoveZ * MoveZ) :: number
	if MoveLen > 1e-5 then
		NextWishX += MoveX / MoveLen
		NextWishZ += MoveZ / MoveLen
		NextMaxScale = math.max(NextMaxScale, 1.0)
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
		NextJumpRequested = true
	end

	return NextWishX, NextWishZ, NextMaxScale, NextJumpRequested
end

--[=[
	Normalizes and clamps accumulated player wish-direction intent.
]=]
function PhysicsInputGateway.FlushPlayerIntent(
	RawWishX: number,
	RawWishZ: number,
	MaxScale: number,
	JumpRequested: boolean
): (number, number, number, boolean)
	const WishLen = math.sqrt(RawWishX * RawWishX + RawWishZ * RawWishZ) :: number
	if WishLen <= 1e-5 then
		return 0, 0, 0, JumpRequested
	end
	return RawWishX / WishLen, RawWishZ / WishLen, math.min(MaxScale, PLAYER_MAX_WISH_SCALE), JumpRequested
end

return PhysicsInputGateway
