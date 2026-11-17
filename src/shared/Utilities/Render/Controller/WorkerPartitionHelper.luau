--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const RENDER_BUFFER_LAYOUT_SIZE = SystemsConfigs.RenderBufferLayoutSize :: number

-- Tables --
local WorkerPartitionHelper = {}

-- Functions --
-- ============================================================================
-- 1. PREFIX-SUM SCANLINE COST RECORDING, DYNAMIC BAND PARTITION & DISPATCH
-- ============================================================================

--[=[
	Records a projected triangle's estimated per-scanline rasterization cost into an i32 difference array in O(1) time.
	@param RowWorkDiff buffer -- Difference buffer of size (Height + 1) * 4 bytes.
	@param MinX number -- Clamped inclusive triangle minimum screen X.
	@param MaxX number -- Clamped inclusive triangle maximum screen X.
	@param MinY number -- Clamped inclusive triangle minimum screen Y.
	@param MaxY number -- Clamped inclusive triangle maximum screen Y.
	@param TextureId number -- TextureTable ID (0 for untextured solid fill, >0 for perspective-textured).
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

	const SpanWidth = math.max(1, MaxX - MinX + 1) :: number
	const RowCost = if TextureId > 0 then SpanWidth * 2 + 4 else SpanWidth + 4 :: number
	const StartOffset = ClampedMinY * 4 :: number
	const EndAfterOffset = (ClampedMaxY + 1) * 4 :: number

	buffer.writei32(RowWorkDiff, StartOffset, buffer.readi32(RowWorkDiff, StartOffset) + RowCost)
	buffer.writei32(RowWorkDiff, EndAfterOffset, buffer.readi32(RowWorkDiff, EndAfterOffset) - RowCost)
end

--[=[
	Integrates RowWorkDiff into CumulativeWork (zeroing RowWorkDiff for the next frame), partitions [0..Height - 1]
	into WorkerCount contiguous equal-cost scanline bands, and populates the O(1) RowToWorker lookup buffer.
	@param RowWorkDiff buffer -- Difference buffer of size (Height + 1) * 4 bytes (zeroed in-place during sweep).
	@param CumulativeWork buffer -- Scratch prefix-sum buffer of size Height * 4 bytes.
	@param RowToWorker buffer -- Output lookup buffer of size Height bytes mapping Y -> 1..WorkerCount.
	@param Height number -- Screen height in pixels.
	@param WorkerCount number -- Active parallel worker count.
	@param BandStarts { number } -- Output 1-based array of inclusive band start Y coordinates.
	@param BandEnds { number } -- Output 1-based array of inclusive band end Y coordinates.
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
	local TotalWork = 0 :: number

	for RowY = 0, Height - 1 do
		const ByteOffset = RowY * 4 :: number
		RunningRowWork += buffer.readi32(RowWorkDiff, ByteOffset)
		buffer.writei32(RowWorkDiff, ByteOffset, 0)
		if RunningRowWork > 0 then
			TotalWork += RunningRowWork
		end
		buffer.writeu32(CumulativeWork, ByteOffset, TotalWork)
	end
	buffer.writei32(RowWorkDiff, Height * 4, 0)

	if WorkerCount == 1 then
		BandStarts[1] = 0
		BandEnds[1] = Height - 1
		buffer.fill(RowToWorker, 0, 1, Height)
		return
	end

	if TotalWork <= 0 then
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
	Dispatches staged 56-byte triangle commands into each overlapping worker's command queue in exact submission order.
	@param StagedTriangles buffer -- Contiguous staged 56-byte triangle command buffer.
	@param StagedBounds buffer -- Contiguous 4-byte (u16 MinY, u16 MaxY) bounds per staged triangle.
	@param TriangleCount number -- Number of staged triangles this frame.
	@param RowToWorker buffer -- Lookup buffer mapping screen Y -> 1..WorkerCount.
	@param WorkerOffsets { number } -- Per-worker byte write offsets (mutated in-place).
	@param BufferTable { buffer } -- Per-worker destination command buffers.
	@param WorkerBufferCapacity number -- Maximum byte capacity per worker command buffer.
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
