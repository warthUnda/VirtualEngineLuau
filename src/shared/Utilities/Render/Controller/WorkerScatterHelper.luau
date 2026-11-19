--!strict
--!native
--!optimize 2

--[=[
	@class WorkerScatterHelper
	Two-pass exact-size front-to-back chunk scatter for dual untextured/textured worker streams
	with single-worker run coalescing and steady-state slice reuse.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const UNTEXTURED_STRIDE = (SystemsConfigs.UntexturedBufferLayoutSize or 32) :: number
const TEXTURED_STRIDE = (SystemsConfigs.RenderBufferLayoutSize or 64) :: number

-- Buffers
const EmptySlice = buffer.create(0) :: buffer

-- Tables --
const WriteUntexOff = table.create(16, 0) :: { number }
const WriteTexOff = table.create(16, 0) :: { number }
local WorkerScatterHelper = {}

-- Functions --
-- ============================================================================
-- 1. FRONT-TO-BACK DUAL-STREAM CHUNK SCATTER
-- ============================================================================

--[=[
	Scatters per-chunk untextured and textured staged triangles in strict chunk order (`1..ChunkCount`)
	into exact-sized per-worker slice buffers with contiguous single-worker run coalescing.
]=]
function WorkerScatterHelper.ScatterDualChunksToWorkers(
	ChunkUntexTris: { buffer },
	ChunkUntexBounds: { buffer },
	ChunkUntexCounts: { number },
	ChunkTexTris: { buffer },
	ChunkTexBounds: { buffer },
	ChunkTexCounts: { number },
	ChunkCount: number,
	RowToWorker: buffer,
	ActiveHeight: number,
	WorkerCount: number,
	OutUntexSlices: { buffer },
	OutUntexBytes: { number },
	OutTexSlices: { buffer },
	OutTexBytes: { number }
)
	const MaxRow = math.min(ActiveHeight - 1, buffer.len(RowToWorker) - 1) :: number
	for w = 1, WorkerCount do
		OutUntexBytes[w] = 0
		OutTexBytes[w] = 0
	end

	if MaxRow < 0 then
		for w = 1, WorkerCount do
			OutUntexSlices[w] = EmptySlice
			OutTexSlices[w] = EmptySlice
		end
		return
	end

	for c = 1, ChunkCount do
		const UCount = ChunkUntexCounts[c] :: number
		const UBounds = ChunkUntexBounds[c]
		for t = 0, UCount - 1 do
			const BOff = t * 4 :: number
			const FirstW = buffer.readu8(RowToWorker, math.min(buffer.readu16(UBounds, BOff), MaxRow)) :: number
			const LastW = buffer.readu8(RowToWorker, math.min(buffer.readu16(UBounds, BOff + 2), MaxRow)) :: number
			if FirstW > 0 and LastW >= FirstW then
				for w = FirstW, LastW do
					OutUntexBytes[w] += UNTEXTURED_STRIDE
				end
			end
		end

		const TCount = ChunkTexCounts[c] :: number
		const TBounds = ChunkTexBounds[c]
		for t = 0, TCount - 1 do
			const BOff = t * 4 :: number
			const FirstW = buffer.readu8(RowToWorker, math.min(buffer.readu16(TBounds, BOff), MaxRow)) :: number
			const LastW = buffer.readu8(RowToWorker, math.min(buffer.readu16(TBounds, BOff + 2), MaxRow)) :: number
			if FirstW > 0 and LastW >= FirstW then
				for w = FirstW, LastW do
					OutTexBytes[w] += TEXTURED_STRIDE
				end
			end
		end
	end

	for w = 1, WorkerCount do
		WriteUntexOff[w] = 0
		WriteTexOff[w] = 0
		const UB = OutUntexBytes[w] :: number
		const TB = OutTexBytes[w] :: number
		const PrevU = OutUntexSlices[w] :: buffer?
		const PrevT = OutTexSlices[w] :: buffer?
		OutUntexSlices[w] = if UB == 0
			then EmptySlice
			elseif PrevU ~= nil and buffer.len(PrevU) == UB then PrevU
			else buffer.create(UB)
		OutTexSlices[w] = if TB == 0
			then EmptySlice
			elseif PrevT ~= nil and buffer.len(PrevT) == TB then PrevT
			else buffer.create(TB)
	end

	for c = 1, ChunkCount do
		const UCount = ChunkUntexCounts[c] :: number
		const UTris = ChunkUntexTris[c]
		const UBounds = ChunkUntexBounds[c]
		local t = 0 :: number
		while t < UCount do
			const BOff = t * 4 :: number
			const FirstW = buffer.readu8(RowToWorker, math.min(buffer.readu16(UBounds, BOff), MaxRow)) :: number
			const LastW = buffer.readu8(RowToWorker, math.min(buffer.readu16(UBounds, BOff + 2), MaxRow)) :: number
			if FirstW > 0 and FirstW == LastW then
				local RunEnd = t + 1 :: number
				while RunEnd < UCount do
					const NextBOff = RunEnd * 4 :: number
					const NW1 = buffer.readu8(RowToWorker, math.min(buffer.readu16(UBounds, NextBOff), MaxRow)) :: number
					const NW2 = buffer.readu8(RowToWorker, math.min(buffer.readu16(UBounds, NextBOff + 2), MaxRow)) :: number
					if NW1 ~= FirstW or NW2 ~= FirstW then
						break
					end
					RunEnd += 1
				end
				const RunBytes = (RunEnd - t) * UNTEXTURED_STRIDE :: number
				const DstOff = WriteUntexOff[FirstW] :: number
				WriteUntexOff[FirstW] = DstOff + RunBytes
				buffer.copy(OutUntexSlices[FirstW], DstOff, UTris, t * UNTEXTURED_STRIDE, RunBytes)
				t = RunEnd
			else
				if FirstW > 0 and LastW > FirstW then
					const SrcOff = t * UNTEXTURED_STRIDE :: number
					for w = FirstW, LastW do
						const DstOff = WriteUntexOff[w] :: number
						WriteUntexOff[w] = DstOff + UNTEXTURED_STRIDE
						buffer.copy(OutUntexSlices[w], DstOff, UTris, SrcOff, UNTEXTURED_STRIDE)
					end
				end
				t += 1
			end
		end

		const TCount = ChunkTexCounts[c] :: number
		const TTris = ChunkTexTris[c]
		const TBounds = ChunkTexBounds[c]
		for ti = 0, TCount - 1 do
			const BOff = ti * 4 :: number
			const FirstW = buffer.readu8(RowToWorker, math.min(buffer.readu16(TBounds, BOff), MaxRow)) :: number
			const LastW = buffer.readu8(RowToWorker, math.min(buffer.readu16(TBounds, BOff + 2), MaxRow)) :: number
			if FirstW > 0 and LastW >= FirstW then
				const SrcOff = ti * TEXTURED_STRIDE :: number
				for w = FirstW, LastW do
					const DstOff = WriteTexOff[w] :: number
					WriteTexOff[w] = DstOff + TEXTURED_STRIDE
					buffer.copy(OutTexSlices[w], DstOff, TTris, SrcOff, TEXTURED_STRIDE)
				end
			end
		end
	end
end

return WorkerScatterHelper
