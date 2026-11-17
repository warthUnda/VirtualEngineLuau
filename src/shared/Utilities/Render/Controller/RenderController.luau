--!strict
--!native
--!optimize 2

--[=[
	@class RenderController
	Singleton facade exposing active renderer controls, frame drawing, camera bindings,
	and viewport GUI access for the client software rasterizer.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const RenderRoot = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("Render")

-- Libraries --
const CameraService = require(RenderRoot:WaitForChild("Camera"):WaitForChild("CameraService"))
const RenderService = require(RenderRoot:WaitForChild("Core"):WaitForChild("RenderService"))

-- Variables --
local ActiveRenderer: RenderService.RenderObject = RenderService.New()

-- Tables --
local RenderController = {}

-- Functions --
-- ============================================================================
-- 1. SINGLETON RENDER CONTROLLER FACADE
-- ============================================================================

--[=[
	Constructs a new standalone OOP RenderService instance.
	@param Options RenderService.RenderOptions? -- Optional resolution, storage, camera, or GUI name overrides.
	@return RenderService.RenderObject -- Newly constructed OOP RenderObject.
]=]
function RenderController.New(Options: RenderService.RenderOptions?): RenderService.RenderObject
	return RenderService.New(Options)
end

--[=[
	Returns the active singleton OOP RenderObject managed by RenderController.
	@return RenderService.RenderObject -- Active RenderObject instance.
]=]
function RenderController.GetActiveRenderer(): RenderService.RenderObject
	return ActiveRenderer
end

--[=[
	Replaces the active singleton OOP RenderObject managed by RenderController.
	@param NewRenderer RenderService.RenderObject -- Target RenderObject to promote as active.
]=]
function RenderController.SetActiveRenderer(NewRenderer: RenderService.RenderObject)
	ActiveRenderer = NewRenderer
end

--[=[
	Initializes the active OOP RenderObject, creating its own ScreenGui and ImageLabel and binding workers.
	@param TargetParent Instance? -- Optional GUI container override (defaults to LocalPlayer.PlayerGui).
]=]
function RenderController.Init(TargetParent: Instance?)
	ActiveRenderer:Init(TargetParent, true)
end

--[=[
	Executes a frame gather, dynamic worker band partition, and rasterization dispatch on the active RenderObject.
	@return boolean -- True when a frame was dispatched; false if the previous frame is still in flight.
]=]
function RenderController.DrawFrame(): boolean
	return ActiveRenderer:DrawFrame()
end

--[=[
	Binds a custom OOP CameraObject to the active singleton renderer.
	@param CameraObj CameraService.CameraObject -- Target CameraObject to render from.
]=]
function RenderController.SetCamera(CameraObj: CameraService.CameraObject)
	ActiveRenderer:SetCamera(CameraObj)
end

--[=[
	Toggles visibility on the active singleton renderer's ScreenGui.
	@param Enabled boolean -- Visibility toggle state.
]=]
function RenderController.SetEnabled(Enabled: boolean)
	ActiveRenderer:SetEnabled(Enabled)
end

--[=[
	Returns the active singleton renderer's self-created ScreenGui (or nil if uninitialized).
	@return ScreenGui? -- Owned ScreenGui instance.
]=]
function RenderController.GetScreenGui(): ScreenGui?
	return ActiveRenderer:GetScreenGui()
end

--[=[
	Returns the active singleton renderer's full-screen ImageLabel (or nil if uninitialized).
	@return ImageLabel? -- Owned ImageLabel instance.
]=]
function RenderController.GetImageLabel(): ImageLabel?
	return ActiveRenderer:GetImageLabel()
end

--[=[
	Returns the active singleton renderer's bound EditableImage (or nil if uninitialized).
	@return EditableImage? -- Owned EditableImage instance.
]=]
function RenderController.GetEditableImage(): EditableImage?
	return ActiveRenderer:GetEditableImage()
end

RenderController.RenderFrame = RenderController.DrawFrame

return RenderController
