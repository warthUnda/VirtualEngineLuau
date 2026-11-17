--!strict
--!native
--!optimize 2

--[=[
	@class PlayerControllerHelper
	Storage resolution, binary player state codec, and entity slot lookup helpers
	for PlayerController.
]=]

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const RunService = game:GetService("RunService") :: RunService
const ServerScriptService = game:GetService("ServerScriptService") :: ServerScriptService

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared") :: Folder
const RequireAny = require :: any

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))

-- Configs --
const IS_CLIENT = RunService:IsClient() :: boolean
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const PAYLOAD_BYTES = SystemsConfigs.PlayerStatePayloadBytes :: number

export type RegistryEntry = {
	UserId: number,
	DynamicId: number,
	Name: string,
	ColorR: number,
	ColorG: number,
	ColorB: number,
}

-- Variables --
local CachedDefaultStorage: ECSMain.ECSStorage? = nil

-- Tables --
local PlayerControllerHelper = {}

-- Functions --
-- ============================================================================
-- 1. STORAGE RESOLUTION, BINARY STATE CODEC & ENTITY SLOT LOOKUP HELPERS
-- ============================================================================

--[=[
	Resolves the active Server or Client Controller Actor ECSStorage (or returns ProvidedStorage when supplied).
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional explicit ECSStorage override.
	@return ECSMain.ECSStorage? -- Resolved ECSStorage container or nil if unresolved.
]=]
function PlayerControllerHelper.ResolveStorage(ProvidedStorage: ECSMain.ECSStorage?): ECSMain.ECSStorage?
	if ProvidedStorage then
		return ProvidedStorage
	end
	if CachedDefaultStorage then
		return CachedDefaultStorage
	end

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
	Packs a 20-byte binary player transform payload (PosX, PosY, PosZ, LookX, LookZ as f32).
	@param PayloadBuffer buffer -- Buffer with at least 20 bytes capacity.
	@param PosX number -- Player position X.
	@param PosY number -- Player position Y.
	@param PosZ number -- Player position Z.
	@param LookX number -- Player look direction X.
	@param LookZ number -- Player look direction Z.
	@return boolean -- True if successfully packed and validated.
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
	@param PayloadBuffer buffer -- Inbound payload buffer.
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
	@param Storage ECSMain.ECSStorage -- Target ECS storage.
	@param DynamicId number -- 1-based dynamic ID to find.
	@return number -- Entity ID (1-based) if found, or 0.
]=]
function PlayerControllerHelper.FindEntitySlotByDynamicId(Storage: ECSMain.ECSStorage, DynamicId: number): number
	if DynamicId <= 0 then
		return 0
	end
	const BoundId = Storage.DynamicObjectsList.GetBoundEntityId(DynamicId) :: number
	const EntityCount = Storage.ECSData.GetCounts().EntityECSCount :: number
	const PropertiesBuffer = Storage.PropertiesData.GetData() :: buffer
	if BoundId > 0 and BoundId <= EntityCount then
		if ECSMain.GetEntityDynamicId(buffer.readu32(PropertiesBuffer, (BoundId - 1) * PROPERTIES_STRIDE)) == DynamicId then
			return BoundId
		end
	end
	for EntityId = 1, EntityCount do
		if ECSMain.GetEntityDynamicId(buffer.readu32(PropertiesBuffer, (EntityId - 1) * PROPERTIES_STRIDE)) == DynamicId then
			return EntityId
		end
	end
	return 0
end

return PlayerControllerHelper
