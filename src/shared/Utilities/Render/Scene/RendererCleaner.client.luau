--!strict
--!native
--!optimize 2

--[=[
	@class RendererCleaner.client
	Actor-hosted client render culler that updates view frustum state and synchronizes
	visible ObjectStorage entities into RenderECSStorage ordered largest-to-smallest.
]=]

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const LocalPlayer = Players.LocalPlayer :: Player
const SelfActor = script:GetActor() :: Actor?
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const UtilitiesFolder = SharedFolder:WaitForChild("Utilities")
const RenderRoot = UtilitiesFolder:WaitForChild("Render")
const ObjectStorageModule = (SelfActor and SelfActor:WaitForChild("ObjectStorage"))
	or LocalPlayer:WaitForChild("PlayerScripts")
		:WaitForChild("Client")
		:WaitForChild("Objects")
		:WaitForChild("ObjectStorage")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
const ViewCulling = require(RenderRoot:WaitForChild("Core"):WaitForChild("ViewCulling"))
const CleanerHelper = require(RenderRoot:WaitForChild("Scene"):WaitForChild("CleanerHelper"))
const PhysicsController = require(UtilitiesFolder:WaitForChild("Physics"):WaitForChild("Controller"):WaitForChild("PhysicsController"))

-- Storage --
const RequireAny = require :: any
const ObjectStorage = RequireAny(ObjectStorageModule) :: ECSMain.ECSStorage
const RenderECSStorage = require(RenderRoot:WaitForChild("ECSStorage"))

-- Configs --
const CLEANER_TICK_INTERVAL = SystemsConfigs.CleanerTickInterval :: number

-- Tables --
const CleanerState = CleanerHelper.CreateCleanerState(ObjectStorage, RenderECSStorage)

-- Functions --
-- ============================================================================
-- 1. CLIENT RENDER CULLING & DESCENDING-SIZE ECS SYNCHRONIZATION LOOP
-- ============================================================================

while true do
	if ObjectStorage.ECSData.GetCounts().EntityECSCount > 0 then
		ViewCulling.UpdateClientView(PhysicsController.GetPlayerPosition())
	end

	CleanerHelper.SyncRenderStorage(CleanerState)
	task.wait(CLEANER_TICK_INTERVAL)
end
