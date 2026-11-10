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
const PhysicsController = require(
	Utilities:WaitForChild("Physics")
		:WaitForChild("Controller")
		:WaitForChild("PhysicsController")
) :: ModuleScript

const Renderer = require(
	Utilities:WaitForChild("Render")
		:WaitForChild("Controller")
		:WaitForChild("RenderController")
) :: ModuleScript

-- ============================================================================
-- 1. INITIALIZATION
-- ============================================================================

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
