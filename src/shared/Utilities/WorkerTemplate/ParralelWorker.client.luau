--!native
--!optimize 2

-- Static References --
const ControllerActor =
	game:GetService("Players").LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Controller") :: Actor

const SelfActor = script.Parent :: Actor

-- Modules --
const BufferHelper = require(game.ReplicatedStorage.Shared.Utilities.BufferHelper) :: ModuleScript
const MathModule = require(game.ReplicatedStorage.Shared.Utilities.Render.RenderMath) :: ModuleScript
const RenderConfigs = require(game.StarterPlayer.StarterPlayerScripts.Client.RenderConfigs) :: ModuleScript

-- Configs
const WIDTH: number, HEIGHT: number = RenderConfigs.ReturnDimensions2D()

const TOTAL_PIXELS = WIDTH * HEIGHT :: number

local BufferLayoutSize = BufferHelper.RenderBufferLayoutSize :: number
local ReadMemoryOffset = 0 :: number

-- Buffers
const FRSBuffer = buffer.create(4) :: buffer
const PixelBuffer = buffer.create(TOTAL_PIXELS * 4) :: buffer
const ZBuffer = buffer.create(TOTAL_PIXELS * 4) :: buffer

task.desynchronize()

-- ============================================================================
-- 1. LISTENER - LISTENS TO RETURNING DATA AND COMPUTING IT
-- ============================================================================

SelfActor:BindToMessageParallel(
	"Execute Rendering",
	function(RenderBuffer: buffer, ByteCount: number, BufferSuccessRate: buffer, FrameId: number)
		BufferHelper.ClearBuffers(TOTAL_PIXELS, PixelBuffer, ZBuffer)

		local SeedBuffer = buffer.create(10000 * 4)

		ReadMemoryOffset = 0
		local SuccessOffset = 0 :: number
		local SeedOffset = 0 :: number

		for i = 1, ByteCount / BufferLayoutSize do
			const V0X = buffer.readi16(RenderBuffer, ReadMemoryOffset) :: number
			const V0Y = buffer.readi16(RenderBuffer, ReadMemoryOffset + 2) :: number
			const V0Z = buffer.readf32(RenderBuffer, ReadMemoryOffset + 4) :: number

			const V1X = buffer.readi16(RenderBuffer, ReadMemoryOffset + 8) :: number
			const V1Y = buffer.readi16(RenderBuffer, ReadMemoryOffset + 10) :: number
			const V1Z = buffer.readf32(RenderBuffer, ReadMemoryOffset + 12) :: number

			const V2X = buffer.readi16(RenderBuffer, ReadMemoryOffset + 16) :: number
			const V2Y = buffer.readi16(RenderBuffer, ReadMemoryOffset + 18) :: number
			const V2Z = buffer.readf32(RenderBuffer, ReadMemoryOffset + 20) :: number

			const R = buffer.readu16(RenderBuffer, ReadMemoryOffset + 24) :: number
			const G = buffer.readu16(RenderBuffer, ReadMemoryOffset + 26) :: number
			const B = buffer.readu16(RenderBuffer, ReadMemoryOffset + 28) :: number

			const V0Vector = Vector3.new(V0X, V0Y, V0Z) :: Vector3
			const V1Vector = Vector3.new(V1X, V1Y, V1Z) :: Vector3
			const V2Vector = Vector3.new(V2X, V2Y, V2Z) :: Vector3

			MathModule.DrawTriangle(
				V0Vector,
				V1Vector,
				V2Vector,
				R,
				G,
				B,
				WIDTH,
				HEIGHT,
				PixelBuffer,
				ZBuffer,
				FRSBuffer,
				BufferSuccessRate,
				SuccessOffset
			)

			ReadMemoryOffset += BufferLayoutSize
			SuccessOffset += 1
		end

		ControllerActor:SendMessage("Return Render Calculations", PixelBuffer, ZBuffer, FrameId)
	end
)
