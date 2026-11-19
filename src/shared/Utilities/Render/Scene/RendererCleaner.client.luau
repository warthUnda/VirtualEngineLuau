--!strict
--!native
--!optimize 2

--[=[
	@class RendererCleaner
	Client render culling and front-to-back BVH ECS synchronization loop inside the Controller Actor.
]=]

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const RunService = game:GetService("RunService") :: RunService

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
const CameraStore = require(RenderRoot:WaitForChild("Camera"):WaitForChild("CameraStore"))
const ViewCulling = require(RenderRoot:WaitForChild("Core"):WaitForChild("ViewCulling"))
const CleanerHelper = require(RenderRoot:WaitForChild("Scene"):WaitForChild("CleanerHelper"))
const PhysicsController =
	require(UtilitiesFolder:WaitForChild("Physics"):WaitForChild("Controller"):WaitForChild("PhysicsController"))

-- Storage --
const RequireAny = require :: any
const ObjectStorage = RequireAny(ObjectStorageModule) :: ECSMain.ECSStorage
const RenderECSStorage = require(RenderRoot:WaitForChild("ECSStorage"))

-- Configs --
const CLEANER_TICK_INTERVAL = SystemsConfigs.CleanerTickInterval :: number
const DEFAULT_CAMERA_FOV = SystemsConfigs.DefaultCameraFOV :: number

-- Tables --
const CleanerState = CleanerHelper.CreateCleanerState(ObjectStorage, RenderECSStorage)

-- Functions --
-- ============================================================================
-- 1. CLIENT RENDER CULLING & FRONT-TO-BACK BVH ECS SYNCHRONIZATION LOOP
-- ============================================================================

while true do
	const CamTable = CameraStore.GetCameraTable()
	const CamCFrame = CamTable.CameraCFrame :: CFrame
	const CamFOV = (CamTable.CameraFOV or DEFAULT_CAMERA_FOV) :: number
	const PlayerPos = PhysicsController.GetPlayerPosition()

	if CleanerHelper.NeedsSync(CleanerState, CamCFrame, CamFOV, PlayerPos) then
		if ObjectStorage.ECSData.GetCounts().EntityECSCount > 0 then
			ViewCulling.UpdateClientView(PlayerPos)
		end
		CleanerHelper.SyncRenderStorage(CleanerState)
	end

	if CLEANER_TICK_INTERVAL > 0 then
		task.wait(CLEANER_TICK_INTERVAL)
	else
		RunService.RenderStepped:Wait()
	end
end
