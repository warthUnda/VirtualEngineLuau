--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const ControllerActor = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Controller") :: Actor
const SelfActor = script.Parent :: Actor

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const BufferHelper = require(ReplicatedStorage.Shared.Utilities.Render.Core.BufferHelper)
const RenderMath = require(ReplicatedStorage.Shared.Utilities.Render.Core.RenderMath)
const TextureTable = require(ReplicatedStorage.Shared.Utilities.Render.Texture.TextureTable)

-- Configs --
const WIDTH = SystemsConfigs.RenderWidth :: number
const HEIGHT = SystemsConfigs.RenderHeight :: number
const TOTAL_PIXELS = WIDTH * HEIGHT :: number
const ROW_STRIDE = WIDTH * 4 :: number
const TEXTURE_SIZE = SystemsConfigs.TextureSize :: number

-- Tables --
local BandStartY = 0 :: number
local BandEndY = HEIGHT - 1 :: number
local PrevLocalDirtyMinY = HEIGHT :: number
local PrevLocalDirtyMaxY = -1 :: number
local TextureBuffers = TextureTable.GetAllCachedBuffers() :: { [number]: buffer }
local TextureWidth = TEXTURE_SIZE :: number
local TextureHeight = TEXTURE_SIZE :: number

-- Buffers
const EmptyPayload = buffer.create(0) :: buffer
const PixelBuffer = buffer.create(TOTAL_PIXELS * 4) :: buffer
const ZBuffer = buffer.create(TOTAL_PIXELS * 4) :: buffer

BufferHelper.ClearBuffers(TOTAL_PIXELS, PixelBuffer, ZBuffer)

task.desynchronize()

-- ============================================================================
-- 1. LISTENER - LISTENS TO RETURNING DATA AND COMPUTING IT
-- ============================================================================

SelfActor:BindToMessageParallel(
	"Set Band Range",
	function(NewBandStartY: number, NewBandEndY: number)
		if PrevLocalDirtyMinY <= PrevLocalDirtyMaxY then
			BufferHelper.ClearDirtyRows(WIDTH, PrevLocalDirtyMinY, PrevLocalDirtyMaxY, TOTAL_PIXELS, PixelBuffer, ZBuffer)
			PrevLocalDirtyMinY = HEIGHT
			PrevLocalDirtyMaxY = -1
		end
		BandStartY = NewBandStartY
		BandEndY = NewBandEndY
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

SelfActor:BindToMessageParallel(
	"Execute Rendering",
	function(
		RenderBuffer: buffer,
		ByteCount: number,
		FrameId: number,
		DynamicBandStartY: number?,
		DynamicBandEndY: number?
	)
		if PrevLocalDirtyMinY <= PrevLocalDirtyMaxY then
			BufferHelper.ClearDirtyRows(WIDTH, PrevLocalDirtyMinY, PrevLocalDirtyMaxY, TOTAL_PIXELS, PixelBuffer, ZBuffer)
			PrevLocalDirtyMinY = HEIGHT
			PrevLocalDirtyMaxY = -1
		end

		if DynamicBandStartY ~= nil and DynamicBandEndY ~= nil then
			BandStartY = DynamicBandStartY
			BandEndY = DynamicBandEndY
		end

		local DirtyMinY = HEIGHT :: number
		local DirtyMaxY = -1 :: number

		if ByteCount > 0 and BandStartY <= BandEndY then
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

		if DirtyMinY <= DirtyMaxY and BandStartY <= BandEndY then
			const ClampedMinY = math.max(BandStartY, DirtyMinY) :: number
			const ClampedMaxY = math.min(BandEndY, DirtyMaxY) :: number
			PrevLocalDirtyMinY = ClampedMinY - BandStartY
			PrevLocalDirtyMaxY = ClampedMaxY - BandStartY

			const DirtyBytes = (ClampedMaxY - ClampedMinY + 1) * ROW_STRIDE :: number
			const CompactSlice = buffer.create(DirtyBytes) :: buffer
			buffer.copy(CompactSlice, 0, PixelBuffer, PrevLocalDirtyMinY * ROW_STRIDE, DirtyBytes)

			ControllerActor:SendMessage(
				"Return Render Calculations",
				CompactSlice,
				FrameId,
				BandStartY,
				BandEndY,
				ClampedMinY,
				ClampedMaxY
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
	end
)
