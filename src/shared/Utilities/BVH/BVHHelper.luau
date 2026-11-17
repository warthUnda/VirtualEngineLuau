--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const RunService = game:GetService("RunService") :: RunService
const ServerScriptService = game:GetService("ServerScriptService") :: ServerScriptService

-- Static References --
const IS_SERVER = RunService:IsServer() :: boolean
const SelfActor = script:GetActor() :: Actor?
const RequireAny = require :: any

-- Libraries --
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))
const BVHSubtreeBuilder = require(script.Parent.BVHSubtreeBuilder)

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
-- 1. ECS STORAGE VALIDATION & RESOLUTION HELPERS
-- ============================================================================

--[=[
	Checks whether a candidate value matches the ECSStorage table layout.
	@param Candidate any -- Value to inspect.
	@return boolean -- True when Candidate exposes ECSData, PositionData, SizeData, and DirectionsData.
]=]
function BVHHelper.IsECSStorage(Candidate: any): boolean
	return type(Candidate) == "table"
		and Candidate.ECSData ~= nil
		and Candidate.PositionData ~= nil
		and Candidate.SizeData ~= nil
		and Candidate.DirectionsData ~= nil
end

--[=[
	Resolves the active Server or Client ECSStorage (or returns ProvidedStorage when valid).
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional explicit storage override.
	@return ECSMain.ECSStorage? -- Resolved storage container, or nil if unavailable.
]=]
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

return BVHHelper
