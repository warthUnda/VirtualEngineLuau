--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const RunService = game:GetService("RunService") :: RunService
const UserInputService = game:GetService("UserInputService") :: UserInputService

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const PhysicsController = require(
	SharedFolder:WaitForChild("Utilities"):WaitForChild("Physics"):WaitForChild("Controller"):WaitForChild("PhysicsController")
)
const CameraStore = require(script.Parent.CameraStore)
const CameraHelper = require(script.Parent.CameraHelper)
const CameraPresets = require(script.Parent.CameraPresets)
const CameraRigHelper = require(script.Parent.CameraRigHelper)

-- Configs --
const MOUSE_UNLOCK_KEY = SystemsConfigs.CameraMouseUnlockKey :: Enum.KeyCode
const PLAYER_EYE_OFFSET = SystemsConfigs.CameraPlayerEyeOffset :: number
const EYE_OFFSET_VEC = Vector3.new(0, PLAYER_EYE_OFFSET, 0) :: Vector3
const CamTable = CameraStore.GetCameraTable()

-- Tables --
local CameraStepRunner = {}

-- Functions --
-- ============================================================================
-- 1. CONNECTION CLEANUP, PER-FRAME STEPPING & INPUT WIRING
-- ============================================================================

--[=[
	Disconnects and clears all active RBXScriptConnections for the current camera view.
	@param ConnectionList { RBXScriptConnection } -- Mutable list of active connections.
]=]
function CameraStepRunner.DisconnectAll(ConnectionList: { RBXScriptConnection })
	for _, Connection: RBXScriptConnection in ipairs(ConnectionList) do
		Connection:Disconnect()
	end
	table.clear(ConnectionList)
end

--[=[
	Advances camera orientation, smoothing, BVH raycast occlusion, and character rig alignment by one frame.
	@param State CameraPresets.CameraRuntimeState -- Mutable camera runtime state.
	@param Service any -- CameraService singleton table.
	@param Mouse Mouse -- LocalPlayer mouse instance.
	@param DeltaTime number -- Frame delta time in seconds.
]=]
function CameraStepRunner.StepCamera(
	State: CameraPresets.CameraRuntimeState,
	Service: any,
	Mouse: Mouse,
	DeltaTime: number
)
	if State.CurrentCharacter and not State.CurrentCharacter.Parent then
		State.CurrentCharacter = nil
		State.WaistCache = nil
		State.NeckCache = nil
		if not State.CustomHost then
			Service.Host = nil
		end
	end
	if State.CustomHost and not State.CustomHost.Parent then
		State.CustomHost = nil
		Service.Host = nil
	end

	if UserInputService.GamepadEnabled then
		State.CameraRotation -= State.DifferenceVector
	else
		State.DifferenceVector = Vector2.zero
	end

	const PitchLimit = math.rad(Service.Angle) :: number
	State.CameraRotation = Vector2.new(
		if Service.xLock then Service.atX else State.CameraRotation.X,
		if Service.yLock then Service.atY else math.clamp(State.CameraRotation.Y, -PitchLimit, PitchLimit)
	)

	if State.CustomHost and State.CustomHost.Parent then
		State.CurrentCamPosition = State.CustomHost.Position
	else
		State.CurrentCamPosition = PhysicsController.GetPlayerPosition() + EYE_OFFSET_VEC
	end

	if UserInputService:IsKeyDown(Enum.KeyCode.Right) then
		State.ArrowKeyAngle += 3 * DeltaTime
	elseif UserInputService:IsKeyDown(Enum.KeyCode.Left) then
		State.ArrowKeyAngle -= 3 * DeltaTime
	end

	local RotationCFrame = CFrame.fromEulerAnglesYXZ(State.CameraRotation.Y, State.CameraRotation.X - State.ArrowKeyAngle, 0) :: CFrame
	State.UpdateShake = if State.UpdateShake < math.random(2, 3) then State.UpdateShake + 1 else 0
	if Service.Shaking then
		if State.UpdateShake == 0 then
			State.ShakeOffset = CameraHelper.CalculateShakingOffset(Service.ShakingIntensity, Service.CharacterVisibility, Service.Smoothness)
		end
	else
		State.ShakeOffset = Vector3.zero
	end

	const WobbleOffset = CameraRigHelper.ComputeFootWobble(State.CurrentCharacter, Service.Wobble, State.CustomHost)
	const DesiredTime = Service.Smoothness ^ 2 * 0.05 + 0.02 * Service.Smoothness + 0.005 :: number
	const LerpFactor = 1 - math.exp(-DeltaTime / DesiredTime) :: number

	if Service.MinZoom == 0 and Service.MaxZoom == 0 and Service.RotSmoothness > Service.Smoothness and Service.RotSmoothness > 0 then
		const DesiredRotTime = Service.RotSmoothness ^ 2 * 0.05 + 0.02 * Service.RotSmoothness + 0.005 :: number
		RotationCFrame = State.PastCamRot:Lerp(RotationCFrame, 1 - math.exp(-DeltaTime / DesiredRotTime))
	end

	State.PastCamRot = RotationCFrame
	const RawCamCFrame = (RotationCFrame * Service.Offset * Service.TiltFactor)
		+ State.CurrentCamPosition
		+ State.ShakeOffset
		+ (RotationCFrame * Vector3.new(0, 0, Service.Zoom))
	const FocusOrigin = State.CurrentCamPosition + State.ShakeOffset :: Vector3
	const ClampedPos = CameraHelper.RaycastWorld(
		FocusOrigin,
		RawCamCFrame.Position - FocusOrigin,
		State.CurrentCharacter,
		Service.Host
	)
	const CamCFrame = (RawCamCFrame - RawCamCFrame.Position) + ClampedPos :: CFrame
	const TargetCFrame = CamTable.CameraCFrame:Lerp(CamCFrame, LerpFactor) :: CFrame

	local DesiredVertical = DesiredTime :: number
	if Service.Zoom > 0 and Service.Smoothness > 0 then
		DesiredVertical, State.Lapsed = CameraHelper.ComputeVerticalDamping(
			DesiredTime, DeltaTime, State.Lapsed, State.CurrentCharacter, PhysicsController.IsPlayerGrounded()
		)
	end

	const ResolvedY = if DesiredVertical ~= DesiredTime
		then CamTable.CameraCFrame:Lerp(CamCFrame, 1 - math.exp(-DeltaTime / DesiredVertical)).Y
		else TargetCFrame.Y :: number

	CamTable.CameraCFrame = if Service.Smoothness <= 0
		then CamCFrame
		else CFrame.new(TargetCFrame.X, ResolvedY, TargetCFrame.Z) * TargetCFrame.Rotation * WobbleOffset

	CameraRigHelper.UpdateCharacterRig(State, Service, CamCFrame, Mouse)
