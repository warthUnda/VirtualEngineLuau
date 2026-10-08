--!native
--!optimize 2

-- Static References --
const ControllerActor =
	game:GetService("Players").LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Controller") :: Actor

const SelfActor = script.Parent :: Actor

-- Modules --
const BufferHelper = require(game.ReplicatedStorage.Shared.Utilities.BufferHelper) :: ModuleScript
const MathModule = require(game.ReplicatedStorage.Shared.Utilities.Render.RenderMath) :: ModuleScript
const RenderConfigs = require(game.StarterPlayer.StarterPlayerScripts.Client.Renderer.RenderConfigs) :: ModuleScript

-- Configs
const WIDTH: number, HEIGHT: number = RenderConfigs.ReturnDimensions2D()

const TOTAL_PIXELS = WIDTH * HEIGHT :: number

local BufferLayoutSize = 42 :: number
local ReadMemoryOffset = 0 :: number

-- Buffers
const FRSBuffer = buffer.create(4) :: buffer
const PixelBuffer = buffer.create(TOTAL_PIXELS * 4) :: buffer
const ZBuffer = buffer.create(TOTAL_PIXELS * 4) :: buffer

task.desynchronize()

-- ============================================================================
-- 1. LISTENER - LISTENS TO RETURNING DATA AND COMPUTING IT
-- ============================================================================

SelfActor:BindToMessageParallel("Execute Rendering", function(RenderBuffer: buffer, ByteCount: number, FrameId: number)
	BufferHelper.ClearBuffers(TOTAL_PIXELS, PixelBuffer, ZBuffer)

	ReadMemoryOffset = 0

	for i = 1, ByteCount / BufferLayoutSize do
		const V0X = buffer.readf32(RenderBuffer, ReadMemoryOffset) :: number
		const V0Y = buffer.readf32(RenderBuffer, ReadMemoryOffset + 4) :: number
		const V0Z = buffer.readf32(RenderBuffer, ReadMemoryOffset + 8) :: number

		const V1X = buffer.readf32(RenderBuffer, ReadMemoryOffset + 12) :: number
		const V1Y = buffer.readf32(RenderBuffer, ReadMemoryOffset + 16) :: number
		const V1Z = buffer.readf32(RenderBuffer, ReadMemoryOffset + 20) :: number

		const V2X = buffer.readf32(RenderBuffer, ReadMemoryOffset + 24) :: number
		const V2Y = buffer.readf32(RenderBuffer, ReadMemoryOffset + 28) :: number
		const V2Z = buffer.readf32(RenderBuffer, ReadMemoryOffset + 32) :: number

		const R = buffer.readu16(RenderBuffer, ReadMemoryOffset + 36) :: number
		const G = buffer.readu16(RenderBuffer, ReadMemoryOffset + 38) :: number
		const B = buffer.readu16(RenderBuffer, ReadMemoryOffset + 40) :: number

		const V0Vector = Vector3.new(V0X, V0Y, V0Z) :: Vector3
		const V1Vector = Vector3.new(V1X, V1Y, V1Z) :: Vector3
		const V2Vector = Vector3.new(V2X, V2Y, V2Z) :: Vector3

		MathModule.DrawTriangle(V0Vector, V1Vector, V2Vector, R, G, B, WIDTH, HEIGHT, PixelBuffer, ZBuffer, FRSBuffer)

		ReadMemoryOffset += BufferLayoutSize
	end

	ControllerActor:SendMessage("Return Render Calculations", PixelBuffer, ZBuffer, FrameId)
end)
