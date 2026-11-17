--!strict
--!native
--!optimize 2

--[=[
	@class PlayerController
	Facade coordinating server player lifecycle and client registry synchronization
	via EventBus without coupling domain code to network RemoteEvents.
]=]

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const RunService = game:GetService("RunService") :: RunService

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared") :: Folder

-- Libraries --
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
const EventBus = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("EventBus"))
const PlayerService = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("PlayerService"))
const PlayerControllerHelper = require(script.Parent.PlayerControllerHelper)
const PlayerClientSync = require(script.Parent.PlayerClientSync)

-- Configs --
const IS_CLIENT = RunService:IsClient() :: boolean
const Events = EventBus.Events

-- Variables --
local Initialized = false :: boolean

-- Tables --
local RecordsByPlayer = {} :: { [Player]: PlayerService.PlayerRecord }
local RecordsByUserId = {} :: { [number]: PlayerService.PlayerRecord }
local RecordsByDynamicId = {} :: { [number]: PlayerService.PlayerRecord }

const RegistryMaps: PlayerClientSync.RegistryMaps = {
	RecordsByPlayer = RecordsByPlayer,
	RecordsByUserId = RecordsByUserId,
	RecordsByDynamicId = RecordsByDynamicId,
}

local PlayerController = {}

-- Functions --
-- ============================================================================
-- 1. SERVER LIFECYCLE, EVENT-DRIVEN SYNC FACADE & QUERY ACCESSORS
-- ============================================================================

--[=[
	Exports active player OOP bindings for event-driven replication.
	@param _ProvidedStorage ECSMain.ECSStorage? -- Optional explicit ECSStorage override.
	@return { PlayerControllerHelper.RegistryEntry } -- Array of active registry entries.
]=]
function PlayerController.ExportRegistryEntries(_ProvidedStorage: ECSMain.ECSStorage?): { PlayerControllerHelper.RegistryEntry }
	local Entries = {} :: { PlayerControllerHelper.RegistryEntry }
	for _, Record: PlayerService.PlayerRecord in pairs(RecordsByUserId) do
		if Record.Active and Record.DynamicId > 0 then
			table.insert(Entries, {
				UserId = Record.UserId,
				DynamicId = Record.DynamicId,
				Name = Record.Name,
				ColorR = Record.ColorR,
				ColorG = Record.ColorG,
				ColorB = Record.ColorB,
			})
		end
	end
	return Entries
end

