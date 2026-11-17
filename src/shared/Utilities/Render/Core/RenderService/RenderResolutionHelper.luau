--!strict
--!native
--!optimize 2

--[=[
	@class RenderResolutionHelper
	Applies closed-loop dynamic viewport resolution scaling from ResourceController and
	ControllerInterpreter onto an OOP RenderObject. Treats RenderConfig.RenderWidth and
	RenderConfig.RenderHeight as pre-allocated maximum buffer ceilings and keeps the single
	permanent EditableImage intact (updating ImageLabel.ImageRectSize atomically upon frame
	upload) so scaling never flickers or invalidates buffers.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const UtilitiesFolder = SharedFolder:WaitForChild("Utilities")
const ControllerTheoryRoot = UtilitiesFolder:WaitForChild("ControllerTheory")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ResourceController =
	require(ControllerTheoryRoot:WaitForChild("Controller"):WaitForChild("ResourceController"))
const ControllerInterpreter =
	require(ControllerTheoryRoot:WaitForChild("Core"):WaitForChild("ControllerInterpreter"))

-- Configs --
const MAX_RENDER_WIDTH = SystemsConfigs.RenderWidth :: number
const MAX_RENDER_HEIGHT = SystemsConfigs.RenderHeight :: number
const UPSCALE_HYSTERESIS_PIXELS = 8 :: number

-- Tables --
local RenderResolutionHelper = {}

-- Functions --
-- ============================================================================
-- 1. FLICKER-FREE VIEWPORT RESOLUTION RESIZING & CONTROLLER SYNCHRONIZATION
-- ============================================================================

--[=[
	Updates active (Width, Height) within the RenderConfig maximum ceiling without recreating
	EditableImage or invalidating pre-allocated staging/scanline/worker buffers.
	@param RendererObj any -- Target OOP RenderObject instance.
	@param NewWidth number -- Desired viewport width in pixels.
	@param NewHeight number -- Desired viewport height in pixels.
]=]
function RenderResolutionHelper.ResizeRenderer(RendererObj: any, NewWidth: number, NewHeight: number)
	const CeilingWidth = math.min(RendererObj.BaseWidth :: number, MAX_RENDER_WIDTH) :: number
	const CeilingHeight = math.min(RendererObj.BaseHeight :: number, MAX_RENDER_HEIGHT) :: number
	const ClampedWidth = math.clamp(math.floor(NewWidth), 1, CeilingWidth) :: number
	const ClampedHeight = math.clamp(math.floor(NewHeight), 1, CeilingHeight) :: number

	if ClampedWidth == RendererObj.Width and ClampedHeight == RendererObj.Height then
		return
	end

	RendererObj.Width = ClampedWidth
	RendererObj.Height = ClampedHeight
	RendererObj.ImageSize = Vector2.new(ClampedWidth, ClampedHeight)
	RendererObj.CachedProjWidth = -1
	RendererObj.CachedProjHeight = -1
	RendererObj.FinalPixel = buffer.create(ClampedWidth * ClampedHeight * 4)

	-- Zero active prefix of pre-allocated maximum RowWorkDiff so no stale deltas cross resolution steps
	buffer.fill(RendererObj.RowWorkDiff :: buffer, 0, 0, (ClampedHeight + 1) * 4)
end

--[=[
	Evaluates ResourceController's current 1..100 Renderer score through ControllerInterpreter
	and applies viewport resolution steps with upward hysteresis when no worker frame is in flight.
	@param RendererObj any -- Target OOP RenderObject instance.
]=]
function RenderResolutionHelper.SyncAdaptiveResolution(RendererObj: any)
	if RendererObj.FrameInFlight then
		return
	end

	const CeilingWidth = math.min(RendererObj.BaseWidth :: number, MAX_RENDER_WIDTH) :: number
	const CeilingHeight = math.min(RendererObj.BaseHeight :: number, MAX_RENDER_HEIGHT) :: number
	const RendererScore = ResourceController.GetRendererScore() :: number
	const TargetWidth: number, TargetHeight: number =
		ControllerInterpreter.InterpretRenderer(RendererScore, CeilingWidth, CeilingHeight)

	const CurrentWidth = RendererObj.Width :: number
	const CurrentHeight = RendererObj.Height :: number
	if TargetWidth == CurrentWidth and TargetHeight == CurrentHeight then
		return
	end

	-- Apply downward throttles immediately; require >= 8px step (or full native restoration) when scaling up
	if TargetWidth > CurrentWidth and TargetWidth < CeilingWidth and (TargetWidth - CurrentWidth) < UPSCALE_HYSTERESIS_PIXELS then
		return
	end

	RenderResolutionHelper.ResizeRenderer(RendererObj, TargetWidth, TargetHeight)
end

return RenderResolutionHelper
