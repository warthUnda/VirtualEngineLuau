--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")
const ServerScriptService = game:GetService("ServerScriptService")

-- Static References --
const IS_CLIENT = RunService:IsClient() :: boolean
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))

-- Configs --
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const PAYLOAD_BYTES = SystemsConfigs.PlayerStatePayloadBytes :: number
const CORE_EVENTS_FOLDER_NAME = SystemsConfigs.CoreEventsFolderName :: string
const PLAYER_STATE_REMOTE_NAME = SystemsConfigs.PlayerStateRemoteEventName :: string
const PLAYER_REGISTRY_REMOTE_NAME = SystemsConfigs.PlayerRegistryRemoteEventName :: string

export type RegistryEntry = {
	UserId: number,
	DynamicId: number,
	Name: string,
	ColorR: number,
	ColorG: number,
	ColorB: number,
}

-- Tables --
local CachedDefaultStorage: ECSMain.ECSStorage? = nil

local PlayerControllerHelper = {}

-- ============================================================================
-- 1. STORAGE RESOLUTION, BINARY STATE CODEC & ENTITY SLOT LOOKUP HELPERS
-- ============================================================================

--[=[
	Resolves the active Server or Client Controller Actor ECSStorage (or returns ProvidedStorage when supplied).
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional isolated storage override for unit tests.
	@return ECSMain.ECSStorage? -- Resolved ECSStorage instance.
]=]
function PlayerControllerHelper.ResolveStorage(ProvidedStorage: ECSMain.ECSStorage?): ECSMain.ECSStorage?
	if ProvidedStorage then
		return ProvidedStorage
	end

	if CachedDefaultStorage then
		return CachedDefaultStorage
	end

	const RequireAny: any = require

	if not IS_CLIENT then
		const ServerFolder = ServerScriptService:FindFirstChild("Server")
		const ObjectsFolder = if ServerFolder then ServerFolder:FindFirstChild("Objects") else nil
		const ObjectsECS = if ObjectsFolder then ObjectsFolder:FindFirstChild("ObjectsECS") else nil
		const StorageModule = if ObjectsECS then ObjectsECS:FindFirstChild("Storage") else nil
		if StorageModule and StorageModule:IsA("ModuleScript") then
			CachedDefaultStorage = RequireAny(StorageModule) :: ECSMain.ECSStorage
		end
		return CachedDefaultStorage
	end

	const LocalPlayer = Players.LocalPlayer :: Player?
	if not LocalPlayer then
		return nil
	end

	const PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts") :: PlayerScripts
	const ControllerActor = PlayerScripts:FindFirstChild("Controller") :: Actor?
	if ControllerActor then
		const ActorStorage = ControllerActor:FindFirstChild("ObjectStorage")
		if ActorStorage and ActorStorage:IsA("ModuleScript") then
			CachedDefaultStorage = RequireAny(ActorStorage) :: ECSMain.ECSStorage
			return CachedDefaultStorage
		end
	end

	const FallbackModule = PlayerScripts:WaitForChild("Client"):WaitForChild("Objects"):WaitForChild("ObjectStorage")
	CachedDefaultStorage = RequireAny(FallbackModule) :: ECSMain.ECSStorage
	return CachedDefaultStorage
end

--[=[
	Ensures CoreEvents, PlayerStateEvent (UnreliableRemoteEvent), and PlayerRegistryEvent (RemoteEvent) exist on server or resolves them on client.
	@return (UnreliableRemoteEvent?, RemoteEvent?) -- StateEvent, RegistryEvent.
]=]
function PlayerControllerHelper.ResolveRemoteEvents(): (any, RemoteEvent?)
	if not IS_CLIENT then
		local CoreEvents = ReplicatedStorage:FindFirstChild(CORE_EVENTS_FOLDER_NAME) :: Folder?
		if not CoreEvents then
			const NewFolder = Instance.new("Folder")
			NewFolder.Name = CORE_EVENTS_FOLDER_NAME
			NewFolder.Parent = ReplicatedStorage
			CoreEvents = NewFolder
		end

		const CoreFolder = CoreEvents :: Folder
		local StateEvent = CoreFolder:FindFirstChild(PLAYER_STATE_REMOTE_NAME)
		if not StateEvent then
			const NewStateEvent = Instance.new("UnreliableRemoteEvent")
			NewStateEvent.Name = PLAYER_STATE_REMOTE_NAME
			NewStateEvent.Parent = CoreEvents
			StateEvent = NewStateEvent
		end

		local RegistryEvent = CoreFolder:FindFirstChild(PLAYER_REGISTRY_REMOTE_NAME) :: RemoteEvent?
		if not RegistryEvent then
			const NewRegistryEvent = Instance.new("RemoteEvent")
			NewRegistryEvent.Name = PLAYER_REGISTRY_REMOTE_NAME
			NewRegistryEvent.Parent = CoreEvents
			RegistryEvent = NewRegistryEvent
		end

		return StateEvent, RegistryEvent
	end

	const CoreEvents = ReplicatedStorage:WaitForChild(CORE_EVENTS_FOLDER_NAME, 5) :: Folder?
	if not CoreEvents then
		return nil, nil
	end

	const StateEvent = CoreEvents:WaitForChild(PLAYER_STATE_REMOTE_NAME, 5)
	const RegistryEvent = CoreEvents:WaitForChild(PLAYER_REGISTRY_REMOTE_NAME, 5) :: RemoteEvent?
	return StateEvent, RegistryEvent
