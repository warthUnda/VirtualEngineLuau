--!strict
--!native
--!optimize 2

--[=[
	@class RenderBootstrap
	Bootstraps the multi-threaded rendering environment by instantiating worker actors,
	cloning isolated ECS storage copies, replication receivers, and the main controller script.
]=]

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const RenderRoot = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("Render")
const WorkerFolder = RenderRoot:WaitForChild("Worker")
const SceneFolder = RenderRoot:WaitForChild("Scene")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const ACTOR_COUNT = SystemsConfigs.ActorCount :: number

-- Tables --
local RenderBootstrap = {}

-- Functions --
-- ============================================================================
-- 1. CREATE WORKER - CONTROLLER SETUP
-- ============================================================================

--[=[
	Bootstraps the multi-threaded rendering environment by instantiating worker actors,
	cloning isolated ECS storage copies, replication receivers, and the main controller script.
]=]
function RenderBootstrap.CreateSetup(): ()
	const PlayerScripts = Players.LocalPlayer:WaitForChild("PlayerScripts") :: PlayerScripts
	const ClientFolder = PlayerScripts:WaitForChild("Client") :: Folder
	const ClientObjects = ClientFolder:WaitForChild("Objects") :: Folder

	-- Workers
	const WorkerActorFolder = Instance.new("Folder") :: Folder
	WorkerActorFolder.Name = "WorkerFolder"
	WorkerActorFolder.Parent = PlayerScripts

	-- Creation of workers
	for i: number = 1, ACTOR_COUNT do
		const NewWorkerActor = Instance.new("Actor") :: Actor
		NewWorkerActor.Parent = WorkerActorFolder
		NewWorkerActor.Name = "ParallelSetup" .. i

		const NewRenderTemplate = WorkerFolder:WaitForChild("ParallelWorker"):Clone() :: Script
		NewRenderTemplate.Name = "ParallelRender" .. i
		NewRenderTemplate.Parent = NewWorkerActor
	end

	-- Controller for the workers
	const ControllerActor = Instance.new("Actor") :: Actor
	ControllerActor.Name = "Controller"
	ControllerActor.Parent = PlayerScripts

	const ControllerStorage = ClientObjects:WaitForChild("ObjectStorage"):Clone()
	ControllerStorage.Parent = ControllerActor

	const ReplicationFolder = ClientObjects:WaitForChild("Replication") :: Folder
	const ControllerSender = ReplicationFolder:WaitForChild("ReplicationSender"):Clone() :: LocalScript
	ControllerSender.Parent = ControllerActor

	const ControllerReceiver = ReplicationFolder:WaitForChild("ReplicationReceiver"):Clone() :: LocalScript
	ControllerReceiver.Parent = ControllerActor

	const CleanerScript = SceneFolder:WaitForChild("RendererCleaner"):Clone() :: LocalScript
	CleanerScript.Parent = ControllerActor

	-- Main client loop (physics -> rendering) runs inside the Controller Actor
	const MainScript = ClientFolder:WaitForChild("main"):Clone() :: LocalScript
	MainScript.Parent = ControllerActor
end

return RenderBootstrap
