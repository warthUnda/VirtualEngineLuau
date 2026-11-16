--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const RenderCoreFolder = SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Core")

-- Modules --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const VerticeFile = require(RenderCoreFolder:WaitForChild("VerticeFile"))

-- Configs --
const DEFAULT_SPAWN = SystemsConfigs.PlayerDefaultSpawnPosition :: Vector3
const DEFAULT_COLOR = SystemsConfigs.PlayerDefaultColor :: Color3
const PLAYER_RENDER_SHAPE = SystemsConfigs.PlayerRenderShape :: string

-- Tables --
local PlayerServiceHelper = {}

-- ============================================================================
-- 1. ORIENTATION NORMALIZATION & INITIAL CHARACTER SEEDING HELPERS
-- ============================================================================

--[=[
	Normalizes a horizontal (X, Z) look direction vector on the XZ plane, falling back safely when degenerate.
	@param RawLookX number -- Candidate forward X component.
	@param RawLookZ number -- Candidate forward Z component.
	@param FallbackX number -- Previous valid forward X component.
	@param FallbackZ number -- Previous valid forward Z component.
	@return (number, number) -- Unit horizontal (LookX, LookZ).
]=]
function PlayerServiceHelper.NormalizeHorizontalLook(
	RawLookX: number,
	RawLookZ: number,
	FallbackX: number,
	FallbackZ: number
): (number, number)
	const RawLength = math.sqrt(RawLookX * RawLookX + RawLookZ * RawLookZ) :: number
	if RawLength > 1e-5 and RawLength < math.huge then
		const InvRaw = 1 / RawLength :: number
		return RawLookX * InvRaw, RawLookZ * InvRaw
	end

	const FallbackLength = math.sqrt(FallbackX * FallbackX + FallbackZ * FallbackZ) :: number
	if FallbackLength > 1e-5 and FallbackLength < math.huge then
		const InvFallback = 1 / FallbackLength :: number
		return FallbackX * InvFallback, FallbackZ * InvFallback
	end

	return 0, -1
end

--[=[
	Resolves the configured VerticeFile 3-bit shape ID for rendered player ECS entities.
	@return number -- VerticeFile shape ID.
]=]
function PlayerServiceHelper.ResolvePlayerShapeId(): number
	const ResolvedId = VerticeFile.ShapeToId[PLAYER_RENDER_SHAPE] :: number?
	return ResolvedId or VerticeFile.ShapeToId.Cube
end

--[=[
	Extracts initial player identity, spawn transform, and RGB color from a Player instance (with optional Character fallback).
	@param PlayerInstance Player -- Target player instance.
	@return (number, string, number, number, number, number, number, number, number, number) -- UserId, Name, PosX, PosY, PosZ, LookX, LookZ, R, G, B.
]=]
function PlayerServiceHelper.ExtractInitialSeed(
	PlayerInstance: Player
): (number, string, number, number, number, number, number, number, number, number)
	const AnyPlayer = PlayerInstance :: any
	const UserId = if type(AnyPlayer.UserId) == "number" then AnyPlayer.UserId :: number else 0
	const PlayerName = if type(AnyPlayer.Name) == "string" then AnyPlayer.Name :: string else "Player"

	local PosX = DEFAULT_SPAWN.X :: number
	local PosY = DEFAULT_SPAWN.Y :: number
	local PosZ = DEFAULT_SPAWN.Z :: number
	local LookX = 0 :: number
	local LookZ = -1 :: number
	local ColorR = math.clamp(math.floor(DEFAULT_COLOR.R * 255 + 0.5), 0, 255) :: number
	local ColorG = math.clamp(math.floor(DEFAULT_COLOR.G * 255 + 0.5), 0, 255) :: number
	local ColorB = math.clamp(math.floor(DEFAULT_COLOR.B * 255 + 0.5), 0, 255) :: number

	const Character = AnyPlayer.Character :: Model?
	if typeof(Character) == "Instance" and Character:IsA("Model") and Character.Parent ~= nil then
		const RootCandidate = Character:FindFirstChild("HumanoidRootPart")
			or Character.PrimaryPart
			or Character:FindFirstChildWhichIsA("BasePart")

		local SeedCFrame: CFrame
		if RootCandidate and RootCandidate:IsA("BasePart") then
			SeedCFrame = RootCandidate.CFrame
		else
			SeedCFrame = Character:GetPivot()
		end

		const SeedPos = SeedCFrame.Position :: Vector3
		const SeedLook = SeedCFrame.LookVector :: Vector3
		PosX = SeedPos.X
		PosY = SeedPos.Y + 0.5
		PosZ = SeedPos.Z
		LookX, LookZ = PlayerServiceHelper.NormalizeHorizontalLook(SeedLook.X, SeedLook.Z, 0, -1)

		const TorsoCandidate = Character:FindFirstChild("UpperTorso") or Character:FindFirstChild("Torso")
		if TorsoCandidate and TorsoCandidate:IsA("BasePart") then
			const TorsoColor = TorsoCandidate.Color :: Color3
			ColorR = math.clamp(math.floor(TorsoColor.R * 255 + 0.5), 0, 255)
			ColorG = math.clamp(math.floor(TorsoColor.G * 255 + 0.5), 0, 255)
			ColorB = math.clamp(math.floor(TorsoColor.B * 255 + 0.5), 0, 255)
		end
	end

	return UserId, PlayerName, PosX, PosY, PosZ, LookX, LookZ, ColorR, ColorG, ColorB
end

return PlayerServiceHelper
