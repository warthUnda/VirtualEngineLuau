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
const UtilitiesFolder = SharedFolder:WaitForChild("Utilities")

-- Modules --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
const PlayerService = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("PlayerService"))
const PlayerControllerHelper = require(script.Parent.PlayerControllerHelper)

const PhysicsController = if IS_CLIENT
	then require(UtilitiesFolder:WaitForChild("Physics"):WaitForChild("Controller"):WaitForChild("PhysicsController"))
	else nil
const CameraStore = if IS_CLIENT
	then require(UtilitiesFolder:WaitForChild("Render"):WaitForChild("Camera"):WaitForChild("CameraStore"))
	else nil
const CameraService = if IS_CLIENT
	then require(UtilitiesFolder:WaitForChild("Render"):WaitForChild("Camera"):WaitForChild("CameraService"))
	else nil

-- Configs --
const SYNC_INTERVAL = SystemsConfigs.PlayerSyncInterval :: number
const PAYLOAD_BYTES = SystemsConfigs.PlayerStatePayloadBytes :: number
const HEARTBEAT_RESEND_INTERVAL = 0.5 :: number

-- Tables --
local Initialized = false :: boolean
local PlayerStateEvent: any = nil
local PlayerRegistryEvent: RemoteEvent? = nil

local RecordsByPlayer = {} :: { [Player]: PlayerService.PlayerRecord }
local RecordsByUserId = {} :: { [number]: PlayerService.PlayerRecord }
local RecordsByDynamicId = {} :: { [number]: PlayerService.PlayerRecord }
local HookedStorages = setmetatable({}, { __mode = "k" }) :: { [ECSMain.ECSStorage]: boolean }

local SyncAccumulator = SYNC_INTERVAL :: number
local HasSentInitialState = false :: boolean
local LastSentClock = 0 :: number
local LastSentPosX = 0 :: number
local LastSentPosY = 0 :: number
local LastSentPosZ = 0 :: number
local LastSentLookX = 0 :: number
local LastSentLookZ = -1 :: number

-- Buffers
const ClientStatePayload = buffer.create(PAYLOAD_BYTES) :: buffer

local PlayerController = {}

-- ============================================================================
-- 1. SERVER LIFECYCLE & DYNAMIC OBJECTS REGISTRY SYNC
-- ============================================================================

--[=[
	Exports active player OOP bindings for replication across PlayerRegistryEvent.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional storage override.
	@return { PlayerControllerHelper.RegistryEntry } -- Array of active player registry entries.
]=]
function PlayerController.ExportRegistryEntries(
	_ProvidedStorage: ECSMain.ECSStorage?
): { PlayerControllerHelper.RegistryEntry }
	local Entries = {} :: { PlayerControllerHelper.RegistryEntry }
	for _, Record in pairs(RecordsByUserId) do
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
	Registers a Player, spawns its renderable dynamic ECS entity, and binds its OOP record into DynamicObjectsList.
	@param PlayerInstance Player -- Target player to register.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional isolated storage override for unit tests.
	@return PlayerService.PlayerRecord? -- Bound OOP PlayerRecord (or nil if storage unavailable).
]=]
function PlayerController.RegisterPlayer(
	PlayerInstance: Player,
	ProvidedStorage: ECSMain.ECSStorage?
): PlayerService.PlayerRecord?
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
	@param PlayerInstance Player -- Disconnecting player instance.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional isolated storage override for unit tests.
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

	if not IS_CLIENT and ProvidedStorage == nil and PlayerRegistryEvent then
		PlayerRegistryEvent:FireAllClients(PlayerController.ExportRegistryEntries(nil))
	end
end

