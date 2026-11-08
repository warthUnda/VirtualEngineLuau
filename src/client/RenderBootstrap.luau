local RenderBootstrap = {}

-- Modules --
local RenderRoot = game.ReplicatedStorage
	:WaitForChild("Shared")
	:WaitForChild("Utilities")
	:WaitForChild("Render") :: Folder

-- References --
local ControllerFolder = RenderRoot:WaitForChild("Controller") :: Folder
local SceneFolder = RenderRoot:WaitForChild("Scene") :: Folder
local WorkerFolder = RenderRoot:WaitForChild("Worker") :: Folder

-- Modules --
local RenderConfigs = require(RenderRoot:WaitForChild("RenderConfigs")) :: ModuleScript

-- Configs --
local ActorCount = RenderConfigs.GetActorCount()

-- ============================================================================
-- 1. CREATE WORKER - CONTROLLER SETUP
-- ============================================================================

function RenderBootstrap.CreateSetup()
	local PlayerScripts = game:GetService("Players").LocalPlayer:WaitForChild("PlayerScripts") :: Folder

	-- Workers
	local WorkerActorFolder = Instance.new("Folder") :: Folder
	WorkerActorFolder.Name = "WorkerFolder"
	WorkerActorFolder.Parent = PlayerScripts

	-- Controller for the workers
	local ControllerActor = Instance.new("Actor") :: Actor
	ControllerActor.Name = "Controller"
	ControllerActor.Parent = PlayerScripts

	-- Scripts of the controller
	local ControllerScript = ControllerFolder:WaitForChild("RenderController"):Clone() :: Script -- Controls the actual workers
	ControllerScript.Parent = ControllerActor

	local ControllerPartStore = SceneFolder:WaitForChild("PartStore"):Clone() :: ModuleScript -- Provides the parts for Controller script
	ControllerPartStore.Parent = ControllerActor

	local ControllerScanner = SceneFolder:WaitForChild("WorkspaceScanner"):Clone() :: Script -- Scans for parts and puts them inside ControllerPartStore
	ControllerScanner.Parent = ControllerActor

	-- Creation of workers
	for i = 1, ActorCount do
		local NewWorkerActor = Instance.new("Actor") :: Actor
		NewWorkerActor.Parent = WorkerActorFolder
		NewWorkerActor.Name = "ParallelSetup" .. i

		local NewRenderTemplate = WorkerFolder:WaitForChild("ParallelWorker"):Clone() :: Script -- Executes the hard math in parallel
		NewRenderTemplate.Name = "ParallelRender" .. i
		NewRenderTemplate.Parent = NewWorkerActor
	end
end

return RenderBootstrap
