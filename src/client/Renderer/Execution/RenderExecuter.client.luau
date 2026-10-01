--!native
--!optimize 2

-- Caching --
local ClearTable = table.clear
local Floor = math.floor

local Round = math.round

-- Static References --
local Player = game:GetService("Players").LocalPlayer :: Player
local PlayerGui = Player:WaitForChild("PlayerGui") :: PlayerGui

local Camera = workspace.CurrentCamera :: Camera

local ImageLabel = PlayerGui:WaitForChild("ScreenGui").ImageLabel :: ImageLabel

-- Services --
local AssetService = game:GetService("AssetService") :: AssetService
local RunService = game:GetService("RunService") :: RunService

local MathModule = require(game.StarterPlayer.StarterPlayerScripts.Client.Renderer.Execution.MathModule) :: ModuleScript
local RenderConfigs = require(game.StarterPlayer.StarterPlayerScripts.Client.Renderer.RenderConfigs) :: ModuleScript
local PartStore = require(game.StarterPlayer.StarterPlayerScripts.Client.Renderer.Stores.PartStores) :: ModuleScript

-- Configs
local WIDTH = 240 :: number
local HEIGHT = 120 :: number
local TOTAL_PIXELS = WIDTH * HEIGHT :: number
local BUFFER_SIZE = TOTAL_PIXELS * 4 :: number

local PixelBuffer = buffer.create(BUFFER_SIZE) :: buffer
local ZBuffer = table.create(TOTAL_PIXELS, 1000.0) :: { number }

local PART_TRIANGLES = RenderConfigs.GetPartTriangles() :: { { number } }

local WorldVertices = table.create(8)

-- CONNECTING IMAGE + EDITABLE IMAGE
local EditableImage = AssetService:CreateEditableImage({
	Size = Vector2.new(WIDTH, HEIGHT),
}) :: EditableImage
ImageLabel.ImageContent = Content.fromObject(EditableImage) :: Content

-- ============================================================================
-- 1. RENDER LOOP
-- ============================================================================

RunService.RenderStepped:Connect(function()
	const Clock = os.clock() :: number
	MathModule.ClearBuffers(TOTAL_PIXELS, PixelBuffer, ZBuffer)

	local PartArray = PartStore.ReturnArray() :: { BasePart }

	const CamCFrame = Camera.CFrame :: CFrame
	const CamFOV = Camera.FieldOfView :: number

	local ScreenVertices = {} :: { Vector2 }

	for i = 1, #PartArray do
		const TargetPart = PartArray[i] :: BasePart

		if not TargetPart then
			continue
		end

		const PartColor = TargetPart.Color :: Color3
		const R = Floor(PartColor.R * 255) :: number
		const G = Floor(PartColor.G * 255) :: number
		const B = Floor(PartColor.B * 255) :: number

		MathModule.GetPartWorldVertices(TargetPart, WorldVertices)

		for i, WorldPos in ipairs(WorldVertices) do
			ScreenVertices[i] =
				MathModule.ProjectWorldPointToScreen(WorldPos, CamCFrame, CamFOV, WIDTH, HEIGHT) :: Vector3
		end

		for TriangleIndex = 1, #PART_TRIANGLES do
			const tri = PART_TRIANGLES[TriangleIndex] :: { number }
			const v0 = ScreenVertices[tri[1]] :: Vector3
			const v1 = ScreenVertices[tri[2]] :: Vector3
			const v2 = ScreenVertices[tri[3]] :: Vector3

			if v0 and v1 and v2 then
				MathModule.DrawTriangle(v0, v1, v2, R, G, B, WIDTH, HEIGHT, PixelBuffer, ZBuffer)
			end
		end

		ClearTable(ScreenVertices)
	end

	EditableImage:WritePixelsBuffer(Vector2.zero, Vector2.new(WIDTH, HEIGHT), PixelBuffer)
	print("Rendering took " .. (os.clock() - Clock) .. " seconds")
end)
