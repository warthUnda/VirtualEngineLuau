--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const ControllerActor = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Controller") :: Actor
const SelfActor = script.Parent :: Actor

-- Modules --
const BufferHelper = require(ReplicatedStorage.Shared.Utilities.Render.Core.BufferHelper)
const RenderMath = require(ReplicatedStorage.Shared.Utilities.Render.Core.RenderMath)
const RenderConfigs = require(ReplicatedStorage.Shared.Utilities.Render.RenderConfigs)

-- Configs --
const WIDTH: number, HEIGHT: number = RenderConfigs.GetDimensions2D()
const TOTAL_PIXELS = WIDTH * HEIGHT :: number
const BUFFER_LAYOUT_SIZE = BufferHelper.RenderBufferLayoutSize :: number

local ReadMemoryOffset = 0 :: number

-- Buffers
const PixelBuffer = buffer.create(TOTAL_PIXELS * 4) :: buffer
const ZBuffer = buffer.create(TOTAL_PIXELS * 4) :: buffer

task.desynchronize()

-- ============================================================================
-- 1. LISTENER - LISTENS TO RETURNING DATA AND COMPUTING IT
-- ============================================================================

SelfActor:BindToMessageParallel("Execute Rendering", function(RenderBuffer: buffer, ByteCount: number, FrameId: number)
	BufferHelper.ClearBuffers(TOTAL_PIXELS, PixelBuffer, ZBuffer)

	ReadMemoryOffset = 0

	for i = 1, ByteCount // BUFFER_LAYOUT_SIZE do
		const V0X = buffer.readi16(RenderBuffer, ReadMemoryOffset) :: number
		const V0Y = buffer.readi16(RenderBuffer, ReadMemoryOffset + 2) :: number
		const V0Z = buffer.readf32(RenderBuffer, ReadMemoryOffset + 4) :: number

		const V1X = buffer.readi16(RenderBuffer, ReadMemoryOffset + 8) :: number
		const V1Y = buffer.readi16(RenderBuffer, ReadMemoryOffset + 10) :: number
		const V1Z = buffer.readf32(RenderBuffer, ReadMemoryOffset + 12) :: number

		const V2X = buffer.readi16(RenderBuffer, ReadMemoryOffset + 16) :: number
		const V2Y = buffer.readi16(RenderBuffer, ReadMemoryOffset + 18) :: number
		const V2Z = buffer.readf32(RenderBuffer, ReadMemoryOffset + 20) :: number

		const PackedColor = buffer.readu32(RenderBuffer, ReadMemoryOffset + 24) :: number

		RenderMath.DrawTriangle(
			V0X,
			V0Y,
			V0Z,
			V1X,
			V1Y,
			V1Z,
			V2X,
			V2Y,
			V2Z,
			PackedColor,
			WIDTH,
			HEIGHT,
			PixelBuffer,
			ZBuffer
		)

		ReadMemoryOffset += BUFFER_LAYOUT_SIZE
	end

	ControllerActor:SendMessage("Return Render Calculations", PixelBuffer, ZBuffer, FrameId)
end)
