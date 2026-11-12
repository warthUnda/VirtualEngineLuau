--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const RunService = game:GetService("RunService") :: RunService

-- Static References --
const SelfActor = script:GetActor() :: Actor?
if not SelfActor then
	return
end

const Utilities = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities") :: Folder

-- Modules --
const PhysicsController =
	require(Utilities:WaitForChild("Physics"):WaitForChild("Controller"):WaitForChild("PhysicsController"))

const Renderer = require(Utilities:WaitForChild("Render"):WaitForChild("Controller"):WaitForChild("RenderController"))

-- ============================================================================
-- 1. INITIALIZATION
-- ============================================================================

const RenderBootstrap = require(script.Parent.RenderBootstrap)

RenderBootstrap.CreateSetup()

PhysicsController.InitializePhysics()
Renderer.Init()

-- ============================================================================
-- 2. MAIN LOOP - SIMULATE PHYSICS THEN DRAW FRAME
-- ============================================================================

while true do
	const DeltaTime = RunService.RenderStepped:Wait() :: number
	PhysicsController.SimulatePhysicsFrame(DeltaTime)
	Renderer.DrawFrame()
end
