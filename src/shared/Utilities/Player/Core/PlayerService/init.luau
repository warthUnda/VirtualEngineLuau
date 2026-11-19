--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
const PlayerServiceHelper = require(script.PlayerServiceHelper)
const PlayerRecordMethods = require(script.PlayerRecordMethods)
const PlayerRecordAccessors = require(script.PlayerRecordAccessors)

-- Configs --
const DEFAULT_SPAWN = SystemsConfigs.PlayerDefaultSpawnPosition :: Vector3

export type PlayerRecord = {
	ClassName: string,
	Player: Player?,
	UserId: number,
	Name: string,
	EntityId: number,
	DynamicId: number,
	PositionX: number,
	PositionY: number,
	PositionZ: number,
	LookX: number,
	LookY: number,
	LookZ: number,
	ColorR: number,
	ColorG: number,
	ColorB: number,
	Active: boolean,
	BindToStorage: (
		self: PlayerRecord,
		Storage: ECSMain.ECSStorage,
		CanCollideOverride: boolean?,
		IsVisibleOverride: boolean?
	) -> (number, number),
	BindClientDynamicId: (
		self: PlayerRecord,
		Storage: ECSMain.ECSStorage,
		DynamicId: number,
		EntityId: number?
	) -> boolean,
	UpdateTransform: (
		self: PlayerRecord,
		Storage: ECSMain.ECSStorage,
		PosX: number,
		PosY: number,
		PosZ: number,
		LookX: number,
		LookZ: number
	) -> (),
	SetLocalVisibilityAndCollision: (
		self: PlayerRecord,
		Storage: ECSMain.ECSStorage,
		IsVisible: boolean,
		CanCollide: boolean
	) -> (),
	SetColor: (self: PlayerRecord, Storage: ECSMain.ECSStorage, Color: Color3) -> (),
	GetPosition: (self: PlayerRecord) -> Vector3,
	GetLookVector: (self: PlayerRecord) -> Vector3,
	UnbindFromStorage: (self: PlayerRecord, Storage: ECSMain.ECSStorage) -> (),
}

-- Tables --
local PlayerService = {
	BindToStorage = PlayerRecordMethods.BindToStorage,
	BindClientDynamicId = PlayerRecordMethods.BindClientDynamicId,
	UpdateTransform = PlayerRecordMethods.UpdateTransform,
	SetLocalVisibilityAndCollision = PlayerRecordAccessors.SetLocalVisibilityAndCollision,
	SetColor = PlayerRecordAccessors.SetColor,
	GetPosition = PlayerRecordAccessors.GetPosition,
	GetLookVector = PlayerRecordAccessors.GetLookVector,
	UnbindFromStorage = PlayerRecordMethods.UnbindFromStorage,
}
PlayerService.__index = PlayerService

-- ============================================================================
-- 1. PLAYER OOP CONSTRUCTORS & FACADE
-- ============================================================================

--[=[
	Creates a new PlayerService OOP wrapper for the specified Player instance.
	@param PlayerInstance Player -- Target player instance.
	@return PlayerRecord -- Initialized OOP player record ready for ECS & DynamicObjectsList binding.
]=]
function PlayerService.New(PlayerInstance: Player): PlayerRecord
	const UserId, PlayerName, PosX, PosY, PosZ, LookX, LookZ, ColorR, ColorG, ColorB =
		PlayerServiceHelper.ExtractInitialSeed(PlayerInstance)

	const RawRecord = {
		ClassName = "PlayerService",
		Player = PlayerInstance,
		UserId = UserId,
		Name = PlayerName,
		EntityId = 0,
		DynamicId = 0,
		PositionX = PosX,
		PositionY = PosY,
		PositionZ = PosZ,
		LookX = LookX,
		LookY = 0,
		LookZ = LookZ,
		ColorR = ColorR,
		ColorG = ColorG,
		ColorB = ColorB,
		Active = true,
	}

	return (setmetatable(RawRecord, PlayerService) :: any) :: PlayerRecord
end

--[=[
	Creates a lightweight client-side PlayerService OOP wrapper from replicated registry metadata.
	@param UserId number -- Replicated Roblox UserId.
	@param PlayerName string -- Replicated player display/account name.
	@param ColorR number -- Visual red channel (0-255).
	@param ColorG number -- Visual green channel (0-255).
	@param ColorB number -- Visual blue channel (0-255).
	@param PlayerInstance Player? -- Optional resolved client Player reference.
	@return PlayerRecord -- Initialized OOP player record.
]=]
function PlayerService.FromRegistryEntry(
	UserId: number,
	PlayerName: string,
	ColorR: number,
	ColorG: number,
	ColorB: number,
	PlayerInstance: Player?
): PlayerRecord
	const RawRecord = {
		ClassName = "PlayerService",
		Player = PlayerInstance,
		UserId = UserId,
		Name = PlayerName,
		EntityId = 0,
		DynamicId = 0,
		PositionX = DEFAULT_SPAWN.X,
		PositionY = DEFAULT_SPAWN.Y,
		PositionZ = DEFAULT_SPAWN.Z,
		LookX = 0,
		LookY = 0,
		LookZ = -1,
		ColorR = math.clamp(math.floor(ColorR), 0, 255),
		ColorG = math.clamp(math.floor(ColorG), 0, 255),
		ColorB = math.clamp(math.floor(ColorB), 0, 255),
		Active = true,
	}

	return (setmetatable(RawRecord, PlayerService) :: any) :: PlayerRecord
end

return PlayerService
