--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")

const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const Utilities = SharedFolder:WaitForChild("Utilities")

-- Modules --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const PhysicsController =
	require(Utilities:WaitForChild("Physics"):WaitForChild("Controller"):WaitForChild("PhysicsController"))
const Renderer = require(Utilities:WaitForChild("Render"):WaitForChild("Controller"):WaitForChild("RenderController"))
const ViewCulling = require(Utilities:WaitForChild("Render"):WaitForChild("Core"):WaitForChild("ViewCulling"))

-- Configs --
const CORE_EVENTS_FOLDER_NAME = SystemsConfigs.CoreEventsFolderName :: string
const OBSERVER_REMOTE_EVENT_NAME = SystemsConfigs.ObserverRemoteEventName :: string
const OBSERVER_SYNC_INTERVAL = SystemsConfigs.ObserverSyncInterval :: number

-- Remote events
const CoreEvents = ReplicatedStorage:WaitForChild(CORE_EVENTS_FOLDER_NAME) :: Folder
const ObserverStateEvent = CoreEvents:WaitForChild(OBSERVER_REMOTE_EVENT_NAME) :: UnreliableRemoteEvent

-- Tables --
local SyncAccumulator = OBSERVER_SYNC_INTERVAL :: number

-- Buffers
const ObserverPayload = buffer.create(ViewCulling.ObserverPayloadBytes) :: buffer

-- ============================================================================
-- 1. INITIALIZATION
-- ============================================================================

PhysicsController.InitializePhysics()
Renderer.Init()

-- ============================================================================
-- 2. MAIN LOOP - SIMULATE PHYSICS, DRAW FRAME & STREAM VIRTUAL OBSERVER
-- ============================================================================

while true do
	const DeltaTime = RunService.RenderStepped:Wait() :: number
	PhysicsController.SimulatePhysicsFrame(DeltaTime)
	Renderer.DrawFrame()

	SyncAccumulator += DeltaTime
	if SyncAccumulator >= OBSERVER_SYNC_INTERVAL then
		SyncAccumulator = 0
		if ViewCulling.PackClientObserverState(ObserverPayload, PhysicsController.GetPlayerPosition()) then
			ObserverStateEvent:FireServer(ObserverPayload)
		end
	end
end