end

--[=[
	Binds touch, keyboard, pointer, and PostSimulation frame listeners for a non-Default camera view.
	@param State CameraPresets.CameraRuntimeState -- Mutable camera runtime state.
	@param Service any -- CameraService singleton table.
	@param Mouse Mouse -- LocalPlayer mouse instance.
	@param ViewType string -- Active camera view identifier.
]=]
function CameraStepRunner.BindViewInputs(
	State: CameraPresets.CameraRuntimeState,
	Service: any,
	Mouse: Mouse,
	ViewType: string
)
	const Connections = State.ConnectionList
	const OnInputChange = function(Input: InputObject, GameProcessed: boolean)
		Service.Zoom = CameraHelper.ComputeZoomFromInput(Input, GameProcessed, Service.Zoom, Service.MinZoom, Service.MaxZoom)
		const RightHold = (Service.LockMouse or UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)) :: boolean
		State.Delta, State.DifferenceVector, State.CameraRotation = CameraHelper.ComputeLookRotation(
			Input, GameProcessed, RightHold, State.CameraRotation,
			Service.xLock, Service.atX, Service.yLock, Service.atY,
			Service.Angle, State.Delta, State.DifferenceVector
		)
		UserInputService.MouseBehavior = if Service.LockMouse
			then Enum.MouseBehavior.LockCenter
			elseif RightHold then Enum.MouseBehavior.LockCurrentPosition
			else Enum.MouseBehavior.Default
	end

	if UserInputService.TouchEnabled then
		table.insert(Connections, UserInputService.TouchPan:Connect(OnInputChange :: any))
		table.insert(Connections, UserInputService.TouchRotate:Connect(OnInputChange :: any))
		local PinchDelta = 0 :: number
		table.insert(Connections, UserInputService.TouchPinch:Connect(function(_, Scale: number, _, TouchState: Enum.UserInputState, GameProcessed: boolean)
			if not GameProcessed and TouchState ~= Enum.UserInputState.Begin then
				Service.Zoom = math.clamp(Service.Zoom - (Scale - PinchDelta) * 20, Service.MinZoom, Service.MaxZoom)
			end
			PinchDelta = Scale
		end))
	end

	table.insert(Connections, UserInputService.InputBegan:Connect(function(Input: InputObject, GameProcessed: boolean)
		if not GameProcessed and Input.KeyCode == MOUSE_UNLOCK_KEY then
			Service.LockMouse = not Service.LockMouse
			UserInputService.MouseBehavior = if Service.LockMouse then Enum.MouseBehavior.LockCenter else Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = (not Service.LockMouse or ViewType ~= "FirstPerson")
			return
		end
		OnInputChange(Input, GameProcessed)
	end))
	table.insert(Connections, UserInputService.InputChanged:Connect(OnInputChange))
	table.insert(Connections, UserInputService.InputEnded:Connect(OnInputChange))
	table.insert(Connections, RunService.PostSimulation:Connect(function(DeltaTime: number)
		CameraStepRunner.StepCamera(State, Service, Mouse, DeltaTime)
	end))
end

return CameraStepRunner
