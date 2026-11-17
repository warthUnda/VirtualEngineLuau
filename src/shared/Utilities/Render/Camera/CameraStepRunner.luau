--!strict
--!native
--!optimize 2

--[=[
	@class CameraStepRunner
	Executes simulated player eye stepping, UserInputService bindings,
	and workspace camera locking.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const RunService = game:GetService("RunService") :: RunService
const UserInputService = game:GetService("UserInputService") :: UserInputService

-- Static References --
const IS_CLIENT = RunService:IsClient() :: boolean
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const UtilitiesFolder = SharedFolder:WaitForChild("Utilities")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const CameraHelper = require(script.Parent.CameraHelper)

-- Configs --
const PLAYER_EYE_OFFSET = SystemsConfigs.CameraPlayerEyeOffset :: number
const EYE_OFFSET_VEC = Vector3.new(0, PLAYER_EYE_OFFSET, 0) :: Vector3
const MAX_PITCH_RAD = math.rad(SystemsConfigs.CameraMaxVerticalAngle :: number) :: number
const MOUSE_UNLOCK_KEY = SystemsConfigs.CameraMouseUnlockKey :: Enum.KeyCode
const FIXED_POSITION = SystemsConfigs.CameraFixedPosition :: Vector3

-- Variables --
local CachedPhysicsController: { GetPlayerPosition: () -> Vector3 }? = nil

-- Tables --
local CameraStepRunner = {}

-- Functions --
-- ============================================================================
-- 1. WORKSPACE CAMERA LOCKING, SINGLE-PLAYER STEPPING & INPUT BINDING
-- ============================================================================

--[=[
	Parks Workspace.CurrentCamera at FIXED_POSITION matching the camera object's orientation.
	@param CamObj any -- Target OOP CameraObject instance.
]=]
function CameraStepRunner.LockWorkspaceCamera(CamObj: any)
	if not IS_CLIENT then
		return
	end

	const ActiveCamera = workspace.CurrentCamera
	if not ActiveCamera then
		return
	end

	if ActiveCamera.CameraType ~= Enum.CameraType.Scriptable then
		ActiveCamera.CameraType = Enum.CameraType.Scriptable
	end
	const CurrentCF = CamObj.CameraCFrame :: CFrame
	const TargetRotation = CameraHelper.VectorsToRotation(
		CurrentCF.LookVector,
		CurrentCF.UpVector,
		CurrentCF.RightVector
	)
	ActiveCamera.CFrame = CFrame.new(FIXED_POSITION) * TargetRotation
end

--[=[
	Disconnects all active camera input and simulation connections on a CameraObject.
	@param Connections { RBXScriptConnection } -- Connection list to clear.
]=]
function CameraStepRunner.DisconnectAll(Connections: { RBXScriptConnection })
	for _, Connection: RBXScriptConnection in ipairs(Connections) do
		Connection:Disconnect()
	end
	table.clear(Connections)
end

--[=[
	Updates the OOP camera's CFrame from the simulated player eye position and refreshes its per-frame cache.
	@param CamObj any -- Target OOP CameraObject instance.
]=]
function CameraStepRunner.StepCamera(CamObj: any)
	if not CachedPhysicsController then
		const ResolvedPhysics: any = require(
			UtilitiesFolder:WaitForChild("Physics"):WaitForChild("Controller"):WaitForChild("PhysicsController")
		)
		CachedPhysicsController = ResolvedPhysics
	end
	const PhysicsMod = CachedPhysicsController :: { GetPlayerPosition: () -> Vector3 }

	const CustomHost = CamObj.Host :: BasePart?
	const EyePos = if CustomHost and CustomHost.Parent
		then CustomHost.Position
		else PhysicsMod.GetPlayerPosition() + EYE_OFFSET_VEC :: Vector3

	const Rot = CamObj.CameraRotation :: Vector2
	CamObj.CameraCFrame = CFrame.new(EyePos) * CFrame.fromEulerAnglesYXZ(Rot.Y, Rot.X, 0)
end

--[=[
	Binds desktop mouse-look, LeftAlt mouse-lock toggle, and PostSimulation updates to a CameraObject.
	@param CamObj any -- Target OOP CameraObject instance.
]=]
function CameraStepRunner.BindInputs(CamObj: any)
	if not IS_CLIENT then
		return
	end

	const Connections = CamObj.ConnectionList :: { RBXScriptConnection }

	table.insert(Connections, UserInputService.InputBegan:Connect(function(Input: InputObject, GameProcessed: boolean)
		if GameProcessed or Input.KeyCode ~= MOUSE_UNLOCK_KEY then
			return
		end
		CamObj.LockMouse = not CamObj.LockMouse
		UserInputService.MouseBehavior = if CamObj.LockMouse
			then Enum.MouseBehavior.LockCenter
			else Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = not CamObj.LockMouse
	end))

	table.insert(Connections, UserInputService.InputChanged:Connect(function(Input: InputObject, GameProcessed: boolean)
		if GameProcessed or Input.UserInputState ~= Enum.UserInputState.Change then
			return
		end
		const RightHold = (CamObj.LockMouse or UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)) :: boolean
		if not RightHold then
			return
		end
		CamObj.CameraRotation = CameraHelper.ComputeLookRotation(CamObj.CameraRotation, Input.Delta, MAX_PITCH_RAD)
	end))

	table.insert(Connections, RunService.PostSimulation:Connect(function()
		CameraStepRunner.StepCamera(CamObj)
	end))
end

return CameraStepRunner
