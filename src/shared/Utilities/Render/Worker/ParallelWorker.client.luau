--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const ControllerActor = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Controller") :: Actor
const SelfActor = script.Parent :: Actor

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const BufferHelper = require(ReplicatedStorage.Shared.Utilities.Render.Core.BufferHelper)
const RenderMath = require(ReplicatedStorage.Shared.Utilities.Render.Core.RenderMath)
const TextureTable = require(ReplicatedStorage.Shared.Utilities.Render.Texture.TextureTable)

-- Configs --
const WIDTH = SystemsConfigs.RenderWidth :: number
const HEIGHT = SystemsConfigs.RenderHeight :: number
const TOTAL_PIXELS = WIDTH * HEIGHT :: number
const TEXTURE_SIZE = SystemsConfigs.TextureSize :: number

local DirtyMinY = 0 :: number
local DirtyMaxY = -1 :: number
local TextureBuffers = TextureTable.GetAllCachedBuffers() :: { [number]: buffer }
local TextureWidth = TEXTURE_SIZE :: number
local TextureHeight = TEXTURE_SIZE :: number

-- Buffers
const EmptyPayload = buffer.create(0) :: buffer
const PixelBuffer = buffer.create(TOTAL_PIXELS * 4) :: buffer
const ZBuffer = buffer.create(TOTAL_PIXELS * 4) :: buffer
const ROW_STRIDE = WIDTH * 4 :: number

BufferHelper.ClearBuffers(TOTAL_PIXELS, PixelBuffer, ZBuffer)

task.desynchronize()

-- ============================================================================
-- 1. LISTENER - LISTENS TO RETURNING DATA AND COMPUTING IT
-- ============================================================================

SelfActor:BindToMessageParallel(
	"Set Texture Table",
	function(NewTextureBuffers: { [number]: buffer }, NewWidth: number, NewHeight: number)
		TextureBuffers = NewTextureBuffers
		TextureWidth = NewWidth
		TextureHeight = NewHeight
	end
)

SelfActor:BindToMessageParallel("Execute Rendering", function(RenderBuffer: buffer, ByteCount: number, FrameId: number)
	if DirtyMinY <= DirtyMaxY then
		BufferHelper.ClearDirtyRows(WIDTH, DirtyMinY, DirtyMaxY, TOTAL_PIXELS, PixelBuffer, ZBuffer)
		DirtyMinY = HEIGHT
		DirtyMaxY = -1
	end

	if ByteCount > 0 then
		DirtyMinY, DirtyMaxY = RenderMath.DrawTriangleBatch(
			RenderBuffer,
			ByteCount,
			TextureBuffers,
			TextureWidth,
			TextureHeight,
			WIDTH,
			HEIGHT,
			PixelBuffer,
			ZBuffer
		)
	end

	if DirtyMinY <= DirtyMaxY then
		const DirtyStartOffset = DirtyMinY * ROW_STRIDE :: number
		const DirtyByteCount = (DirtyMaxY - DirtyMinY + 1) * ROW_STRIDE :: number
		const DirtyPixelSlice = buffer.create(DirtyByteCount) :: buffer
		const DirtyZSlice = buffer.create(DirtyByteCount) :: buffer
		buffer.copy(DirtyPixelSlice, 0, PixelBuffer, DirtyStartOffset, DirtyByteCount)
		buffer.copy(DirtyZSlice, 0, ZBuffer, DirtyStartOffset, DirtyByteCount)
		ControllerActor:SendMessage("Return Render Calculations", DirtyPixelSlice, DirtyZSlice, FrameId, DirtyMinY, DirtyMaxY)
	else
		ControllerActor:SendMessage("Return Render Calculations", EmptyPayload, EmptyPayload, FrameId, DirtyMinY, DirtyMaxY)
	end
end)
