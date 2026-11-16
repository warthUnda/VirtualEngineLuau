--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")

-- Static References --
const IS_CLIENT = RunService:IsClient() :: boolean
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

-- Libraries --
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
const PlayerService = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("PlayerService"))
const PlayerControllerHelper = require(script.Parent.PlayerControllerHelper)
const PlayerClientSync = require(script.Parent.PlayerClientSync)

-- Variables --
local Initialized = false :: boolean
local PlayerStateEvent: any = nil
local PlayerRegistryEvent: RemoteEvent? = nil

-- Tables --
local RecordsByPlayer = {} :: { [Player]: PlayerService.PlayerRecord }
local RecordsByUserId = {} :: { [number]: PlayerService.PlayerRecord }
local RecordsByDynamicId = {} :: { [number]: PlayerService.PlayerRecord }
local HookedStorages = setmetatable({}, { __mode = "k" }) :: { [ECSMain.ECSStorage]: boolean }

const RegistryMaps: PlayerClientSync.RegistryMaps = {
	RecordsByPlayer = RecordsByPlayer,
	RecordsByUserId = RecordsByUserId,
	RecordsByDynamicId = RecordsByDynamicId,
	HookedStorages = HookedStorages,
}

local PlayerController = {}

-- Functions --
-- ============================================================================
-- 1. SERVER LIFECYCLE, CLIENT SYNC FACADE & QUERY ACCESSORS
-- ============================================================================

--[=[
	Exports active player OOP bindings for replication across PlayerRegistryEvent.
]=]
function PlayerController.ExportRegistryEntries(_ProvidedStorage: ECSMain.ECSStorage?): { PlayerControllerHelper.RegistryEntry }
	local Entries = {} :: { PlayerControllerHelper.RegistryEntry }
	for _, Record in pairs(RecordsByUserId) do
		if Record.Active and Record.DynamicId > 0 then
			table.insert(Entries, {
				UserId = Record.UserId, DynamicId = Record.DynamicId, Name = Record.Name,
				ColorR = Record.ColorR, ColorG = Record.ColorG, ColorB = Record.ColorB,
			})
		end
	end
	return Entries
end

--[=[
	Registers a Player, spawns its renderable dynamic ECS entity, and binds its OOP record into DynamicObjectsList.
]=]
function PlayerController.RegisterPlayer(PlayerInstance: Player, ProvidedStorage: ECSMain.ECSStorage?): PlayerService.PlayerRecord?
	const Existing = RecordsByPlayer[PlayerInstance]
	if Existing and Existing.Active and Existing.EntityId > 0 then
		return Existing
	end

	const Storage = PlayerControllerHelper.ResolveStorage(ProvidedStorage)
	if not Storage then
		return nil
	end
	PlayerControllerHelper.EnsureStorageSwapPopHook(HookedStorages, Storage)

	const Record = PlayerService.New(PlayerInstance)
	const EntityId, DynamicId = Record:BindToStorage(Storage)
	if EntityId <= 0 or DynamicId <= 0 then
		return nil
	end

	RecordsByPlayer[PlayerInstance] = Record
	if Record.UserId ~= 0 then
		RecordsByUserId[Record.UserId] = Record
	end
	RecordsByDynamicId[DynamicId] = Record

	if not IS_CLIENT and ProvidedStorage == nil and PlayerRegistryEvent then
		PlayerRegistryEvent:FireAllClients(PlayerController.ExportRegistryEntries(nil))
	end
	return Record
end

--[=[
	Evicts a disconnecting Player, deleting its ECS entity via swap-and-pop and unlinking its DynamicObjectsList slot.
]=]
function PlayerController.RemovePlayer(PlayerInstance: Player, ProvidedStorage: ECSMain.ECSStorage?)
	const Record = RecordsByPlayer[PlayerInstance]
	if not Record then
		return
	end

	const OldDynamicId = Record.DynamicId :: number
	const OldUserId = Record.UserId :: number
	RecordsByPlayer[PlayerInstance] = nil
	if OldUserId ~= 0 and RecordsByUserId[OldUserId] == Record then RecordsByUserId[OldUserId] = nil end
	if OldDynamicId > 0 and RecordsByDynamicId[OldDynamicId] == Record then RecordsByDynamicId[OldDynamicId] = nil end

	const Storage = PlayerControllerHelper.ResolveStorage(ProvidedStorage)
	if Storage then
		Record:UnbindFromStorage(Storage)
	end
	if not IS_CLIENT and ProvidedStorage == nil and PlayerRegistryEvent then
		PlayerRegistryEvent:FireAllClients(PlayerController.ExportRegistryEntries(nil))
	end
end

--[=[
	Validates and applies a 20-byte binary player transform update packet on the server.
]=]
function PlayerController.ApplyStatePayload(PlayerInstance: Player, PayloadBuffer: buffer, ProvidedStorage: ECSMain.ECSStorage?): boolean
	if typeof(PlayerInstance) == "Instance" and not PlayerInstance:IsDescendantOf(Players) then
		return false
	end
	const Valid, PosX, PosY, PosZ, LookX, LookZ = PlayerControllerHelper.UnpackStatePayload(PayloadBuffer)
	if not Valid then
		return false
	end
	const Storage = PlayerControllerHelper.ResolveStorage(ProvidedStorage)
	if not Storage then
		return false
	end

	local Record = RecordsByPlayer[PlayerInstance]
	if not Record or not Record.Active then
		Record = PlayerController.RegisterPlayer(PlayerInstance, Storage)
	end
	if not Record then
		return false
	end

	Record:UpdateTransform(Storage, PosX, PosY, PosZ, LookX, LookZ)
	return true
