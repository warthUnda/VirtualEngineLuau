--!strict
--!native
--!optimize 2

--[=[
	@class main.client
	Main client entry point executed inside the Controller Actor VM.
	Initializes local physics, player input/camera controllers, and the software
	renderer, driving the unthrottled RenderStepped simulation and render loop.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const RunService = game:GetService("RunService") :: RunService

-- Static References --
-- Cloned into the Controller Actor by RenderBootstrap; skip execution in the PlayerScripts template copy.
const SelfActor = script:GetActor() :: Actor?
if not SelfActor then
	return
end

const SharedFolder = ReplicatedStorage:WaitForChild("Shared") :: Folder
const Utilities = SharedFolder:WaitForChild("Utilities") :: Folder

-- Libraries --
const ResourceController = require(Utilities:WaitForChild("ControllerTheory"))
const PhysicsController =
	require(Utilities:WaitForChild("Physics"):WaitForChild("Controller"):WaitForChild("PhysicsController"))
const PlayerController =
	require(Utilities:WaitForChild("Player"):WaitForChild("Controller"):WaitForChild("PlayerController"))
const ViewCulling = require(Utilities:WaitForChild("Render"):WaitForChild("Core"):WaitForChild("ViewCulling"))
const RenderLibrary = require(Utilities:WaitForChild("Render"):WaitForChild("RenderLibrary"))

-- Functions --
-- ============================================================================
-- 1. INITIALIZATION
-- ============================================================================

ResourceController.Initialize()
PhysicsController.InitializePhysics()
PlayerController.Initialize()
RenderLibrary.Init()

-- ============================================================================
-- 2. MAIN LOOP - SIMULATE PHYSICS & DRAW FRAME
-- ============================================================================

while true do
	const DeltaTime = RunService.RenderStepped:Wait() :: number
	ResourceController.BeginFrame()
	debug.profilebegin("SimulatePhysics")
	PhysicsController.SimulatePhysicsFrame(DeltaTime)
	PlayerController.StepClient(DeltaTime)
	ViewCulling.StepObserverSync(DeltaTime, PhysicsController.GetPlayerPosition())
	debug.profileend()
	debug.profilebegin("Render all instances")
	RenderLibrary.DrawFrame()
	debug.profileend()
	ResourceController.EndFrame(DeltaTime)
end
