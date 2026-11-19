--!strict
--!native
--!optimize 2

--[=[
	@class WorkerPartitionHelper
	Prefix-sum scanline cost recording (calibrated textured/untextured cost model), dynamic
	equal-cost band partitioning, legacy textured batch dispatch, and dual-stream scatter facade.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const WorkerScatterHelper = require(script.Parent:WaitForChild("WorkerScatterHelper"))

-- Configs --
const RENDER_BUFFER_LAYOUT_SIZE = SystemsConfigs.RenderBufferLayoutSize :: number

-- Tables --
local WorkerPartitionHelper = {
	ScatterDualChunksToWorkers = WorkerScatterHelper.ScatterDualChunksToWorkers,
}

-- Functions --
-- ============================================================================
-- 1. PREFIX-SUM SCANLINE COST RECORDING, DYNAMIC BAND PARTITION & DISPATCH
-- ============================================================================

--[=[
	Records a projected triangle's estimated per-scanline rasterization cost into an i32 difference array in O(1) time.
]=]
function WorkerPartitionHelper.RecordTriangleRowWork(
	RowWorkDiff: buffer,
	MinX: number,
	MaxX: number,
	MinY: number,
	MaxY: number,
	TextureId: number
)
	const MaxRow = (buffer.len(RowWorkDiff) // 4) - 2 :: number
	if MaxRow < 0 or MinX > MaxX then
		return
	end
	const ClampedMinY = math.max(0, MinY) :: number
	const ClampedMaxY = math.min(MaxRow, MaxY) :: number
	if ClampedMinY > ClampedMaxY then
		return
	end
	const HalfSpan = math.max(1, MaxX - MinX + 1) * 0.5 :: number
	const RowCost = if TextureId > 0 then math.floor(HalfSpan * 2 + 20) else math.floor(HalfSpan + 28) :: number
	const StartOffset = ClampedMinY * 4 :: number
	const EndAfterOffset = (ClampedMaxY + 1) * 4 :: number
	buffer.writei32(RowWorkDiff, StartOffset, buffer.readi32(RowWorkDiff, StartOffset) + RowCost)
	buffer.writei32(RowWorkDiff, EndAfterOffset, buffer.readi32(RowWorkDiff, EndAfterOffset) - RowCost)
end

--[=[
	Computes front-to-back contiguous entity chunk sizes for Pass-1 geometry staging, giving Worker 1
	a smaller slice to compensate for near/guardband polygon clipping cost on closest entities.
]=]
function WorkerPartitionHelper.ComputeStageChunkCounts(
	EntityCount: number,
	WorkerCount: number,
	OutCounts: { number }
): number
	if EntityCount <= 0 or WorkerCount <= 0 then
		return 0
	end
	if WorkerCount == 3 and EntityCount >= 9 then
		const FirstCount = math.max(1, math.floor(EntityCount * 0.17)) :: number
		const Remaining = EntityCount - FirstCount :: number
		const SecondCount = math.ceil(Remaining * 0.5) :: number
		OutCounts[1] = FirstCount
		OutCounts[2] = SecondCount
		OutCounts[3] = Remaining - SecondCount
		return 3
	end

	const BaseSize = math.ceil(EntityCount / WorkerCount) :: number
	local Dispatched = 0 :: number
	local Assigned = 0 :: number
	for w = 1, WorkerCount do
		if Assigned >= EntityCount then
			break
		end
		const Count = math.min(BaseSize, EntityCount - Assigned) :: number
		Dispatched += 1
		OutCounts[Dispatched] = Count
		Assigned += Count
	end
	return Dispatched
end

--[=[
	Integrates RowWorkDiff into CumulativeWork (zeroing RowWorkDiff for the next frame), partitions `[0..Height - 1]`
	into WorkerCount contiguous equal-cost bands, and populates the O(1) RowToWorker lookup buffer.
]=]
function WorkerPartitionHelper.PartitionWorkerBands(
	RowWorkDiff: buffer,
	CumulativeWork: buffer,
	RowToWorker: buffer,
	Height: number,
	WorkerCount: number,
	BandStarts: { number },
	BandEnds: { number }
)
	if Height <= 0 or WorkerCount <= 0 then
		return
	end

	local RunningRowWork = 0 :: number
	local TotalTriWork = 0 :: number

	for RowY = 0, Height - 1 do
		const ByteOffset = RowY * 4 :: number
		RunningRowWork += buffer.readi32(RowWorkDiff, ByteOffset)
		buffer.writei32(RowWorkDiff, ByteOffset, 0)
		const RowTriCost = if RunningRowWork > 0 then RunningRowWork else 0 :: number
		TotalTriWork += RowTriCost
		buffer.writeu32(CumulativeWork, ByteOffset, RowTriCost)
	end
	buffer.writei32(RowWorkDiff, Height * 4, 0)

	if WorkerCount == 1 then
		BandStarts[1] = 0
		BandEnds[1] = Height - 1
		buffer.fill(RowToWorker, 0, 1, Height)
		return
	end

	if TotalTriWork <= 0 then
		const UniformBandHeight = math.ceil(Height / WorkerCount) :: number
		local CurrentStart = 0 :: number
		for WorkerIdx = 1, WorkerCount do
			if CurrentStart >= Height then
				BandStarts[WorkerIdx] = Height
				BandEnds[WorkerIdx] = Height - 1
				continue
			end
			const RemainingWorkers = WorkerCount - WorkerIdx :: number
			const MaxEndRow = math.max(CurrentStart, Height - 1 - RemainingWorkers) :: number
			const EndRow = if WorkerIdx == WorkerCount
				then Height - 1
				else math.min(CurrentStart + UniformBandHeight - 1, MaxEndRow) :: number
			BandStarts[WorkerIdx] = CurrentStart
			BandEnds[WorkerIdx] = EndRow
			buffer.fill(RowToWorker, CurrentStart, WorkerIdx, EndRow - CurrentStart + 1)
			CurrentStart = EndRow + 1
		end
		return
	end

	-- Account for baseline per-row clear, slice copy, and GPU upload cost across empty sky rows
	const BaseRowCost = math.max(1, TotalTriWork // (Height * 5)) :: number
	local TotalWork = 0 :: number
	for RowY = 0, Height - 1 do
		const ByteOffset = RowY * 4 :: number
		TotalWork += buffer.readu32(CumulativeWork, ByteOffset) + BaseRowCost
		buffer.writeu32(CumulativeWork, ByteOffset, TotalWork)
	end

	local CurrentRow = 0 :: number
	for WorkerIdx = 1, WorkerCount - 1 do
		if CurrentRow >= Height then
			BandStarts[WorkerIdx] = Height
			BandEnds[WorkerIdx] = Height - 1
			continue
		end
		const RemainingWorkers = WorkerCount - WorkerIdx :: number
		const MaxEndRow = math.max(CurrentRow, Height - 1 - RemainingWorkers) :: number
		const TargetWork = (TotalWork * WorkerIdx) / WorkerCount :: number

		local SplitRow = CurrentRow :: number
		while SplitRow < MaxEndRow and buffer.readu32(CumulativeWork, SplitRow * 4) < TargetWork do
			SplitRow += 1
		end
		if SplitRow > CurrentRow then
			const PreviousCumulative = buffer.readu32(CumulativeWork, (SplitRow - 1) * 4) :: number
			const CurrentCumulative = buffer.readu32(CumulativeWork, SplitRow * 4) :: number
			if (TargetWork - PreviousCumulative) < (CurrentCumulative - TargetWork) then
				SplitRow -= 1
			end
		end

		BandStarts[WorkerIdx] = CurrentRow
		BandEnds[WorkerIdx] = SplitRow
		buffer.fill(RowToWorker, CurrentRow, WorkerIdx, SplitRow - CurrentRow + 1)
		CurrentRow = SplitRow + 1
	end

	BandStarts[WorkerCount] = CurrentRow
	BandEnds[WorkerCount] = Height - 1
	if CurrentRow <= Height - 1 then
		buffer.fill(RowToWorker, CurrentRow, WorkerCount, Height - CurrentRow)
	end
end

--[=[
	Legacy textured triangle batch dispatcher copying staged triangles into per-worker command buffers.
]=]
function WorkerPartitionHelper.DispatchStagedTriangles(
	StagedTriangles: buffer,
	StagedBounds: buffer,
	TriangleCount: number,
	RowToWorker: buffer,
	WorkerOffsets: { number },
	BufferTable: { buffer },
	WorkerBufferCapacity: number,
	ActiveHeight: number?
)
	const BufferMaxRow = buffer.len(RowToWorker) - 1 :: number
	const MaxRow = if ActiveHeight ~= nil then math.min(ActiveHeight - 1, BufferMaxRow) else BufferMaxRow :: number
	if MaxRow < 0 or TriangleCount <= 0 then
		return
	end

	for TriangleIdx = 0, TriangleCount - 1 do
		const BoundsOffset = TriangleIdx * 4 :: number
		const MinY = math.min(buffer.readu16(StagedBounds, BoundsOffset), MaxRow) :: number
		const MaxY = math.min(buffer.readu16(StagedBounds, BoundsOffset + 2), MaxRow) :: number
		const FirstWorker = buffer.readu8(RowToWorker, MinY) :: number
		const LastWorker = buffer.readu8(RowToWorker, MaxY) :: number
		if FirstWorker == 0 or LastWorker < FirstWorker then
			continue
		end

		const SourceOffset = TriangleIdx * RENDER_BUFFER_LAYOUT_SIZE :: number
		for WorkerIdx = FirstWorker, LastWorker do
			const DestOffset = WorkerOffsets[WorkerIdx] :: number
			if DestOffset + RENDER_BUFFER_LAYOUT_SIZE > WorkerBufferCapacity then
				continue
			end
			WorkerOffsets[WorkerIdx] = DestOffset + RENDER_BUFFER_LAYOUT_SIZE
			buffer.copy(BufferTable[WorkerIdx], DestOffset, StagedTriangles, SourceOffset, RENDER_BUFFER_LAYOUT_SIZE)
		end
	end
end

return WorkerPartitionHelper
