--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")
const ServerScriptService = game:GetService("ServerScriptService")

-- Static References --
const IS_SERVER = RunService:IsServer() :: boolean
const SelfActor = script:GetActor() :: Actor?
const RequireAny = require :: any

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))
const BVHSubtreeBuilder = require(script.Parent.BVHSubtreeBuilder)

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const MUTATION_SCAN_BUDGET = SystemsConfigs.BVHMutationScanBudget :: number
const ITEM_BOUNDS_STRIDE = 36 :: number
const CACHED_STATE_STRIDE = 28 :: number

-- Variables --
local DefaultServerStorage: ECSMain.ECSStorage? = nil
local DefaultClientStorage: ECSMain.ECSStorage? = nil
local DefaultRenderStorage: ECSMain.ECSStorage? = nil

-- Tables --
local BVHHelper = {
	BuildSubtree = BVHSubtreeBuilder.BuildSubtree,
}

-- Functions --

-- ============================================================================
-- 1. STORAGE RESOLUTION, MUTATION DETECTION & IGNORE FILTER HELPERS
-- ============================================================================

function BVHHelper.IsECSStorage(Candidate: any): boolean
	return type(Candidate) == "table"
		and Candidate.ECSData ~= nil
		and Candidate.PositionData ~= nil
		and Candidate.SizeData ~= nil
		and Candidate.DirectionsData ~= nil
end

function BVHHelper.ResolveStorage(ProvidedStorage: ECSMain.ECSStorage?): ECSMain.ECSStorage?
	if ProvidedStorage and BVHHelper.IsECSStorage(ProvidedStorage) then
		return ProvidedStorage
	end

	if IS_SERVER then
		if not DefaultServerStorage then
			const ServerFolder = ServerScriptService:FindFirstChild("Server")
			const ObjectsFolder = if ServerFolder then ServerFolder:FindFirstChild("Objects") else nil
			const ObjectsECS = if ObjectsFolder then ObjectsFolder:FindFirstChild("ObjectsECS") else nil
			const StorageModule = if ObjectsECS then ObjectsECS:FindFirstChild("Storage") else nil
			if StorageModule and StorageModule:IsA("ModuleScript") then
				DefaultServerStorage = RequireAny(StorageModule) :: ECSMain.ECSStorage
			end
		end
		return DefaultServerStorage
	end

	if not DefaultClientStorage then
		const ActorStorage = if SelfActor then SelfActor:FindFirstChild("ObjectStorage") else nil
		if ActorStorage and ActorStorage:IsA("ModuleScript") then
			DefaultClientStorage = RequireAny(ActorStorage) :: ECSMain.ECSStorage
		else
			const LocalPlayer = Players.LocalPlayer :: Player?
			const PlayerScripts = if LocalPlayer then LocalPlayer:FindFirstChild("PlayerScripts") else nil
			const ControllerActor = if PlayerScripts then PlayerScripts:FindFirstChild("Controller") else nil
			const ControllerStorage = if ControllerActor then ControllerActor:FindFirstChild("ObjectStorage") else nil
			const ClientFolder = if PlayerScripts then PlayerScripts:FindFirstChild("Client") else nil
			const ObjectsFolder = if ClientFolder then ClientFolder:FindFirstChild("Objects") else nil
			const ObjStorage = if ObjectsFolder then ObjectsFolder:FindFirstChild("ObjectStorage") else nil

			if ControllerStorage and ControllerStorage:IsA("ModuleScript") then
				DefaultClientStorage = RequireAny(ControllerStorage) :: ECSMain.ECSStorage
			elseif ObjStorage and ObjStorage:IsA("ModuleScript") then
				DefaultClientStorage = RequireAny(ObjStorage) :: ECSMain.ECSStorage
			end
		end
	end

	if DefaultClientStorage and DefaultClientStorage.ECSData.GetCounts().EntityECSCount > 0 then
		return DefaultClientStorage
	end

	if not DefaultRenderStorage then
		const SharedFolder = ReplicatedStorage:FindFirstChild("Shared")
		const UtilitiesFolder = if SharedFolder then SharedFolder:FindFirstChild("Utilities") else nil
		const RenderFolder = if UtilitiesFolder then UtilitiesFolder:FindFirstChild("Render") else nil
		const RenderStorageModule = if RenderFolder then RenderFolder:FindFirstChild("ECSStorage") else nil
		if RenderStorageModule and RenderStorageModule:IsA("ModuleScript") then
			DefaultRenderStorage = RequireAny(RenderStorageModule) :: ECSMain.ECSStorage
		end
	end

	return DefaultRenderStorage or DefaultClientStorage
