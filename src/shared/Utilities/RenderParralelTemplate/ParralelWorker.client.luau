local Actor = script.Parent :: Actor

local BufferHelper = require(game.ReplicatedStorage.Shared.Utilities.BufferHelper)
local MathModule = require(game.ReplicatedStorage.Shared.Utilities.Render.MathModule) :: ModuleScript

local WIDTH = 240 :: number
local HEIGHT = 120 :: number
local TOTAL_PIXELS = WIDTH * HEIGHT :: number

local BufferLayoutSize = 46
local ReadMemoryOffset = 0

local FRSBuffer = buffer.create(4)
local PixelBuffer = buffer.create(TOTAL_PIXELS * 4)
local ZBuffer = buffer.create(TOTAL_PIXELS * 4)

Actor:BindToMessage("Execute Renderer", function(RenderBuffer: buffer)
	MathModule.ClearBuffers(TOTAL_PIXELS, PixelBuffer, ZBuffer)

	for i = 1, BufferLayoutSize / 38 do
		local V0X = buffer.readf32(RenderBuffer, ReadMemoryOffset)
		local V0Y = buffer.readf32(RenderBuffer, ReadMemoryOffset + 4)
		local V0Z = buffer.readf32(RenderBuffer, ReadMemoryOffset + 8)

		local V1X = buffer.readf32(RenderBuffer, ReadMemoryOffset + 12)
		local V1Y = buffer.readf32(RenderBuffer, ReadMemoryOffset + 16)
		local V1Z = buffer.readf32(RenderBuffer, ReadMemoryOffset + 20)

		local V2X = buffer.readf32(RenderBuffer, ReadMemoryOffset + 24)
		local V2Y = buffer.readf32(RenderBuffer, ReadMemoryOffset + 28)
		local V2Z = buffer.readf32(RenderBuffer, ReadMemoryOffset + 32)

		local R = buffer.readu16(RenderBuffer, ReadMemoryOffset + 36)
		local G = buffer.readu16(RenderBuffer, ReadMemoryOffset + 38)
		local B = buffer.readu16(RenderBuffer, ReadMemoryOffset + 40)

		local WIDTH = buffer.readu16(RenderBuffer, ReadMemoryOffset + 42)
		local HEIGHT = buffer.readu16(RenderBuffer, ReadMemoryOffset + 44)

		local V0Vector = Vector3.new(V0X, V0Y, V0Z)
		local V1Vector = Vector3.new(V1X, V1Y, V1Z)
		local V2Vector = Vector3.new(V2X, V2Y, V2Z)

		MathModule.DrawTriangle(V0Vector, V1Vector, V2Vector, R, G, B, WIDTH, HEIGHT, PixelBuffer, ZBuffer, FRSBuffer)

		ReadMemoryOffset += BufferLayoutSize
	end
end)
