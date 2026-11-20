--!strict
--!native
--!optimize 2

--[=[
	@class RenderFrameDispatchHelper
	Pass-1 chunk row-work merge, Pass-2 equal-cost band scatter dispatch, and frame completion handler.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const RenderRoot = SharedFolder:WaitForChild("Utilities"):WaitForChild("Render")
const ControllerFolder = RenderRoot:WaitForChild("Controller")
const ControllerTheoryFolder = SharedFolder:WaitForChild("Utilities"):WaitForChild("ControllerTheory")

-- Libraries --
const RenderingRep =
	require(ControllerTheoryFolder:WaitForChild("ControllerReps"):WaitForChild("RenderingRep"))
const WorkerPartitionHelper = require(ControllerFolder:WaitForChild("WorkerPartitionHelper"))
const RenderWorkerGateway = require(ControllerFolder:WaitForChild("RenderWorkerGateway"))

-- Tables --
local RenderFrameDispatchHelper = {}

-- Functions --
-- ============================================================================
-- 1. PASS-1 CHUNK MERGE -> PASS-2 TILE SCATTER & DIRECT UPLOAD COMPLETION
-- ============================================================================

--[=[
	Accumulates returned Pass-1 geometry chunks and triggers Pass-2 band partitioning + scatter once complete.
]=]
function RenderFrameDispatchHelper.HandleStageChunkReturned(
	self: any,
	ChunkIdx: number,
	FrameId: number,
	UntexTris: buffer,
	UntexBounds: buffer,
	UntexCount: number,
	TexTris: buffer,
	TexBounds: buffer,
	TexCount: number,
	ChunkRowDiff: buffer,
	StageElapsed: number
)
	if FrameId ~= self.CurrentFrame then
		return
	end
	if StageElapsed > (self.MaxStageCpuTime :: number) then
		self.MaxStageCpuTime = StageElapsed
	end

	self.ChunkUntexTris[ChunkIdx] = UntexTris
	self.ChunkUntexBounds[ChunkIdx] = UntexBounds
	self.ChunkUntexCounts[ChunkIdx] = UntexCount
	self.ChunkTexTris[ChunkIdx] = TexTris
	self.ChunkTexBounds[ChunkIdx] = TexBounds
	self.ChunkTexCounts[ChunkIdx] = TexCount
	self.LastStagedTriangleCount = (self.LastStagedTriangleCount :: number) + UntexCount + TexCount

	const MergeStart = os.clock() :: number
	const ActiveHeight = self.ActiveFrameHeight :: number
	const MasterDiff = self.RowWorkDiff :: buffer
	for RowY = 0, ActiveHeight do
		const Off = RowY * 4 :: number
		buffer.writei32(MasterDiff, Off, buffer.readi32(MasterDiff, Off) + buffer.readi32(ChunkRowDiff, Off))
	end
	self.LastGatherCpuTime = (self.LastGatherCpuTime :: number) + (os.clock() - MergeStart)

	self.StagedReceived = (self.StagedReceived :: number) + 1
	if self.StagedReceived < self.ExpectedStageChunks then
		return
	end

	const DispatchStart = os.clock() :: number
	const ActiveWidth = self.ActiveFrameWidth :: number
	const WorkerActors = self.WorkerActors :: { Actor }
	const WorkerCount = #WorkerActors :: number
	const BandStarts = self.BandStarts :: { number }
	const BandEnds = self.BandEnds :: { number }

	WorkerPartitionHelper.PartitionWorkerBands(
		MasterDiff, self.CumulativeWork, self.RowToWorker, ActiveHeight, WorkerCount, BandStarts, BandEnds, self.WorkerBandWeights
	)
	WorkerPartitionHelper.ScatterDualChunksToWorkers(
		self.ChunkUntexTris, self.ChunkUntexBounds, self.ChunkUntexCounts,
		self.ChunkTexTris, self.ChunkTexBounds, self.ChunkTexCounts,
		self.ExpectedStageChunks, self.RowToWorker, ActiveHeight, WorkerCount,
		self.WorkerUntexSlices, self.WorkerUntexBytes, self.WorkerTexSlices, self.WorkerTexBytes
	)
	RenderWorkerGateway.DispatchTileBands(
		WorkerActors,
		self.WorkerUntexSlices, self.WorkerUntexBytes,
		self.WorkerTexSlices, self.WorkerTexBytes,
		BandStarts, BandEnds, FrameId, ActiveWidth, ActiveHeight
	)
	self.LastGatherCpuTime = (self.LastGatherCpuTime :: number) + (os.clock() - DispatchStart)
end

--[=[
	Tracks returned Pass-2 pixel bands and reports total critical-path renderer CPU time on frame completion.
]=]
function RenderFrameDispatchHelper.HandleBandReturned(
	self: any,
	_FrameId: number,
	WorkerCpuTime: number,
	UploadCpuTime: number,
	BandStartY: number?,
	BandEndY: number?
)
	if WorkerCpuTime > (self.MaxWorkerCpuTime :: number) then
		self.MaxWorkerCpuTime = WorkerCpuTime
	end
	if BandStartY ~= nil then
		const Starts = self.BandStarts :: { number }
		const Ends = self.BandEnds :: { number }
		const RasterTimes = self.WorkerRasterCpuTimes :: { number }
		for w = 1, (self.ExpectedWorkers :: number) do
			if Starts[w] == BandStartY and Ends[w] == BandEndY then
				RasterTimes[w] = WorkerCpuTime
				break
			end
		end
	end
	self.UploadCpuTime = (self.UploadCpuTime :: number) + UploadCpuTime
	self.Received = (self.Received :: number) + 1
	if self.Received < self.ExpectedWorkers then
		return
	end

	WorkerPartitionHelper.UpdateAdaptiveBandWeights(
		self.WorkerBandWeights, self.WorkerRasterCpuTimes, self.ExpectedWorkers
	)

	const ActiveLabel = self.ImageLabel :: ImageLabel?
	const ActiveImageSize = self.ImageSize :: Vector2
	if ActiveLabel and ActiveLabel.ImageRectSize ~= ActiveImageSize then
		ActiveLabel.ImageRectOffset = Vector2.zero
		ActiveLabel.ImageRectSize = ActiveImageSize
	end
	const TotalRenderCpu = (self.LastGatherCpuTime :: number)
		+ (self.MaxStageCpuTime :: number)
		+ (self.MaxWorkerCpuTime :: number)
		+ (self.UploadCpuTime :: number) :: number
	self.Received = 0
	self.FrameInFlight = false
	RenderingRep.ReportFeedback(TotalRenderCpu)
end

return RenderFrameDispatchHelper
