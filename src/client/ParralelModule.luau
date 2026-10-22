local ParralelModule = {}

-- Modules --
local RenderConfigs = require(script.Parent.RenderConfigs)

-- References --
local WorkerTemplate =
	game.ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("WorkerTemplate") :: Folder

local ControllerTemplate = game.ReplicatedStorage
	:WaitForChild("Shared")
	:WaitForChild("Utilities")
	:WaitForChild("Render")
	:WaitForChild("ControllerFolder") :: Folder

-- Configs --
local ActorCount = RenderConfigs.GetActorCount()

-- ============================================================================
-- 1. CREATE WORKER - CONTROLLER SETUP
-- ============================================================================

function ParralelModule.CreateSetup()
	local PlayerScripts = game:GetService("Players").LocalPlayer:WaitForChild("PlayerScripts") :: Folder

	-- Workers
	local WorkerFolder = Instance.new("Folder") :: Folder
	WorkerFolder.Name = "WorkerFolder"
	WorkerFolder.Parent = PlayerScripts

	-- Controller for the workers
	local ControllerActor = Instance.new("Actor") :: Actor
	ControllerActor.Name = "Controller"
	ControllerActor.Parent = PlayerScripts

	-- Scripts of the controller
	local ControllerScript = ControllerTemplate:WaitForChild("RenderExecuter"):Clone() :: Script -- Controls the actual workers
	ControllerScript.Parent = ControllerActor

	local ControllerPartStore = ControllerTemplate:WaitForChild("PartStores"):Clone() :: ModuleScript -- Provides the parts for Controller script
	ControllerPartStore.Parent = ControllerActor

	local ControllerScanner = ControllerTemplate:WaitForChild("WorkspaceScanner"):Clone() :: Script -- scans for parts and puts them inside ControllerPartStore
	ControllerScanner.Parent = ControllerActor

	-- Creation of workers
	for i = 1, ActorCount do
		local NewWorkerActor = Instance.new("Actor") :: Actor
		NewWorkerActor.Parent = WorkerFolder
		NewWorkerActor.Name = "ParallelSetup" .. i

		local NewRenderTemplate = WorkerTemplate:WaitForChild("ParralelWorker"):Clone() :: Script -- Executes the hard math in parralel
		NewRenderTemplate.Name = "ParallelRender" .. i
		NewRenderTemplate.Parent = NewWorkerActor
	end
end

return ParralelModule