end

--[=[
	Packs a 20-byte binary player transform payload (PosX, PosY, PosZ, LookX, LookZ as f32).
	@param PayloadBuffer buffer -- Preallocated >= 20-byte target buffer.
	@param PosX number -- World center X.
	@param PosY number -- World center Y.
	@param PosZ number -- World center Z.
	@param LookX number -- Horizontal forward X.
	@param LookZ number -- Horizontal forward Z.
	@return boolean -- True if finite and written successfully.
]=]
function PlayerControllerHelper.PackStatePayload(
	PayloadBuffer: buffer,
	PosX: number,
	PosY: number,
	PosZ: number,
	LookX: number,
	LookZ: number
): boolean
	if buffer.len(PayloadBuffer) < PAYLOAD_BYTES then
		return false
	end

	const CheckSum = PosX + PosY + PosZ + LookX + LookZ :: number
	if CheckSum ~= CheckSum or math.abs(CheckSum) == math.huge then
		return false
	end

	buffer.writef32(PayloadBuffer, 0, PosX)
	buffer.writef32(PayloadBuffer, 4, PosY)
	buffer.writef32(PayloadBuffer, 8, PosZ)
	buffer.writef32(PayloadBuffer, 12, LookX)
	buffer.writef32(PayloadBuffer, 16, LookZ)
	return true
end

--[=[
	Unpacks and validates a 20-byte binary player transform payload.
	@param PayloadBuffer buffer -- Incoming binary buffer.
	@return (boolean, number, number, number, number, number) -- Valid, PosX, PosY, PosZ, LookX, LookZ.
]=]
function PlayerControllerHelper.UnpackStatePayload(
	PayloadBuffer: buffer
): (boolean, number, number, number, number, number)
	if typeof(PayloadBuffer) ~= "buffer" or buffer.len(PayloadBuffer) < PAYLOAD_BYTES then
		return false, 0, 0, 0, 0, -1
	end

	const PosX = buffer.readf32(PayloadBuffer, 0) :: number
	const PosY = buffer.readf32(PayloadBuffer, 4) :: number
	const PosZ = buffer.readf32(PayloadBuffer, 8) :: number
	const LookX = buffer.readf32(PayloadBuffer, 12) :: number
	const LookZ = buffer.readf32(PayloadBuffer, 16) :: number

	const CheckSum = PosX + PosY + PosZ + LookX + LookZ :: number
	if CheckSum ~= CheckSum or math.abs(CheckSum) == math.huge then
		return false, 0, 0, 0, 0, -1
	end

	return true, PosX, PosY, PosZ, LookX, LookZ
end

--[=[
	Scans active ECS entities in Storage to locate an entity slot stamped with the target DynamicId.
	@param Storage ECSMain.ECSStorage -- Target ECS storage container.
	@param DynamicId number -- Target DynamicObjectsList ID.
	@return number -- Matching 1-based EntityId (or 0 if not yet replicated).
]=]
function PlayerControllerHelper.FindEntitySlotByDynamicId(
	Storage: ECSMain.ECSStorage,
	DynamicId: number
): number
	if DynamicId <= 0 then
		return 0
	end

	const BoundId = Storage.DynamicObjectsList.GetBoundEntityId(DynamicId) :: number
	const EntityCount = Storage.ECSData.GetCounts().EntityECSCount :: number
	if BoundId > 0 and BoundId <= EntityCount then
		const BoundReg = buffer.readu32(Storage.PropertiesData.GetData(), (BoundId - 1) * PROPERTIES_STRIDE) :: number
		if ECSMain.GetEntityDynamicId(BoundReg) == DynamicId then
			return BoundId
		end
	end

	const PropertiesBuffer = Storage.PropertiesData.GetData() :: buffer
	for EntityId = 1, EntityCount do
		const Register = buffer.readu32(PropertiesBuffer, (EntityId - 1) * PROPERTIES_STRIDE) :: number
		if ECSMain.GetEntityDynamicId(Register) == DynamicId then
			return EntityId
		end
	end

	return 0
end

--[=[
	Registers an O(1) swap-and-pop entity slot listener once per ECSStorage so moved PlayerRecords keep accurate EntityIds.
	@param HookedStorages { [ECSMain.ECSStorage]: boolean } -- Weak-keyed map of already-hooked storages.
	@param Storage ECSMain.ECSStorage -- Target ECSStorage container.
]=]
function PlayerControllerHelper.EnsureStorageSwapPopHook(
	HookedStorages: { [ECSMain.ECSStorage]: boolean },
	Storage: ECSMain.ECSStorage
)
	if HookedStorages[Storage] then
		return
	end
	HookedStorages[Storage] = true

	Storage.ECSData.SetSwapPopCallback(function(DeletedEntityId: number, MovedFromEntityId: number)
		if DeletedEntityId ~= MovedFromEntityId then
			const MovedObject = Storage.DynamicObjectsList.GetObjectByEntityId(DeletedEntityId)
			if type(MovedObject) == "table" and MovedObject.ClassName == "PlayerService" then
				const MovedRecord = MovedObject :: { [string]: any }
				MovedRecord.EntityId = DeletedEntityId
			end
		end
	end)
end

return PlayerControllerHelper
