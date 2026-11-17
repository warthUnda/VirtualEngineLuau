--!strict
--!native
--!optimize 2

--[=[
	@class CameraService
	Single-player OOP camera service managing virtual camera objects,
	active camera singletons, and RenderStepped workspace camera locking.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const RunService = game:GetService("RunService") :: RunService

-- Static References --
const IS_CLIENT = RunService:IsClient() :: boolean
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const CameraStepRunner = require(script.Parent.CameraStepRunner)
const CameraMethods = require(script.Parent.CameraMethods)

-- Configs --
const DEFAULT_CAMERA_CFRAME = SystemsConfigs.DefaultCameraCFrame :: CFrame
const DEFAULT_CAMERA_FOV = SystemsConfigs.DefaultCameraFOV :: number

export type CameraObject = {
	ClassName: string,
	CameraCFrame: CFrame,
	CameraFOV: number,
	CameraType: Enum.CameraType,
	CameraSubject: Instance?,
	CameraView: string,
	CharacterVisibility: string,
	CameraRotation: Vector2,
	LockMouse: boolean,
	Host: BasePart?,
	Active: boolean,
	ConnectionList: { RBXScriptConnection },
	SetCFrame: (self: CameraObject, NewCFrame: CFrame) -> (),
	SetCameraView: (self: CameraObject, ViewType: string?) -> (),
	SetCameraHost: (self: CameraObject, NewHost: BasePart?) -> (),
	ChangeSensitivity: (self: CameraObject, Val: number) -> (),
	ChangeFOV: (self: CameraObject, Val: number) -> (),
	GetCFrame: (self: CameraObject) -> CFrame,
	GetFOV: (self: CameraObject) -> number,
	Destroy: (self: CameraObject) -> (),
}

-- Variables --
local ActiveCamera: CameraObject = nil :: any

-- Tables --
local CameraService = {
	CharacterVisibility = "None" :: string,
	SetCFrame = CameraMethods.SetCFrame,
	SetCameraView = CameraMethods.SetCameraView,
	SetCameraHost = CameraMethods.SetCameraHost,
	ChangeSensitivity = CameraMethods.ChangeSensitivity,
	ChangeFOV = CameraMethods.ChangeFOV,
	GetCFrame = CameraMethods.GetCFrame,
	GetFOV = CameraMethods.GetFOV,
	Destroy = CameraMethods.Destroy,
}
CameraService.__index = CameraService

-- Functions --
-- ============================================================================
-- 1. OOP CAMERA CONSTRUCTOR & SINGLETON SERVICE FACADE
-- ============================================================================

--[=[
	Constructs a new OOP CameraService object.
	@param InitialCFrame CFrame? -- Optional initial camera CFrame (defaults to DefaultCameraCFrame).
	@param InitialFOV number? -- Optional initial vertical FOV in degrees (defaults to DefaultCameraFOV).
	@return CameraObject -- Newly constructed OOP CameraObject.
]=]
function CameraService.New(InitialCFrame: CFrame?, InitialFOV: number?): CameraObject
	const SeedCF = InitialCFrame or DEFAULT_CAMERA_CFRAME

	const RawCamera = {
		ClassName = "CameraService",
		CameraCFrame = SeedCF,
		CameraFOV = InitialFOV or DEFAULT_CAMERA_FOV,
		CameraType = Enum.CameraType.Scriptable,
		CameraSubject = nil :: Instance?,
		CameraView = "FirstPerson",
		CharacterVisibility = "None",
		CameraRotation = Vector2.zero,
		LockMouse = true,
		Host = nil :: BasePart?,
		Active = true,
		ConnectionList = {} :: { RBXScriptConnection },
	}

	const UntypedCam: any = setmetatable(RawCamera, CameraService)
	return UntypedCam :: CameraObject
end

--[=[
	Returns the active singleton OOP CameraObject managed by CameraService.
	@return CameraObject -- Active CameraObject instance.
]=]
function CameraService.GetActiveCamera(): CameraObject
	return ActiveCamera
end

--[=[
	Replaces the active singleton OOP CameraObject managed by CameraService.
	@param NewCamera CameraObject -- Target CameraObject to promote as active.
]=]
function CameraService.SetActiveCamera(NewCamera: CameraObject)
	ActiveCamera = NewCamera
	CameraService.CharacterVisibility = NewCamera.CharacterVisibility
end

ActiveCamera = CameraService.New(DEFAULT_CAMERA_CFRAME, DEFAULT_CAMERA_FOV)
CameraMethods.BindDefaultProvider(CameraService.GetActiveCamera)

if IS_CLIENT then
	RunService.RenderStepped:Connect(function()
		CameraStepRunner.LockWorkspaceCamera(ActiveCamera)
	end)
end

return CameraService
