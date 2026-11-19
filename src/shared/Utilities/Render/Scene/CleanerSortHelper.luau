--!strict
--!native
--!optimize 2

--[=[
	@class CleanerSortHelper
	Zero-allocation in-place sorting utilities ordering visible render entities front-to-back
	ascending by `(ForwardZ - Radius, ObjectId)` for Early-Z and Tile Hi-Z rejection,
	plus surface-area metric helpers.
]=]

-- Configs --
const INSERTION_SORT_THRESHOLD = 20 :: number

-- Tables --
local CleanerSortHelper = {}

-- Functions --
-- ============================================================================
-- 1. FRONT-TO-BACK ASCENDING DEPTH SORT (EARLY-Z & TILE HI-Z ORDERING)
-- ============================================================================

--[=[
	Computes a non-negative surface-area size score for a 3D entity size tuple in SizesBuffer.
	@param SizesBuffer buffer -- Contiguous 12-byte f32 entity size buffer.
	@param ComponentOffset number -- Byte offset `(EntityId - 1) * 12` in SizesBuffer.
	@return number -- Non-negative entity size score.
]=]
function CleanerSortHelper.ComputeEntitySizeScore(SizesBuffer: buffer, ComponentOffset: number): number
	const AbsX = math.abs(buffer.readf32(SizesBuffer, ComponentOffset)) :: number
	const AbsY = math.abs(buffer.readf32(SizesBuffer, ComponentOffset + 4)) :: number
	const AbsZ = math.abs(buffer.readf32(SizesBuffer, ComponentOffset + 8)) :: number
	const HalfSurfaceArea = (AbsX * AbsY + AbsY * AbsZ + AbsZ * AbsX) :: number
	if HalfSurfaceArea ~= HalfSurfaceArea then
		return 0
	end
	if HalfSurfaceArea > 0 then
		return HalfSurfaceArea
	end
	const MaxAxis = math.max(AbsX, AbsY, AbsZ) :: number
	return if MaxAxis == MaxAxis then MaxAxis else 0
end

--[=[
	Sorts a small 0-based inclusive subrange `[Low, High]` in place ascending by `(Depth asc, ObjectId asc)`.
	@param DepthsBuffer buffer -- Scratch f32 front-depth key buffer.
	@param IdsBuffer buffer -- Scratch u32 ObjectId buffer.
	@param Low number -- Inclusive 0-based start index.
	@param High number -- Inclusive 0-based end index.
]=]
function CleanerSortHelper.InsertionSortAscending(
	DepthsBuffer: buffer,
	IdsBuffer: buffer,
	Low: number,
	High: number
)
	for i = Low + 1, High do
		const KeyOffset = i * 4 :: number
		const KeyDepth = buffer.readf32(DepthsBuffer, KeyOffset) :: number
		const KeyId = buffer.readu32(IdsBuffer, KeyOffset) :: number
		local ScanIdx = i - 1 :: number

		while ScanIdx >= Low do
			const ScanOffset = ScanIdx * 4 :: number
			const ScanDepth = buffer.readf32(DepthsBuffer, ScanOffset) :: number
			const ScanId = buffer.readu32(IdsBuffer, ScanOffset) :: number
			if ScanDepth < KeyDepth or (ScanDepth == KeyDepth and ScanId <= KeyId) then
				break
			end
			buffer.writef32(DepthsBuffer, ScanOffset + 4, ScanDepth)
			buffer.writeu32(IdsBuffer, ScanOffset + 4, ScanId)
			ScanIdx -= 1
		end

		const InsertOffset = (ScanIdx + 1) * 4 :: number
		buffer.writef32(DepthsBuffer, InsertOffset, KeyDepth)
		buffer.writeu32(IdsBuffer, InsertOffset, KeyId)
	end
end

