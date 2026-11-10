local RenderBootstrap = {}

-- Modules --
local RenderRoot = game.ReplicatedStorage
	:WaitForChild("Shared")
	:WaitForChild("Utilities")
	:WaitForChild("Render") :: Folder

-- References --
local ControllerFolder = RenderRoot:WaitForChild("Controller") :: Folder
local WorkerFolder = RenderRoot:WaitForChild("Worker") :: Folder
local SceneFolder = RenderRoot:WaitForChild("Scene") :: Folder

-- Modules --
local RenderConfigs = require(RenderRoot:WaitForChild("RenderConfigs")) :: ModuleScript

-- Configs --
local ActorCount = RenderConfigs.GetActorCount()

-- ============================================================================
-- 1. CREATE WORKER - CONTROLLER SETUP
-- ============================================================================

function RenderBootstrap.CreateSetup()
	local PlayerScripts = game:GetService("Players").LocalPlayer:WaitForChild("PlayerScripts") :: Folder
	local ClientObjects = PlayerScripts:WaitForChild("Client"):WaitForChild("Objects") :: Folder

	-- Workers
	local WorkerActorFolder = Instance.new("Folder") :: Folder
	WorkerActorFolder.Name = "WorkerFolder"
	WorkerActorFolder.Parent = PlayerScripts

	-- Controller for the workers
	local ControllerActor = Instance.new("Actor") :: Actor
	ControllerActor.Name = "Controller"
	ControllerActor.Parent = PlayerScripts

	-- Every Actor runs in its own Luau VM and gets its own copy of each ModuleScript it requires,
	-- so the ECS storage has to be cloned into the controller Actor. The ReplicationReceiver is
	-- cloned next to it so it fills the exact buffers this Actor renders from.
	local ControllerStorage = ClientObjects:WaitForChild("ObjectStorage"):Clone() :: Folder
	ControllerStorage.Parent = ControllerActor

	local ControllerReceiver =
		ClientObjects:WaitForChild("Replication"):WaitForChild("ReplicationReceiver"):Clone() :: LocalScript
	ControllerReceiver.Parent = ControllerActor

	-- Scripts of the controller
	local ControllerScript = ControllerFolder:WaitForChild("RenderController"):Clone() :: Script -- Controls the actual workers
	ControllerScript.Parent = ControllerActor

	local CleanerScript = SceneFolder:WaitForChild("RendererCleaner"):Clone() :: LocalScript
	CleanerScript.Parent = ControllerActor

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