end

function PlayerController.ApplyRegistryEntries(Entries: { PlayerControllerHelper.RegistryEntry }, ProvidedStorage: ECSMain.ECSStorage?, LocalUserIdOverride: number?)
	PlayerClientSync.ApplyRegistryEntries(RegistryMaps, Entries, ProvidedStorage, LocalUserIdOverride)
end

function PlayerController.SyncLocalPlayerEntity(IsVisible: boolean, PosX: number, PosY: number, PosZ: number, LookX: number, LookZ: number, ProvidedStorage: ECSMain.ECSStorage?, LocalUserIdOverride: number?): boolean
	return PlayerClientSync.SyncLocalPlayerEntity(RegistryMaps, IsVisible, PosX, PosY, PosZ, LookX, LookZ, ProvidedStorage, LocalUserIdOverride)
end

function PlayerController.StepClient(DeltaTime: number, ProvidedStorage: ECSMain.ECSStorage?)
	PlayerClientSync.StepClient(RegistryMaps, PlayerStateEvent, DeltaTime, ProvidedStorage)
end

--[=[
	Initializes server or client player lifecycle listeners, swap-pop hooks, and network remotes.
]=]
function PlayerController.Initialize(ProvidedStorage: ECSMain.ECSStorage?)
	const Storage = PlayerControllerHelper.ResolveStorage(ProvidedStorage)
	if Storage then
		PlayerControllerHelper.EnsureStorageSwapPopHook(HookedStorages, Storage)
	end
	if ProvidedStorage ~= nil or Initialized then
		return
	end
	Initialized = true

	const StateEvent, RegistryEvent = PlayerControllerHelper.ResolveRemoteEvents()
	PlayerStateEvent = StateEvent
	PlayerRegistryEvent = RegistryEvent

	if not IS_CLIENT then
		for _, ExistingPlayer: Player in ipairs(Players:GetPlayers()) do
			PlayerController.RegisterPlayer(ExistingPlayer, nil)
		end
		Players.PlayerAdded:Connect(function(JoiningPlayer: Player)
			PlayerController.RegisterPlayer(JoiningPlayer, nil)
		end)
		Players.PlayerRemoving:Connect(function(LeavingPlayer: Player)
			PlayerController.RemovePlayer(LeavingPlayer, nil)
		end)
		if StateEvent then
			StateEvent.OnServerEvent:Connect(function(SenderPlayer: Player, Payload: buffer)
				PlayerController.ApplyStatePayload(SenderPlayer, Payload, nil)
			end)
		end
		if RegistryEvent then
			RegistryEvent.OnServerEvent:Connect(function(RequestingPlayer: Player)
				RegistryEvent:FireClient(RequestingPlayer, PlayerController.ExportRegistryEntries(nil))
			end)
		end
		return
	end

	if RegistryEvent then
		RegistryEvent.OnClientEvent:Connect(function(Entries: { PlayerControllerHelper.RegistryEntry })
			if type(Entries) == "table" then
				PlayerController.ApplyRegistryEntries(Entries, nil, nil)
			end
		end)
		RegistryEvent:FireServer()
	end
end

function PlayerController.GetPlayerRecord(PlayerInstance: Player): PlayerService.PlayerRecord?
	return RecordsByPlayer[PlayerInstance]
end
function PlayerController.GetPlayerRecordByUserId(UserId: number): PlayerService.PlayerRecord?
	return RecordsByUserId[UserId]
end

function PlayerController.GetPlayerRecordByEntityId(EntityId: number, ProvidedStorage: ECSMain.ECSStorage?): PlayerService.PlayerRecord?
	const Storage = PlayerControllerHelper.ResolveStorage(ProvidedStorage)
	if not Storage then
		return nil
	end
	const LinkedObject = Storage.DynamicObjectsList.GetObjectByEntityId(EntityId)
	if type(LinkedObject) == "table" and LinkedObject.ClassName == "PlayerService" then return LinkedObject :: PlayerService.PlayerRecord end
	return nil
end

function PlayerController.ResetRegistryForTest(ProvidedStorage: ECSMain.ECSStorage?)
	if not ProvidedStorage then
		return
	end
	for KeyPlayer, Record in pairs(RecordsByPlayer) do
		if typeof(KeyPlayer) ~= "Instance" then
			Record:UnbindFromStorage(ProvidedStorage)
			RecordsByPlayer[KeyPlayer] = nil
		end
	end
	for UserId, Record in pairs(RecordsByUserId) do
		if not Record.Player or typeof(Record.Player) ~= "Instance" then
			ProvidedStorage.DynamicObjectsList.RemoveObject(Record.DynamicId)
			RecordsByUserId[UserId] = nil
		end
	end
	for DynId, Record in pairs(RecordsByDynamicId) do
		if not Record.Player or typeof(Record.Player) ~= "Instance" then
			ProvidedStorage.DynamicObjectsList.RemoveObject(DynId)
			RecordsByDynamicId[DynId] = nil
		end
	end
end

return PlayerController
