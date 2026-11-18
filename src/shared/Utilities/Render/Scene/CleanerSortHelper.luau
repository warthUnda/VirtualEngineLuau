--!strict
--!native
--!optimize 2

--[=[
	@class CleanerSortHelper
	Zero-allocation in-place sorting utilities for ordering visible render entities
	descending by world surface-area size score with deterministic ObjectId tie-breaking.
]=]

-- Configs --
const INSERTION_SORT_THRESHOLD = 20 :: number

-- Tables --
local CleanerSortHelper = {}

-- Functions --
-- ============================================================================
-- 1. ENTITY SIZE METRIC & DETERMINISTIC IN-PLACE QUICKSORT / INSERTION SORT
-- ============================================================================

--[=[
	Computes a non-negative surface-area size score for a 3D entity size tuple in SizesBuffer.
	Handles 3D volumes and zero-thickness 2D planes uniformly without collapsing to zero.
	@param SizesBuffer buffer -- Contiguous 12-byte f32 entity size buffer.
	@param ComponentOffset number -- Byte offset `(EntityId - 1) * 12` in SizesBuffer.
	@return number -- Non-negative entity size score for descending render ordering.
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
	Orders two 0-based entries in place so FirstIdx precedes SecondIdx under `(Size desc, ObjectId asc)`.
	@param SizesBuffer buffer -- Scratch f32 size score buffer.
	@param IdsBuffer buffer -- Scratch u32 ObjectId buffer.
	@param FirstIdx number -- Earlier 0-based index.
	@param SecondIdx number -- Later 0-based index.
]=]
function CleanerSortHelper.CompareAndSwap(
	SizesBuffer: buffer,
	IdsBuffer: buffer,
	FirstIdx: number,
	SecondIdx: number
)
	const FirstOffset = FirstIdx * 4 :: number
	const SecondOffset = SecondIdx * 4 :: number
	const FirstSize = buffer.readf32(SizesBuffer, FirstOffset) :: number
	const SecondSize = buffer.readf32(SizesBuffer, SecondOffset) :: number
	const FirstId = buffer.readu32(IdsBuffer, FirstOffset) :: number
	const SecondId = buffer.readu32(IdsBuffer, SecondOffset) :: number

	if FirstSize > SecondSize or (FirstSize == SecondSize and FirstId <= SecondId) then
		return
	end

	buffer.writef32(SizesBuffer, FirstOffset, SecondSize)
	buffer.writeu32(IdsBuffer, FirstOffset, SecondId)
	buffer.writef32(SizesBuffer, SecondOffset, FirstSize)
	buffer.writeu32(IdsBuffer, SecondOffset, FirstId)
end

--[=[
	Sorts a small 0-based inclusive subrange `[Low, High]` in place using insertion sort.
	@param SizesBuffer buffer -- Scratch f32 size score buffer.
	@param IdsBuffer buffer -- Scratch u32 ObjectId buffer.
	@param Low number -- Inclusive 0-based start index.
	@param High number -- Inclusive 0-based end index.
]=]
function CleanerSortHelper.InsertionSortRange(
	SizesBuffer: buffer,
	IdsBuffer: buffer,
	Low: number,
	High: number
)
	for i = Low + 1, High do
		const KeyOffset = i * 4 :: number
		const KeySize = buffer.readf32(SizesBuffer, KeyOffset) :: number
		const KeyId = buffer.readu32(IdsBuffer, KeyOffset) :: number
		local ScanIdx = i - 1 :: number

		while ScanIdx >= Low do
			const ScanOffset = ScanIdx * 4 :: number
			const ScanSize = buffer.readf32(SizesBuffer, ScanOffset) :: number
			const ScanId = buffer.readu32(IdsBuffer, ScanOffset) :: number
			if ScanSize > KeySize or (ScanSize == KeySize and ScanId <= KeyId) then
				break
			end
			buffer.writef32(SizesBuffer, ScanOffset + 4, ScanSize)
			buffer.writeu32(IdsBuffer, ScanOffset + 4, ScanId)
			ScanIdx -= 1
		end

		const InsertOffset = (ScanIdx + 1) * 4 :: number
		buffer.writef32(SizesBuffer, InsertOffset, KeySize)
		buffer.writeu32(IdsBuffer, InsertOffset, KeyId)
	end
