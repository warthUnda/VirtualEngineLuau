--!strict
--!native
--!optimize 2

--[=[
	@class PlayerClientSync
	Client-side player registry synchronization, local player entity transform updates,
	and unthrottled outbound player state sync.
]=]

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const RunService = game:GetService("RunService") :: RunService

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared") :: Folder
const UtilitiesFolder = SharedFolder:WaitForChild("Utilities") :: Folder

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
const EventBus = require(UtilitiesFolder:WaitForChild("EventBus"))
const PlayerService = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("PlayerService"))
const PlayerControllerHelper = require(script.Parent.PlayerControllerHelper)

const PhysicsController = if RunService:IsClient()
	then require(UtilitiesFolder:WaitForChild("Physics"):WaitForChild("Controller"):WaitForChild("PhysicsController"))
	else nil
const CameraStore = if RunService:IsClient()
	then require(UtilitiesFolder:WaitForChild("Render"):WaitForChild("Camera"):WaitForChild("CameraStore"))
	else nil
const CameraService = if RunService:IsClient()
	then require(UtilitiesFolder:WaitForChild("Render"):WaitForChild("Camera"):WaitForChild("CameraService"))
	else nil

-- Configs --
const IS_CLIENT = RunService:IsClient() :: boolean
const SYNC_INTERVAL = SystemsConfigs.PlayerSyncInterval :: number
const PAYLOAD_BYTES = SystemsConfigs.PlayerStatePayloadBytes :: number
const HEARTBEAT_RESEND_INTERVAL = 0.5 :: number

export type RegistryMaps = {
	RecordsByPlayer: { [Player]: PlayerService.PlayerRecord },
	RecordsByUserId: { [number]: PlayerService.PlayerRecord },
	RecordsByDynamicId: { [number]: PlayerService.PlayerRecord },
}

-- Variables --
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

-- Tables --
local PlayerClientSync = {}

-- Functions --
-- ============================================================================
-- 1. CLIENT REGISTRY APPLICATION & ZERO-LAG LOCAL ENTITY SYNC
-- ============================================================================

--[=[
	Applies replicated server registry entries on the client and links OOP PlayerRecords into DynamicObjectsList.
	@param Maps RegistryMaps -- Client registry tracking maps.
	@param Entries { PlayerControllerHelper.RegistryEntry } -- Replicated registry entries array.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional explicit ECSStorage override.
	@param LocalUserIdOverride number? -- Optional local user ID override.
]=]
function PlayerClientSync.ApplyRegistryEntries(
	Maps: RegistryMaps,
	Entries: { PlayerControllerHelper.RegistryEntry },
	ProvidedStorage: ECSMain.ECSStorage?,
	LocalUserIdOverride: number?
)
	const Storage = PlayerControllerHelper.ResolveStorage(ProvidedStorage)
	if not Storage then
		return
	end

	const LocalUserId = if LocalUserIdOverride ~= nil
		then LocalUserIdOverride
		elseif IS_CLIENT and Players.LocalPlayer then Players.LocalPlayer.UserId
		else 0

	local ActiveDynamicIds = {} :: { [number]: boolean }
	for _, Entry: PlayerControllerHelper.RegistryEntry in ipairs(Entries) do
		if type(Entry) == "table" and type(Entry.DynamicId) == "number" and Entry.DynamicId > 0 then
			ActiveDynamicIds[Entry.DynamicId] = true
		end
	end

	for DynId: number, ExistingRecord: PlayerService.PlayerRecord in pairs(Maps.RecordsByDynamicId) do
		if not ActiveDynamicIds[DynId] then
			ExistingRecord.Active = false
			Storage.DynamicObjectsList.RemoveObject(DynId)
			Maps.RecordsByDynamicId[DynId] = nil
			if ExistingRecord.UserId ~= 0 and Maps.RecordsByUserId[ExistingRecord.UserId] == ExistingRecord then
				Maps.RecordsByUserId[ExistingRecord.UserId] = nil
			end
			if ExistingRecord.Player and Maps.RecordsByPlayer[ExistingRecord.Player] == ExistingRecord then
				Maps.RecordsByPlayer[ExistingRecord.Player] = nil
			end
		end
	end

	for _, Entry: PlayerControllerHelper.RegistryEntry in ipairs(Entries) do
		if type(Entry) ~= "table" or type(Entry.DynamicId) ~= "number" or Entry.DynamicId <= 0 then
			continue
		end

		const LivePlayer = if Entry.UserId > 0 then Players:GetPlayerByUserId(Entry.UserId) else nil
		local Record = Maps.RecordsByUserId[Entry.UserId]
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
		Maps.RecordsByDynamicId[Entry.DynamicId] = Record
		if Entry.UserId ~= 0 then
			Maps.RecordsByUserId[Entry.UserId] = Record
		end
		if LivePlayer then
			Maps.RecordsByPlayer[LivePlayer] = Record
		end

		if Entry.UserId == LocalUserId and FoundSlot > 0 then
			const VisibleInCamera = if CameraService then CameraService.CharacterVisibility ~= "None" else false
			Record:SetLocalVisibilityAndCollision(Storage, VisibleInCamera, false)
		end
	end
