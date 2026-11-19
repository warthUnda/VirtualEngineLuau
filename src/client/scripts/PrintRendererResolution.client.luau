--!strict
--!native
--!optimize 2

--[=[
	@class PrintRendererResolution.client
	Client utility script that checks the active software renderer's viewport
	width and height from its live ViewportLabel and prints the resolution.
]=]

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const LocalPlayer = Players.LocalPlayer :: Player
const PlayerGui = LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))

-- Configs --
const SCREEN_GUI_NAME = SystemsConfigs.RendererScreenGuiName :: string
const IMAGE_LABEL_NAME = SystemsConfigs.RendererImageLabelName :: string
const CONFIG_WIDTH = SystemsConfigs.RenderWidth :: number
const CONFIG_HEIGHT = SystemsConfigs.RenderHeight :: number

-- ============================================================================
-- 1. CHECK & PRINT ACTIVE RENDERER WIDTH AND HEIGHT
-- ============================================================================

const RendererGui = PlayerGui:WaitForChild(SCREEN_GUI_NAME) :: ScreenGui
const ViewportLabel = RendererGui:WaitForChild(IMAGE_LABEL_NAME) :: ImageLabel
const ActiveSize = ViewportLabel.ImageRectSize :: Vector2

print(
	string.format(
		"[RendererResolution] Active: %dx%d (Configured Max: %dx%d)",
		ActiveSize.X,
		ActiveSize.Y,
		CONFIG_WIDTH,
		CONFIG_HEIGHT
	)
)