end

--[=[
	Partitions `[Low, High]` around a median-of-three pivot under `(Size desc, ObjectId asc)`.
	@param SizesBuffer buffer -- Scratch f32 size score buffer.
	@param IdsBuffer buffer -- Scratch u32 ObjectId buffer.
	@param Low number -- Inclusive 0-based start index.
	@param High number -- Inclusive 0-based end index.
	@return (number, number) -- Next `(Left, Right)` partition cursors.
]=]
function CleanerSortHelper.PartitionRange(
	SizesBuffer: buffer,
	IdsBuffer: buffer,
	Low: number,
	High: number
): (number, number)
	const Mid = (Low + High) // 2 :: number
	CleanerSortHelper.CompareAndSwap(SizesBuffer, IdsBuffer, Low, Mid)
	CleanerSortHelper.CompareAndSwap(SizesBuffer, IdsBuffer, Low, High)
	CleanerSortHelper.CompareAndSwap(SizesBuffer, IdsBuffer, Mid, High)

	const PivotOffset = Mid * 4 :: number
	const PivotSize = buffer.readf32(SizesBuffer, PivotOffset) :: number
	const PivotId = buffer.readu32(IdsBuffer, PivotOffset) :: number

	local Left = Low :: number
	local Right = High :: number

	while Left <= Right do
		while Left <= High do
			const LeftOffset = Left * 4 :: number
			const LeftSize = buffer.readf32(SizesBuffer, LeftOffset) :: number
			const LeftId = buffer.readu32(IdsBuffer, LeftOffset) :: number
			if LeftSize < PivotSize or (LeftSize == PivotSize and LeftId >= PivotId) then
				break
			end
			Left += 1
		end

		while Right >= Low do
			const RightOffset = Right * 4 :: number
			const RightSize = buffer.readf32(SizesBuffer, RightOffset) :: number
			const RightId = buffer.readu32(IdsBuffer, RightOffset) :: number
			if RightSize > PivotSize or (RightSize == PivotSize and RightId <= PivotId) then
				break
			end
			Right -= 1
		end

		if Left <= Right then
			const LeftOffset = Left * 4 :: number
			const RightOffset = Right * 4 :: number
			const TempSize = buffer.readf32(SizesBuffer, LeftOffset) :: number
			const TempId = buffer.readu32(IdsBuffer, LeftOffset) :: number
			buffer.writef32(SizesBuffer, LeftOffset, buffer.readf32(SizesBuffer, RightOffset))
			buffer.writeu32(IdsBuffer, LeftOffset, buffer.readu32(IdsBuffer, RightOffset))
			buffer.writef32(SizesBuffer, RightOffset, TempSize)
			buffer.writeu32(IdsBuffer, RightOffset, TempId)
			Left += 1
			Right -= 1
		end
	end

	return Left, Right
end

--[=[
	Sorts `Count` entries in `SizesBuffer` and `IdsBuffer` in place from largest part to smallest
	using iterative median-of-three Quicksort with bounded stack depth and insertion-sort cutoff.
	@param SizesBuffer buffer -- Scratch f32 size score buffer (`Count * 4` active bytes).
	@param IdsBuffer buffer -- Scratch u32 ObjectId buffer (`Count * 4` active bytes).
	@param Count number -- Number of active gathered entries.
	@param StackBuffer buffer -- Pre-allocated u32 range stack (`>= 64 * 8` bytes).
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

	const MaxStackPairs = buffer.len(StackBuffer) // 8 :: number
	local Low = 0 :: number
	local High = Count - 1 :: number
	local StackTop = 0 :: number

	while true do
		if High - Low < INSERTION_SORT_THRESHOLD then
			if Low < High then
				CleanerSortHelper.InsertionSortRange(SizesBuffer, IdsBuffer, Low, High)
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

		const NextLeft: number, NextRight: number = CleanerSortHelper.PartitionRange(SizesBuffer, IdsBuffer, Low, High)
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

return CleanerSortHelper
