--!strict
--!native
--!optimize 2

--[=[
	@class CameraLibrary
	Public singleton and OOP facade library for camera construction, active camera mutation,
	and camera state querying.
]=]

-- Libraries --
const CameraService = require(script.Parent:WaitForChild("CameraService"))

-- Tables --
local CameraLibrary = {}

-- Functions --
-- ============================================================================
-- 1. PUBLIC CAMERA OOP & SINGLETON SERVICE FACADE LIBRARY
-- ============================================================================

--[=[
	Constructs a new OOP CameraObject with per-frame cached basis vectors and projection scalars.
	@param InitialCFrame CFrame? -- Optional initial world CFrame.
	@param InitialFOV number? -- Optional initial vertical FOV in degrees.
	@return CameraService.CameraObject -- Newly constructed OOP CameraObject.
]=]
function CameraLibrary.New(InitialCFrame: CFrame?, InitialFOV: number?): CameraService.CameraObject
	return CameraService.New(InitialCFrame, InitialFOV)
end

--[=[
	Returns the active singleton OOP CameraObject.
	@return CameraService.CameraObject -- Active CameraObject instance.
]=]
function CameraLibrary.GetActiveCamera(): CameraService.CameraObject
	return CameraService.GetActiveCamera()
end

--[=[
	Sets the active singleton OOP CameraObject.
	@param NewCamera CameraService.CameraObject -- CameraObject to make active.
]=]
function CameraLibrary.SetActiveCamera(NewCamera: CameraService.CameraObject)
	CameraService.SetActiveCamera(NewCamera)
end

--[=[
	Configures the active camera's view mode ("FirstPerson" or "Default").
	@param ViewType string? -- Target camera view identifier.
]=]
function CameraLibrary.SetCameraView(ViewType: string?)
	CameraService:SetCameraView(ViewType)
end

--[=[
	Binds an optional BasePart focus host on the active camera (or nil to follow simulated player position).
	@param NewHost BasePart? -- Optional focus BasePart.
]=]
function CameraLibrary.SetCameraHost(NewHost: BasePart?)
	CameraService:SetCameraHost(NewHost)
end

--[=[
	Sets the active camera's world CFrame and refreshes its per-frame cache.
	@param NewCFrame CFrame -- Target world CFrame.
]=]
function CameraLibrary.SetCFrame(NewCFrame: CFrame)
	CameraService:SetCFrame(NewCFrame)
end

--[=[
	Immediately updates the active camera's vertical field of view in degrees.
	@param Val number -- Target vertical FOV (> 0).
]=]
function CameraLibrary.ChangeFOV(Val: number)
	CameraService:ChangeFOV(Val)
end

--[=[
	Updates desktop mouse look sensitivity (> 0).
	@param Val number -- Mouse sensitivity multiplier.
]=]
function CameraLibrary.ChangeSensitivity(Val: number)
	CameraService:ChangeSensitivity(Val)
end

--[=[
	Returns the active camera's current world-space CFrame.
	@return CFrame -- Current camera CFrame.
]=]
function CameraLibrary.GetCFrame(): CFrame
	return CameraService:GetCFrame()
end

--[=[
	Returns the active camera's vertical field of view in degrees.
	@return number -- Current vertical FOV in degrees.
]=]
function CameraLibrary.GetFOV(): number
	return CameraService:GetFOV()
end

return CameraLibrary
