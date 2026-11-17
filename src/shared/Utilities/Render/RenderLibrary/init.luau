--!strict
--!native
--!optimize 2

--[=[
	@class RenderLibrary
	Public singleton and OOP facade library for software rasterizer initialization,
	frame rendering, camera binding, and viewport GUI access.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const RenderRoot = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("Render")

-- Libraries --
const CameraService = require(RenderRoot:WaitForChild("Camera"):WaitForChild("CameraService"))
const RenderService = require(RenderRoot:WaitForChild("Core"):WaitForChild("RenderService"))
const RenderController = require(RenderRoot:WaitForChild("Controller"):WaitForChild("RenderController"))

-- Tables --
local RenderLibrary = {}

-- Functions --
-- ============================================================================
-- 1. PUBLIC RENDERER OOP & SINGLETON SERVICE FACADE LIBRARY
-- ============================================================================

--[=[
	Constructs a new OOP RenderObject that creates its own ScreenGui and ImageLabel when initialized.
	@param Options RenderService.RenderOptions? -- Optional viewport resolution, storage, camera, and GUI name overrides.
	@return RenderService.RenderObject -- Newly constructed OOP RenderObject.
]=]
function RenderLibrary.New(Options: RenderService.RenderOptions?): RenderService.RenderObject
	return RenderService.New(Options)
end

--[=[
	Returns the active singleton OOP RenderObject.
	@return RenderService.RenderObject -- Active RenderObject instance.
]=]
function RenderLibrary.GetActiveRenderer(): RenderService.RenderObject
	return RenderController.GetActiveRenderer()
end

--[=[
	Promotes an OOP RenderObject as the active singleton renderer.
	@param NewRenderer RenderService.RenderObject -- Target RenderObject instance.
]=]
function RenderLibrary.SetActiveRenderer(NewRenderer: RenderService.RenderObject)
	RenderController.SetActiveRenderer(NewRenderer)
end

--[=[
	Initializes the active singleton renderer, creating its ScreenGui and ImageLabel.
	@param TargetParent Instance? -- Optional GUI parent container (defaults to LocalPlayer.PlayerGui).
]=]
function RenderLibrary.Init(TargetParent: Instance?)
	RenderController.Init(TargetParent)
end

--[=[
	Dispatches a single render frame on the active singleton renderer.
	@return boolean -- True when dispatched; false when a prior frame is still in flight.
]=]
function RenderLibrary.DrawFrame(): boolean
	return RenderController.DrawFrame()
end

--[=[
	Binds an OOP CameraObject to the active singleton renderer.
	@param CameraObj CameraService.CameraObject -- Target CameraObject.
]=]
function RenderLibrary.SetCamera(CameraObj: CameraService.CameraObject)
	RenderController.SetCamera(CameraObj)
end

--[=[
	Toggles visibility on the active singleton renderer's ScreenGui.
	@param Enabled boolean -- Visibility toggle state.
]=]
function RenderLibrary.SetEnabled(Enabled: boolean)
	RenderController.SetEnabled(Enabled)
end

--[=[
	Returns the active singleton renderer's self-created ScreenGui (or nil if uninitialized).
	@return ScreenGui? -- Owned ScreenGui instance.
]=]
function RenderLibrary.GetScreenGui(): ScreenGui?
	return RenderController.GetScreenGui()
end

--[=[
	Returns the active singleton renderer's full-screen ImageLabel (or nil if uninitialized).
	@return ImageLabel? -- Owned ImageLabel instance.
]=]
function RenderLibrary.GetImageLabel(): ImageLabel?
	return RenderController.GetImageLabel()
end

--[=[
	Returns the active singleton renderer's bound EditableImage (or nil if uninitialized).
	@return EditableImage? -- Owned EditableImage instance.
]=]
function RenderLibrary.GetEditableImage(): EditableImage?
	return RenderController.GetEditableImage()
end

return RenderLibrary
