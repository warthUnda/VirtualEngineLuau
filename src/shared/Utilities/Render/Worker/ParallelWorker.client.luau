--!strict
--!native
--!optimize 2

--[=[
	@class ParallelWorker
	Isolated Actor VM worker executing Pass-1 entity geometry staging and Pass-2 32x32 tile
	rasterization with steady-state output buffer reuse.
]=]

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const ControllerActor = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Controller") :: Actor
const SelfActor = script.Parent :: Actor
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const RenderRoot = SharedFolder:WaitForChild("Utilities"):WaitForChild("Render")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const VerticeFile = require(RenderRoot:WaitForChild("Core"):WaitForChild("VerticeFile"))
const TileRasterizerMath = require(RenderRoot:WaitForChild("Core"):WaitForChild("TileRasterizerMath"))
const RenderEntityStageHelper = require(RenderRoot:WaitForChild("Controller"):WaitForChild("RenderEntityStageHelper"))
const TextureTable = require(RenderRoot:WaitForChild("Texture"):WaitForChild("TextureTable"))

-- Configs --
const MAX_WIDTH = SystemsConfigs.RenderWidth :: number
const MAX_HEIGHT = SystemsConfigs.RenderHeight :: number
const TEXTURE_SIZE = SystemsConfigs.TextureSize :: number
const UNTEXTURED_STRIDE = SystemsConfigs.UntexturedBufferLayoutSize :: number
const TEXTURED_STRIDE = SystemsConfigs.RenderBufferLayoutSize :: number
const WORKER_BUFFER_MULTIPLIER = SystemsConfigs.WorkerBufferMultiplier :: number
const MAX_STAGED_TRIS = math.max(1024, (MAX_WIDTH * MAX_HEIGHT * WORKER_BUFFER_MULTIPLIER) // TEXTURED_STRIDE) :: number

-- Variables --
local TextureWidth = TEXTURE_SIZE :: number
local TextureHeight = TEXTURE_SIZE :: number
local CachedDiffBytes = 0 :: number
local CachedBandBytes = 0 :: number

-- Buffers
const EmptyPayload = buffer.create(0) :: buffer
local CachedDiffOut = EmptyPayload :: buffer
local CachedBandSlice = EmptyPayload :: buffer
const ScreenVertices = buffer.create(VerticeFile.MaxShapeVertices * 12) :: buffer
const ProjectedVertices = buffer.create(12 * 24) :: buffer
const ClipBufferA = buffer.create(12 * 24) :: buffer
const ClipBufferB = buffer.create(12 * 24) :: buffer
const StageUntexTris = buffer.create(MAX_STAGED_TRIS * UNTEXTURED_STRIDE) :: buffer
const StageUntexBounds = buffer.create(MAX_STAGED_TRIS * 4) :: buffer
const StageTexTris = buffer.create(MAX_STAGED_TRIS * TEXTURED_STRIDE) :: buffer
const StageTexBounds = buffer.create(MAX_STAGED_TRIS * 4) :: buffer
const StageRowWorkDiff = buffer.create((MAX_HEIGHT + 1) * 4) :: buffer

-- Tables --
local TextureBuffers = TextureTable.GetAllCachedBuffers() :: { [number]: buffer }

-- Functions --
task.desynchronize()

-- ============================================================================
-- 1. PARALLEL GEOMETRY STAGING & 2D TILE BAND RASTERIZATION HANDLERS
-- ============================================================================

SelfActor:BindToMessageParallel(
	"Set Texture Table",
	function(NewTextureBuffers: { [number]: buffer }, NewWidth: number, NewHeight: number)
		TextureBuffers = NewTextureBuffers
		TextureWidth = NewWidth
		TextureHeight = NewHeight
	end
)

SelfActor:BindToMessageParallel(
	"Stage Entities",
	function(
		ChunkIdx: number,
		PosSlice: buffer,
		SizeSlice: buffer,
		DirSlice: buffer,
		VisSlice: buffer,
		PropSlice: buffer,
		ChunkEntityCount: number,
		CamPosVec: vector,
		CamRightVec: vector,
		CamUpVec: vector,
		CamLookVec: vector,
		FocalLength: number,
		GuardBandX: number,
		GuardBandY: number,
		PlaneLeft: vector,
		PlaneRight: vector,
		PlaneBottom: vector,
		PlaneTop: vector,
		ActiveWidth: number,
		ActiveHeight: number,
		FrameId: number
	)
		const StageStart = os.clock() :: number
		const DiffBytes = (ActiveHeight + 1) * 4 :: number
		buffer.fill(StageRowWorkDiff, 0, 0, DiffBytes)

		const UntexCount: number, TexCount: number = RenderEntityStageHelper.StageEntitySlice(
			ChunkEntityCount,
			PosSlice, SizeSlice, DirSlice, VisSlice, PropSlice,
			ScreenVertices, ProjectedVertices, ClipBufferA, ClipBufferB,
			StageUntexTris, StageUntexBounds, MAX_STAGED_TRIS,
			StageTexTris, StageTexBounds, MAX_STAGED_TRIS,
			StageRowWorkDiff,
			CamPosVec, CamRightVec, CamUpVec, CamLookVec,
			FocalLength, GuardBandX, GuardBandY, ActiveWidth, ActiveHeight,
			PlaneLeft, PlaneRight, PlaneBottom, PlaneTop
		)

		local UntexTrisOut = EmptyPayload :: buffer
		local UntexBoundsOut = EmptyPayload :: buffer
		if UntexCount > 0 then
			const UBytes = UntexCount * UNTEXTURED_STRIDE :: number
			const UBBytes = UntexCount * 4 :: number
			UntexTrisOut = buffer.create(UBytes)
			UntexBoundsOut = buffer.create(UBBytes)
			buffer.copy(UntexTrisOut, 0, StageUntexTris, 0, UBytes)
			buffer.copy(UntexBoundsOut, 0, StageUntexBounds, 0, UBBytes)
		end

		local TexTrisOut = EmptyPayload :: buffer
		local TexBoundsOut = EmptyPayload :: buffer
		if TexCount > 0 then
			const TBytes = TexCount * TEXTURED_STRIDE :: number
			const TBBytes = TexCount * 4 :: number
			TexTrisOut = buffer.create(TBytes)
			TexBoundsOut = buffer.create(TBBytes)
			buffer.copy(TexTrisOut, 0, StageTexTris, 0, TBytes)
			buffer.copy(TexBoundsOut, 0, StageTexBounds, 0, TBBytes)
		end

		if DiffBytes ~= CachedDiffBytes then
			CachedDiffOut = buffer.create(DiffBytes)
			CachedDiffBytes = DiffBytes
		end
		const DiffOut = CachedDiffOut
		buffer.copy(DiffOut, 0, StageRowWorkDiff, 0, DiffBytes)
		const StageElapsed = (os.clock() - StageStart) :: number

		ControllerActor:SendMessage(
			"Return Staged Geometry",
			ChunkIdx,
			FrameId,
			UntexTrisOut,
			UntexBoundsOut,
			UntexCount,
			TexTrisOut,
			TexBoundsOut,
			TexCount,
			DiffOut,
			StageElapsed
		)
	end
)

SelfActor:BindToMessageParallel(
	"Execute Rendering",
	function(
		UntexBuf: buffer,
		UntexBytes: number,
		TexBuf: buffer,
		TexBytes: number,
		FrameId: number,
		BandStartY: number,
		BandEndY: number,
		DynamicWidth: number,
		DynamicHeight: number
	)
		const WorkerStart = os.clock() :: number
		const ActiveWidth = math.clamp(DynamicWidth, 1, MAX_WIDTH) :: number
		const ActiveHeight = math.clamp(DynamicHeight, 1, MAX_HEIGHT) :: number

		if BandStartY > BandEndY then
			ControllerActor:SendMessage(
				"Return Render Calculations",
				EmptyPayload,
				FrameId,
				BandStartY,
				BandEndY,
				ActiveWidth,
				os.clock() - WorkerStart
			)
			return
		end

		const BandHeight = BandEndY - BandStartY + 1 :: number
		const BandBytes = BandHeight * ActiveWidth * 4 :: number
		if BandBytes ~= CachedBandBytes then
			CachedBandSlice = buffer.create(BandBytes)
			CachedBandBytes = BandBytes
		end
		const BandPixelSlice = CachedBandSlice

		TileRasterizerMath.RasterizeBandDual(
			UntexBuf, UntexBytes,
			TexBuf, TexBytes,
			TextureBuffers, TextureWidth, TextureHeight,
			ActiveWidth, ActiveHeight,
			BandPixelSlice, BandStartY, BandEndY
		)

		ControllerActor:SendMessage(
			"Return Render Calculations",
			BandPixelSlice,
			FrameId,
			BandStartY,
			BandEndY,
			ActiveWidth,
			os.clock() - WorkerStart
		)
	end
)