end

--[=[
	Synchronizes the local player's own replicated ECS entity on the client (suppresses CanCollide and updates transform).
	@param Maps RegistryMaps -- Client registry tracking maps.
	@param IsVisible boolean -- True if local player model should be visible.
	@param PosX number -- Player position X.
	@param PosY number -- Player position Y.
	@param PosZ number -- Player position Z.
	@param LookX number -- Player camera look direction X.
	@param LookZ number -- Player camera look direction Z.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional explicit ECSStorage override.
	@param LocalUserIdOverride number? -- Optional local user ID override.
	@return boolean -- True if local entity was successfully located and updated.
]=]
function PlayerClientSync.SyncLocalPlayerEntity(
	Maps: RegistryMaps,
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

	const LocalRecord = Maps.RecordsByUserId[LocalUserId]
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
	Executes per-frame client player entity sync and emits SendPlayerState on EventBus when transform changes.
	@param Maps RegistryMaps -- Client registry tracking maps.
	@param DeltaTime number -- Frame delta time.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional explicit ECSStorage override.
]=]
function PlayerClientSync.StepClient(
	Maps: RegistryMaps,
	DeltaTime: number,
	ProvidedStorage: ECSMain.ECSStorage?
)
	if not IS_CLIENT or not PhysicsController or not CameraStore then
		return
	end

	const PlayerPos = PhysicsController.GetPlayerPosition() :: Vector3
	const CamLook = CameraStore.GetCameraLook() :: Vector3
	const PosX: number, PosY: number, PosZ: number = PlayerPos.X, PlayerPos.Y, PlayerPos.Z
	const LookX: number, LookZ: number = CamLook.X, CamLook.Z
	const IsVisible = if CameraService then (CameraService.CharacterVisibility ~= "None") else false

	PlayerClientSync.SyncLocalPlayerEntity(Maps, IsVisible, PosX, PosY, PosZ, LookX, LookZ, ProvidedStorage, nil)

	SyncAccumulator += DeltaTime
	if SyncAccumulator < SYNC_INTERVAL then
		return
	end
	SyncAccumulator = 0

	const DiffX = PosX - LastSentPosX :: number
	const DiffY = PosY - LastSentPosY :: number
	const DiffZ = PosZ - LastSentPosZ :: number
	const DiffLookX = LookX - LastSentLookX :: number
	const DiffLookZ = LookZ - LastSentLookZ :: number
	const NowClock = os.clock() :: number
	if
		HasSentInitialState
		and (NowClock - LastSentClock) < HEARTBEAT_RESEND_INTERVAL
		and (DiffX * DiffX + DiffY * DiffY + DiffZ * DiffZ) < 1e-4
		and (DiffLookX * DiffLookX + DiffLookZ * DiffLookZ) < 1e-5
	then
		return
	end

	if PlayerControllerHelper.PackStatePayload(ClientStatePayload, PosX, PosY, PosZ, LookX, LookZ) then
		HasSentInitialState = true
		LastSentClock = NowClock
		LastSentPosX, LastSentPosY, LastSentPosZ = PosX, PosY, PosZ
		LastSentLookX, LastSentLookZ = LookX, LookZ
		EventBus.Emit(EventBus.Events.SendPlayerState, ClientStatePayload)
	end
end

return PlayerClientSync
