--!strict
--!native
--!optimize 2

--[=[
	@class CameraMethods
	Shared instance methods and facade resolution dispatchers for OOP CameraObject instances.
]=]

-- Services --
const RunService = game:GetService("RunService") :: RunService
const UserInputService = game:GetService("UserInputService") :: UserInputService

-- Static References --
const IS_CLIENT = RunService:IsClient() :: boolean

-- Libraries --
const CameraStepRunner = require(script.Parent.CameraStepRunner)

-- Variables --
local ActiveDefaultProvider: (() -> any)? = nil

-- Tables --
local CameraMethods = {}

-- Functions --
-- ============================================================================
-- 1. OOP CAMERA INSTANCE & FACADE METHODS (WITH PER-FRAME CACHING)
-- ============================================================================

--[=[
	Registers the fallback active camera provider so facade calls on CameraService resolve to ActiveCamera.
	@param Provider () -> any -- Accessor returning the active singleton CameraObject.
]=]
function CameraMethods.BindDefaultProvider(Provider: () -> any)
	ActiveDefaultProvider = Provider
end

--[=[
	Resolves either an explicit OOP CameraObject instance or the active singleton CameraObject.
	@param Candidate any -- Self parameter passed to a method call.
	@return any -- Resolved CameraObject instance.
]=]
function CameraMethods.ResolveCamera(Candidate: any): any
	if type(Candidate) == "table" and Candidate.ClassName == "CameraService" then
		return Candidate
	end
	if ActiveDefaultProvider then
		return ActiveDefaultProvider()
	end
	return Candidate
end

--[=[
	Updates the camera CFrame.
	@param self any -- OOP CameraObject or CameraService facade.
	@param NewCFrame CFrame -- Target world-space camera CFrame.
]=]
function CameraMethods.SetCFrame(self: any, NewCFrame: CFrame)
	const CamObj = CameraMethods.ResolveCamera(self)
	CamObj.CameraCFrame = NewCFrame
end

--[=[
	Activates or resets the single-player first-person input controller on the target camera.
	@param self any -- OOP CameraObject or CameraService facade.
	@param ViewType string? -- Optional view mode ("Default" disables custom look; otherwise "FirstPerson").
]=]
function CameraMethods.SetCameraView(self: any, ViewType: string?)
	const CamObj = CameraMethods.ResolveCamera(self)
	const ResolvedView = ViewType or "FirstPerson"
	CamObj.CameraView = ResolvedView
	CameraStepRunner.DisconnectAll(CamObj.ConnectionList)

	if ResolvedView == "Default" then
		CamObj.LockMouse = false
		CamObj.CameraType = Enum.CameraType.Custom
		if IS_CLIENT then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end
		return
	end

	CamObj.LockMouse = true
	CamObj.CameraType = Enum.CameraType.Scriptable
	CamObj.CameraSubject = nil
	if IS_CLIENT then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	end
	CameraStepRunner.BindInputs(CamObj)
end

--[=[
	Redirects camera focus to an explicit BasePart or resets to the simulated player position when nil.
	@param self any -- OOP CameraObject or CameraService facade.
	@param NewHost BasePart? -- Target focus part, or nil to follow PhysicsController.
]=]
function CameraMethods.SetCameraHost(self: any, NewHost: BasePart?)
	const CamObj = CameraMethods.ResolveCamera(self)
	CamObj.Host = NewHost
end

--[=[
	Sets UserInputService.MouseDeltaSensitivity to a positive multiplier.
	@param _self any -- OOP CameraObject or CameraService facade.
	@param Val number -- Sensitivity multiplier (> 0).
]=]
function CameraMethods.ChangeSensitivity(_self: any, Val: number)
	assert(type(Val) == "number" and Val > 0, "[CameraService] Sensitivity should be greater than 0.")
	if IS_CLIENT then
		UserInputService.MouseDeltaSensitivity = Val
	end
end

--[=[
	Immediately sets the vertical field of view in degrees.
	@param self any -- OOP CameraObject or CameraService facade.
	@param Val number -- Target FOV (> 0).
]=]
function CameraMethods.ChangeFOV(self: any, Val: number)
	assert(type(Val) == "number" and Val > 0, "[CameraService] FieldOfView should be greater than 0.")
	const CamObj = CameraMethods.ResolveCamera(self)
	CamObj.CameraFOV = Val
end

--[=[
	Returns the target camera's current world-space CFrame.
	@param self any -- OOP CameraObject or CameraService facade.
	@return CFrame -- Current camera CFrame.
]=]
function CameraMethods.GetCFrame(self: any): CFrame
	const CamObj = CameraMethods.ResolveCamera(self)
	return CamObj.CameraCFrame
end

--[=[
	Returns the target camera's vertical field of view in degrees.
	@param self any -- OOP CameraObject or CameraService facade.
	@return number -- Current vertical FOV in degrees.
]=]
function CameraMethods.GetFOV(self: any): number
	const CamObj = CameraMethods.ResolveCamera(self)
	return CamObj.CameraFOV
end

--[=[
	Disconnects all input/simulation listeners owned by this OOP CameraObject.
	@param self any -- OOP CameraObject instance.
]=]
function CameraMethods.Destroy(self: any)
	const CamObj = CameraMethods.ResolveCamera(self)
	CamObj.Active = false
	CameraStepRunner.DisconnectAll(CamObj.ConnectionList)
end

return CameraMethods
