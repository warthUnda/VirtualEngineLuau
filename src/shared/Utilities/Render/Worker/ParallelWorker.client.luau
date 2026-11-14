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
const ACTOR_COUNT = SystemsConfigs.ActorCount :: number
const MAX_BAND_ROWS = math.ceil(HEIGHT / ACTOR_COUNT) :: number
const BAND_PIXELS = WIDTH * MAX_BAND_ROWS :: number
const TEXTURE_SIZE = SystemsConfigs.TextureSize :: number

local BandStartY = 0 :: number
local BandEndY = HEIGHT - 1 :: number
local DirtyMinY = HEIGHT :: number
local DirtyMaxY = -1 :: number
local TextureBuffers = TextureTable.GetAllCachedBuffers() :: { [number]: buffer }
local TextureWidth = TEXTURE_SIZE :: number
local TextureHeight = TEXTURE_SIZE :: number

-- Buffers
const EmptyPayload = buffer.create(0) :: buffer
const PixelBuffer = buffer.create(BAND_PIXELS * 4) :: buffer
const ZBuffer = buffer.create(BAND_PIXELS * 4) :: buffer

BufferHelper.ClearBuffers(BAND_PIXELS, PixelBuffer, ZBuffer)

task.desynchronize()

-- ============================================================================
-- 1. LISTENER - LISTENS TO RETURNING DATA AND COMPUTING IT
-- ============================================================================

SelfActor:BindToMessageParallel(
	"Set Band Range",
	function(NewBandStartY: number, NewBandEndY: number)
		BandStartY = NewBandStartY
		BandEndY = NewBandEndY
		DirtyMinY = HEIGHT
		DirtyMaxY = -1
		BufferHelper.ClearBuffers(BAND_PIXELS, PixelBuffer, ZBuffer)
	end
)

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
		const LocalMinY = DirtyMinY - BandStartY :: number
		const LocalMaxY = DirtyMaxY - BandStartY :: number
		BufferHelper.ClearDirtyRows(WIDTH, LocalMinY, LocalMaxY, BAND_PIXELS, PixelBuffer, ZBuffer)
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
			ZBuffer,
			BandStartY,
			BandEndY
		)
	end

	if DirtyMinY <= DirtyMaxY then
		ControllerActor:SendMessage(
			"Return Render Calculations",
			PixelBuffer,
			FrameId,
			BandStartY,
			BandEndY,
			DirtyMinY,
			DirtyMaxY
		)
	else
		ControllerActor:SendMessage(
			"Return Render Calculations",
			EmptyPayload,
			FrameId,
			BandStartY,
			BandEndY,
			DirtyMinY,
			DirtyMaxY
		)
	end
end)