--[=[
	Validates and applies a 20-byte binary player transform update packet on the server.
	@param PlayerInstance Player -- Sending player instance.
	@param PayloadBuffer buffer -- 20-byte binary state payload.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional isolated storage override for unit tests.
	@return boolean -- True if valid and applied.
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

-- ============================================================================
-- 2. CLIENT REGISTRY APPLICATION & ZERO-LAG LOCAL ENTITY SYNC
-- ============================================================================

--[=[
	Applies replicated server registry entries on the client, linking OOP PlayerRecords into DynamicObjectsList
	and suppressing CanCollide on the local player's own replicated entity.
	@param Entries { PlayerControllerHelper.RegistryEntry } -- Active player metadata entries.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional isolated storage override for unit tests.
	@param LocalUserIdOverride number? -- Optional explicit local UserId override for unit tests.
]=]
function PlayerController.ApplyRegistryEntries(
	Entries: { PlayerControllerHelper.RegistryEntry },
	ProvidedStorage: ECSMain.ECSStorage?,
	LocalUserIdOverride: number?
)
	const Storage = PlayerControllerHelper.ResolveStorage(ProvidedStorage)
	if not Storage then
		return
	end

	PlayerControllerHelper.EnsureStorageSwapPopHook(HookedStorages, Storage)

	const LocalUserId = if LocalUserIdOverride ~= nil
		then LocalUserIdOverride
		elseif IS_CLIENT and Players.LocalPlayer then Players.LocalPlayer.UserId
		else 0

	local ActiveDynamicIds = {} :: { [number]: boolean }
	for _, Entry in ipairs(Entries) do
		if type(Entry) == "table" and type(Entry.DynamicId) == "number" and Entry.DynamicId > 0 then
			ActiveDynamicIds[Entry.DynamicId] = true
		end
	end

	for DynId, ExistingRecord in pairs(RecordsByDynamicId) do
		if not ActiveDynamicIds[DynId] then
			ExistingRecord.Active = false
			Storage.DynamicObjectsList.RemoveObject(DynId)
			RecordsByDynamicId[DynId] = nil
			if ExistingRecord.UserId ~= 0 and RecordsByUserId[ExistingRecord.UserId] == ExistingRecord then
				RecordsByUserId[ExistingRecord.UserId] = nil
			end
			if ExistingRecord.Player and RecordsByPlayer[ExistingRecord.Player] == ExistingRecord then
				RecordsByPlayer[ExistingRecord.Player] = nil
			end
		end
	end

	for _, Entry in ipairs(Entries) do
		if type(Entry) ~= "table" or type(Entry.DynamicId) ~= "number" or Entry.DynamicId <= 0 then
			continue
		end

		const LivePlayer = if Entry.UserId > 0 then Players:GetPlayerByUserId(Entry.UserId) else nil
		local Record = RecordsByUserId[Entry.UserId]
		if not Record then
			Record = PlayerService.FromRegistryEntry(
				Entry.UserId,
				Entry.Name,
				Entry.ColorR,
				Entry.ColorG,
				Entry.ColorB,
				LivePlayer
			)
		else
			Record.Player = LivePlayer or Record.Player
			Record.Name = Entry.Name
			Record.ColorR = Entry.ColorR
			Record.ColorG = Entry.ColorG
			Record.ColorB = Entry.ColorB
		end

		const FoundSlot = PlayerControllerHelper.FindEntitySlotByDynamicId(Storage, Entry.DynamicId)
		Record:BindClientDynamicId(Storage, Entry.DynamicId, if FoundSlot > 0 then FoundSlot else nil)

		RecordsByDynamicId[Entry.DynamicId] = Record
		if Entry.UserId ~= 0 then
			RecordsByUserId[Entry.UserId] = Record
		end
		if LivePlayer then
			RecordsByPlayer[LivePlayer] = Record
		end

		if Entry.UserId == LocalUserId and FoundSlot > 0 then
			const VisibleInCamera = if CameraService then CameraService.CharacterVisibility ~= "None" else false
			Record:SetLocalVisibilityAndCollision(Storage, VisibleInCamera, false)
		end
	end
end

--[=[
	Synchronizes the local player's own replicated ECS entity on the client: forces CanCollide = false so physics
	and camera raycasts never self-hit, toggles visibility for FirstPerson vs ThirdPerson, and updates transform locally.
	@param IsVisible boolean -- True when camera renders the local avatar (e.g. ThirdPerson / ShiftLock).
	@param PosX number -- Simulated local player center X.
	@param PosY number -- Simulated local player center Y.
	@param PosZ number -- Simulated local player center Z.
	@param LookX number -- Horizontal camera forward X.
	@param LookZ number -- Horizontal camera forward Z.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional isolated storage override for unit tests.
	@param LocalUserIdOverride number? -- Optional explicit local UserId override for unit tests.
	@return boolean -- True if the local player's ECS slot was resolved and updated.
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
	const LocalUserId = if LocalUserIdOverride ~= nil
		then LocalUserIdOverride
		elseif IS_CLIENT and Players.LocalPlayer then Players.LocalPlayer.UserId
		else 0
	if LocalUserId == 0 then
		return false
	end

	const LocalRecord = RecordsByUserId[LocalUserId]
	if not LocalRecord or LocalRecord.DynamicId <= 0 then
		return false
	end

	const Storage = PlayerControllerHelper.ResolveStorage(ProvidedStorage)
	if not Storage then
		return false
	end

	local SlotId = Storage.DynamicObjectsList.GetBoundEntityId(LocalRecord.DynamicId) :: number
	const EntityCount = Storage.ECSData.GetCounts().EntityECSCount :: number
	if SlotId <= 0 or SlotId > EntityCount then
		SlotId = PlayerControllerHelper.FindEntitySlotByDynamicId(Storage, LocalRecord.DynamicId)
		if SlotId > 0 then
			Storage.DynamicObjectsList.BindEntity(LocalRecord.DynamicId, SlotId)
		end
	end

	LocalRecord.EntityId = SlotId
	if SlotId <= 0 then
		return false
	end

	LocalRecord:SetLocalVisibilityAndCollision(Storage, IsVisible, false)
	if IsVisible then
		LocalRecord:UpdateTransform(Storage, PosX, PosY, PosZ, LookX, LookZ)
	end

	return true
end

--[=[
	Executes per-frame client player entity sync and streams compact 20-byte transform updates to the server.
	@param DeltaTime number -- Elapsed frame time in seconds.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional isolated storage override.
]=]
function PlayerController.StepClient(DeltaTime: number, ProvidedStorage: ECSMain.ECSStorage?)
	if not IS_CLIENT or not PhysicsController or not CameraStore then
		return
	end

	const PlayerPos = PhysicsController.GetPlayerPosition() :: Vector3
	const CamLook = CameraStore.GetCameraLook() :: Vector3
	const PosX: number, PosY: number, PosZ: number = PlayerPos.X, PlayerPos.Y, PlayerPos.Z
	const LookX: number, LookZ: number = CamLook.X, CamLook.Z
	const IsVisible = if CameraService then (CameraService.CharacterVisibility ~= "None") else false

	PlayerController.SyncLocalPlayerEntity(IsVisible, PosX, PosY, PosZ, LookX, LookZ, ProvidedStorage, nil)

	SyncAccumulator += DeltaTime
	if SyncAccumulator < SYNC_INTERVAL or not PlayerStateEvent then
		return
	end
	SyncAccumulator = 0

	const DiffX = PosX - LastSentPosX :: number
	const DiffY = PosY - LastSentPosY :: number
	const DiffZ = PosZ - LastSentPosZ :: number
	const PosDistSq = DiffX * DiffX + DiffY * DiffY + DiffZ * DiffZ :: number

	const DiffLookX = LookX - LastSentLookX :: number
	const DiffLookZ = LookZ - LastSentLookZ :: number
	const LookDiffSq = DiffLookX * DiffLookX + DiffLookZ * DiffLookZ :: number

	const NowClock = os.clock() :: number
	if
		HasSentInitialState
		and (NowClock - LastSentClock) < HEARTBEAT_RESEND_INTERVAL
		and PosDistSq < 1e-4
		and LookDiffSq < 1e-5
	then
		return
	end

	if PlayerControllerHelper.PackStatePayload(ClientStatePayload, PosX, PosY, PosZ, LookX, LookZ) then
		HasSentInitialState = true
		LastSentClock = NowClock
		LastSentPosX, LastSentPosY, LastSentPosZ = PosX, PosY, PosZ
		LastSentLookX, LastSentLookZ = LookX, LookZ
		PlayerStateEvent:FireServer(ClientStatePayload)
	end
end

-- ============================================================================
-- 3. INITIALIZATION & QUERY ACCESSORS
-- ============================================================================

--[=[
	Initializes server or client player lifecycle listeners, swap-pop hooks, and network remotes.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional isolated storage override for unit tests.
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

--[=[
	Retrieves the active OOP PlayerRecord for a Player instance.
	@param PlayerInstance Player -- Target player instance.
	@return PlayerService.PlayerRecord? -- Matching OOP PlayerRecord (or nil).
]=]
function PlayerController.GetPlayerRecord(PlayerInstance: Player): PlayerService.PlayerRecord?
	return RecordsByPlayer[PlayerInstance]
end

--[=[
	Retrieves the active OOP PlayerRecord by Roblox UserId.
	@param UserId number -- Target player UserId.
	@return PlayerService.PlayerRecord? -- Matching OOP PlayerRecord (or nil).
]=]
function PlayerController.GetPlayerRecordByUserId(UserId: number): PlayerService.PlayerRecord?
	return RecordsByUserId[UserId]
end

--[=[
	Retrieves the OOP PlayerRecord linked to an ECS entity slot via DynamicObjectsList.
	@param EntityId number -- Target 1-based ECS entity slot.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional storage override.
	@return PlayerService.PlayerRecord? -- Linked OOP PlayerRecord (or nil if entity is not a player).
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
	Clears test records bound to an isolated test storage without disturbing live session players.
	@param ProvidedStorage ECSMain.ECSStorage? -- Isolated test storage to clean up.
]=]
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