--[=[
	Partitions `[Low, High]` around an inlined median-of-three pivot under `(Depth asc, ObjectId asc)`.
	@param DepthsBuffer buffer -- Scratch f32 front-depth key buffer.
	@param IdsBuffer buffer -- Scratch u32 ObjectId buffer.
	@param Low number -- Inclusive 0-based start index.
	@param High number -- Inclusive 0-based end index.
	@return (number, number) -- Next `(Left, Right)` partition cursors.
]=]
function CleanerSortHelper.PartitionAscending(
	DepthsBuffer: buffer,
	IdsBuffer: buffer,
	Low: number,
	High: number
): (number, number)
	const Mid = (Low + High) // 2 :: number
	const LowOff = Low * 4 :: number
	const MidOff = Mid * 4 :: number
	const HighOff = High * 4 :: number

	-- Inline median-of-three ordering for (Low, Mid, High)
	local dL = buffer.readf32(DepthsBuffer, LowOff) :: number
	local idL = buffer.readu32(IdsBuffer, LowOff) :: number
	local dM = buffer.readf32(DepthsBuffer, MidOff) :: number
	local idM = buffer.readu32(IdsBuffer, MidOff) :: number
	if dL > dM or (dL == dM and idL > idM) then
		dL, dM = dM, dL
		idL, idM = idM, idL
	end
	local dH = buffer.readf32(DepthsBuffer, HighOff) :: number
	local idH = buffer.readu32(IdsBuffer, HighOff) :: number
	if dL > dH or (dL == dH and idL > idH) then
		dL, dH = dH, dL
		idL, idH = idH, idL
	end
	if dM > dH or (dM == dH and idM > idH) then
		dM, dH = dH, dM
		idM, idH = idH, idM
	end
	buffer.writef32(DepthsBuffer, LowOff, dL)
	buffer.writeu32(IdsBuffer, LowOff, idL)
	buffer.writef32(DepthsBuffer, MidOff, dM)
	buffer.writeu32(IdsBuffer, MidOff, idM)
	buffer.writef32(DepthsBuffer, HighOff, dH)
	buffer.writeu32(IdsBuffer, HighOff, idH)

	const PivotDepth = dM :: number
	const PivotId = idM :: number
	local Left = Low :: number
	local Right = High :: number

	while Left <= Right do
		while Left <= High do
			const LeftOffset = Left * 4 :: number
			const LeftDepth = buffer.readf32(DepthsBuffer, LeftOffset) :: number
			const LeftId = buffer.readu32(IdsBuffer, LeftOffset) :: number
			if LeftDepth > PivotDepth or (LeftDepth == PivotDepth and LeftId >= PivotId) then
				break
			end
			Left += 1
		end

		while Right >= Low do
			const RightOffset = Right * 4 :: number
			const RightDepth = buffer.readf32(DepthsBuffer, RightOffset) :: number
			const RightId = buffer.readu32(IdsBuffer, RightOffset) :: number
			if RightDepth < PivotDepth or (RightDepth == PivotDepth and RightId <= PivotId) then
				break
			end
			Right -= 1
		end

		if Left <= Right then
			const LeftOffset = Left * 4 :: number
			const RightOffset = Right * 4 :: number
			const TempDepth = buffer.readf32(DepthsBuffer, LeftOffset) :: number
			const TempId = buffer.readu32(IdsBuffer, LeftOffset) :: number
			buffer.writef32(DepthsBuffer, LeftOffset, buffer.readf32(DepthsBuffer, RightOffset))
			buffer.writeu32(IdsBuffer, LeftOffset, buffer.readu32(IdsBuffer, RightOffset))
			buffer.writef32(DepthsBuffer, RightOffset, TempDepth)
			buffer.writeu32(IdsBuffer, RightOffset, TempId)
			Left += 1
			Right -= 1
		end
	end

	return Left, Right
end

--[=[
	Sorts `Count` entries in `DepthsBuffer` and `IdsBuffer` in place front-to-back (closest first)
	using iterative median-of-three Quicksort with bounded stack depth and insertion-sort cutoff.
	@param DepthsBuffer buffer -- Scratch f32 front-depth buffer (`Count * 4` active bytes).
	@param IdsBuffer buffer -- Scratch u32 ObjectId buffer (`Count * 4` active bytes).
	@param Count number -- Number of active gathered entries.
	@param StackBuffer buffer -- Pre-allocated u32 range stack (`>= 64 * 8` bytes).
]=]
function CleanerSortHelper.SortAscendingByDepth(
	DepthsBuffer: buffer,
	IdsBuffer: buffer,
	Count: number,
	StackBuffer: buffer
)
	if Count <= 1 then
		return
	end

	const InsertionSort = CleanerSortHelper.InsertionSortAscending
	const Partition = CleanerSortHelper.PartitionAscending
	const MaxStackPairs = buffer.len(StackBuffer) // 8 :: number
	local Low = 0 :: number
	local High = Count - 1 :: number
	local StackTop = 0 :: number

	while true do
		if High - Low < INSERTION_SORT_THRESHOLD then
			if Low < High then
				InsertionSort(DepthsBuffer, IdsBuffer, Low, High)
			end
			if StackTop == 0 then
				return
			end
			StackTop -= 1
			const PopOffset = StackTop * 8 :: number
			Low = buffer.readu32(StackBuffer, PopOffset)
			High = buffer.readu32(StackBuffer, PopOffset + 4)
			continue
		end

		const NextLeft: number, NextRight: number = Partition(DepthsBuffer, IdsBuffer, Low, High)
		const LeftSpan = NextRight - Low :: number
		const RightSpan = High - NextLeft :: number

		if LeftSpan > RightSpan then
			if Low < NextRight and StackTop < MaxStackPairs then
				const PushOffset = StackTop * 8 :: number
				buffer.writeu32(StackBuffer, PushOffset, Low)
				buffer.writeu32(StackBuffer, PushOffset + 4, NextRight)
				StackTop += 1
			end
			Low = NextLeft
		else
			if NextLeft < High and StackTop < MaxStackPairs then
				const PushOffset = StackTop * 8 :: number
				buffer.writeu32(StackBuffer, PushOffset, NextLeft)
				buffer.writeu32(StackBuffer, PushOffset + 4, High)
				StackTop += 1
			end
			High = NextRight
		end
	end
end

--[=[
	Legacy compatibility wrapper sorting `SizesBuffer` descending by negating keys into `SortAscendingByDepth`.
	@param SizesBuffer buffer -- Scratch f32 size score buffer.
	@param IdsBuffer buffer -- Scratch u32 ObjectId buffer.
	@param Count number -- Entry count.
	@param StackBuffer buffer -- Pre-allocated range stack.
]=]
function CleanerSortHelper.SortDescendingBySize(
	SizesBuffer: buffer,
	IdsBuffer: buffer,
	Count: number,
	StackBuffer: buffer
)
	if Count <= 1 then
		return
	end
	for i = 0, Count - 1 do
		const Off = i * 4 :: number
		buffer.writef32(SizesBuffer, Off, -buffer.readf32(SizesBuffer, Off))
	end
	CleanerSortHelper.SortAscendingByDepth(SizesBuffer, IdsBuffer, Count, StackBuffer)
	for i = 0, Count - 1 do
		const Off = i * 4 :: number
		buffer.writef32(SizesBuffer, Off, -buffer.readf32(SizesBuffer, Off))
	end
end

return CleanerSortHelper