end

function BVHHelper.NeedsRebuild(
	Storage: ECSMain.ECSStorage,
	ActiveStorage: ECSMain.ECSStorage?,
	EntityCount: number,
	LastBuiltEntityCount: number,
	LastDynamicActiveCount: number,
	LastDynamicNextId: number,
	MutationScanCursor: number,
	CachedStateBuffer: buffer,
	EntityIsDynamicBuffer: buffer,
	ItemBoundsBuffer: buffer
): (boolean, number)
	if Storage ~= ActiveStorage or EntityCount ~= LastBuiltEntityCount then
		return true, MutationScanCursor
	end

	const DynList = Storage.DynamicObjectsList
	if DynList and (DynList.Counts.ActiveCount ~= LastDynamicActiveCount or DynList.Counts.NextId ~= LastDynamicNextId) then
		return true, MutationScanCursor
	end
	if EntityCount <= 0 then
		return false, MutationScanCursor
	end

	const PositionBuffer = Storage.PositionData.GetData() :: buffer
	const SizeBuffer = Storage.SizeData.GetData() :: buffer
	const DirectionsBuffer = Storage.DirectionsData.GetData() :: buffer
	const PropertiesBuffer = Storage.PropertiesData.GetData() :: buffer

	const CheckCount = math.min(EntityCount, MUTATION_SCAN_BUDGET) :: number
	local EntityId = MutationScanCursor :: number
	if EntityId < 1 or EntityId > EntityCount then
		EntityId = 1
	end

	for _ = 1, CheckCount do
		const StateOffset = (EntityId - 1) * CACHED_STATE_STRIDE :: number
		const CurrentProp = buffer.readu32(PropertiesBuffer, (EntityId - 1) * PROPERTIES_STRIDE) :: number
		if CurrentProp ~= buffer.readu32(CachedStateBuffer, StateOffset + 24) then
			return true, EntityId
		end

		if buffer.readu8(EntityIsDynamicBuffer, EntityId) == 0 then
			const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
			const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
			const BoundsOffset = (EntityId - 1) * ITEM_BOUNDS_STRIDE :: number
			if
				buffer.readf32(PositionBuffer, CompOffset) ~= buffer.readf32(ItemBoundsBuffer, BoundsOffset + 24)
				or buffer.readf32(PositionBuffer, CompOffset + 4) ~= buffer.readf32(ItemBoundsBuffer, BoundsOffset + 28)
				or buffer.readf32(PositionBuffer, CompOffset + 8) ~= buffer.readf32(ItemBoundsBuffer, BoundsOffset + 32)
				or buffer.readf32(SizeBuffer, CompOffset) ~= buffer.readf32(CachedStateBuffer, StateOffset)
				or buffer.readf32(SizeBuffer, CompOffset + 4) ~= buffer.readf32(CachedStateBuffer, StateOffset + 4)
				or buffer.readf32(SizeBuffer, CompOffset + 8) ~= buffer.readf32(CachedStateBuffer, StateOffset + 8)
				or buffer.readf32(DirectionsBuffer, DirOffset) ~= buffer.readf32(CachedStateBuffer, StateOffset + 12)
				or buffer.readf32(DirectionsBuffer, DirOffset + 16) ~= buffer.readf32(CachedStateBuffer, StateOffset + 16)
				or buffer.readf32(DirectionsBuffer, DirOffset + 32) ~= buffer.readf32(CachedStateBuffer, StateOffset + 20)
			then
				return true, EntityId
			end
		end

		EntityId += 1
		if EntityId > EntityCount then
			EntityId = 1
		end
	end

	return false, EntityId
end

function BVHHelper.IsIgnored(EntityId: number, DynObject: any, IgnoredId: number, IgnoreFilter: any): boolean
	if EntityId > 0 and EntityId == IgnoredId then
		return true
	end
	if IgnoreFilter == nil then
		return false
	end
	if DynObject ~= nil and IgnoreFilter == DynObject then
		return true
	end
	if type(IgnoreFilter) == "table" then
		if EntityId > 0 and IgnoreFilter[EntityId] == true then
			return true
		end
		for _, Item in ipairs(IgnoreFilter) do
			if (EntityId > 0 and Item == EntityId) or (DynObject ~= nil and Item == DynObject) then
				return true
			end
		end
	end
	return false
end

return BVHHelper