--[=[
	Registers a Player, spawns its renderable dynamic ECS entity, and publishes ServerPlayerRegistryChanged on EventBus.
	@param PlayerInstance Player -- Target player instance to register.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional explicit ECSStorage override.
	@return PlayerService.PlayerRecord? -- Initialized player record, or nil if registration failed.
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

	if not IS_CLIENT and ProvidedStorage == nil then
		EventBus.Emit(Events.ServerPlayerRegistryChanged, PlayerController.ExportRegistryEntries(nil))
	end
	return Record
end

--[=[
	Evicts a disconnecting Player, frees its ECS slot in place, and publishes ServerPlayerRegistryChanged on EventBus.
	@param PlayerInstance Player -- Target player instance to remove.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional explicit ECSStorage override.
]=]
function PlayerController.RemovePlayer(PlayerInstance: Player, ProvidedStorage: ECSMain.ECSStorage?)
	const Record = RecordsByPlayer[PlayerInstance]
	if not Record then
		return
	end

	const OldDynamicId = Record.DynamicId :: number
	const OldUserId = Record.UserId :: number
	RecordsByPlayer[PlayerInstance] = nil
	if OldUserId ~= 0 and RecordsByUserId[OldUserId] == Record then
		RecordsByUserId[OldUserId] = nil
	end
	if OldDynamicId > 0 and RecordsByDynamicId[OldDynamicId] == Record then
		RecordsByDynamicId[OldDynamicId] = nil
	end

	const Storage = PlayerControllerHelper.ResolveStorage(ProvidedStorage)
	if Storage then
		Record:UnbindFromStorage(Storage)
	end
	if not IS_CLIENT and ProvidedStorage == nil then
		EventBus.Emit(Events.ServerPlayerRegistryChanged, PlayerController.ExportRegistryEntries(nil))
	end
end

--[=[
	Validates and applies a 20-byte binary player transform update packet on the server.
	@param PlayerInstance Player -- Target player who sent the packet.
	@param PayloadBuffer buffer -- 20-byte binary payload buffer.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional explicit ECSStorage override.
	@return boolean -- True if payload was successfully unpacked and applied.
]=]
function PlayerController.ApplyStatePayload(
	PlayerInstance: Player,
	PayloadBuffer: buffer,
	ProvidedStorage: ECSMain.ECSStorage?
): boolean
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

--[=[
	Applies replicated server registry entries on the client.
	@param Entries { PlayerControllerHelper.RegistryEntry } -- Replicated registry entries.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional explicit ECSStorage override.
	@param LocalUserIdOverride number? -- Optional local user ID override.
]=]
function PlayerController.ApplyRegistryEntries(
	Entries: { PlayerControllerHelper.RegistryEntry },
	ProvidedStorage: ECSMain.ECSStorage?,
	LocalUserIdOverride: number?
)
	PlayerClientSync.ApplyRegistryEntries(RegistryMaps, Entries, ProvidedStorage, LocalUserIdOverride)
end

--[=[
	Synchronizes the local player's own replicated ECS entity on the client.
	@param IsVisible boolean -- True if local player model should be visible.
	@param PosX number -- Player position X.
	@param PosY number -- Player position Y.
	@param PosZ number -- Player position Z.
	@param LookX number -- Player camera look direction X.
	@param LookZ number -- Player camera look direction Z.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional explicit ECSStorage override.
	@param LocalUserIdOverride number? -- Optional local user ID override.
	@return boolean -- True if entity was successfully updated.
]=]
function PlayerController.SyncLocalPlayerEntity(
	IsVisible: boolean,
	PosX: number,
	PosY: number,
	PosZ: number,
	LookX: number,
	LookZ: number,
	ProvidedStorage: ECSMain.ECSStorage?,
	LocalUserIdOverride: number?
): boolean
	return PlayerClientSync.SyncLocalPlayerEntity(
		RegistryMaps,
		IsVisible,
		PosX,
		PosY,
		PosZ,
		LookX,
		LookZ,
		ProvidedStorage,
		LocalUserIdOverride
	)
end

--[=[
	Executes per-frame client player entity sync and emits player state updates on EventBus.
	@param DeltaTime number -- Frame delta time.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional explicit ECSStorage override.
]=]
function PlayerController.StepClient(DeltaTime: number, ProvidedStorage: ECSMain.ECSStorage?)
	PlayerClientSync.StepClient(RegistryMaps, DeltaTime, ProvidedStorage)
end

--[=[
	Initializes server or client player lifecycle listeners via EventBus without touching RemoteEvents directly.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional explicit ECSStorage override.
]=]
function PlayerController.Initialize(ProvidedStorage: ECSMain.ECSStorage?)
	if ProvidedStorage ~= nil or Initialized then
		return
	end
	Initialized = true

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
		EventBus.Subscribe(Events.ServerPlayerStateReceived, function(SenderPlayer: Player, Payload: buffer)
			PlayerController.ApplyStatePayload(SenderPlayer, Payload, nil)
		end)
		EventBus.Subscribe(Events.ServerPlayerRegistryRequested, function(RequestingPlayer: Player)
			EventBus.Emit(Events.ServerPlayerRegistryReply, RequestingPlayer, PlayerController.ExportRegistryEntries(nil))
		end)
		return
	end

	EventBus.Subscribe(Events.PlayerRegistryReceived, function(Entries: { PlayerControllerHelper.RegistryEntry })
		if type(Entries) == "table" then
			PlayerController.ApplyRegistryEntries(Entries, nil, nil)
		end
	end)
end

--[=[
	Retrieves the active PlayerRecord corresponding to a given Player instance.
	@param PlayerInstance Player -- Target player instance.
	@return PlayerService.PlayerRecord? -- PlayerRecord if registered, or nil.
]=]
function PlayerController.GetPlayerRecord(PlayerInstance: Player): PlayerService.PlayerRecord?
	return RecordsByPlayer[PlayerInstance]
end

--[=[
	Retrieves the active PlayerRecord corresponding to a given Roblox UserId.
	@param UserId number -- Target player Roblox UserId.
	@return PlayerService.PlayerRecord? -- PlayerRecord if registered, or nil.
]=]
function PlayerController.GetPlayerRecordByUserId(UserId: number): PlayerService.PlayerRecord?
	return RecordsByUserId[UserId]
end

--[=[
	Retrieves the active PlayerRecord bound to an entity slot ID in storage.
	@param EntityId number -- 1-based ECS entity ID.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional explicit ECSStorage override.
	@return PlayerService.PlayerRecord? -- Bound PlayerRecord or nil.
]=]
function PlayerController.GetPlayerRecordByEntityId(
	EntityId: number,
	ProvidedStorage: ECSMain.ECSStorage?
): PlayerService.PlayerRecord?
	const Storage = PlayerControllerHelper.ResolveStorage(ProvidedStorage)
	if not Storage then
		return nil
	end
	const LinkedObject = Storage.DynamicObjectsList.GetObjectByEntityId(EntityId)
	if type(LinkedObject) == "table" and LinkedObject.ClassName == "PlayerService" then
		return LinkedObject :: PlayerService.PlayerRecord
	end
	return nil
end

--[=[
	Resets test-created player registrations in isolated unit test storage containers.
	@param ProvidedStorage ECSMain.ECSStorage? -- Isolated test storage container.
]=]
function PlayerController.ResetRegistryForTest(ProvidedStorage: ECSMain.ECSStorage?)
	if not ProvidedStorage then
		return
	end
	for KeyPlayer, Record: PlayerService.PlayerRecord in pairs(RecordsByPlayer) do
		if typeof(KeyPlayer) ~= "Instance" then
			Record:UnbindFromStorage(ProvidedStorage)
			RecordsByPlayer[KeyPlayer] = nil
		end
	end
	for UserId: number, Record: PlayerService.PlayerRecord in pairs(RecordsByUserId) do
		if not Record.Player or typeof(Record.Player) ~= "Instance" then
			ProvidedStorage.DynamicObjectsList.RemoveObject(Record.DynamicId)
			RecordsByUserId[UserId] = nil
		end
	end
	for DynId: number, Record: PlayerService.PlayerRecord in pairs(RecordsByDynamicId) do
		if not Record.Player or typeof(Record.Player) ~= "Instance" then
			ProvidedStorage.DynamicObjectsList.RemoveObject(DynId)
			RecordsByDynamicId[DynId] = nil
		end
	end
end

return PlayerController
