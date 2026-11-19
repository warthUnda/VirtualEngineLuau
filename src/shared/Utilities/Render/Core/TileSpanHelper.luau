--!strict
--!native
--!optimize 2

--[=[
	@class TileSpanHelper
	Inlined exact integer edge-clipping and scanline span filler for 32x32 untextured tiles
	with hoisted `SkipZTest` and `SkipZWrite` single-triangle fast paths.
]=]

-- Tables --
local TileSpanHelper = {}

-- Functions --
-- ============================================================================
-- 1. UNTEXTURED 32x32 TILE SCANLINE RASTERIZATION
-- ============================================================================

--[=[
	Rasterizes an untextured triangle across a single `TileW x TileH` L1 tile buffer.
]=]
function TileSpanHelper.RasterizeUntexturedTile(
	TileW: number,
	TileH: number,
	FullCover: boolean,
	SkipZTest: boolean,
	E0Start: number,
	E1Start: number,
	E2Start: number,
	E0StepX: number,
	E1StepX: number,
	E2StepX: number,
	E0StepY: number,
	E1StepY: number,
	E2StepY: number,
	SInvZ0: number,
	SInvZ1: number,
	SInvZ2: number,
	InvZStepX: number,
	PackedColor: number,
	TilePixelBuf: buffer,
	TileZBuf: buffer,
	SkipZWrite: boolean?
)
	const TileRowStride = TileW * 4 :: number
	const MaxOffsetX = TileW - 1 :: number
	local E0 = E0Start :: number
	local E1 = E1Start :: number
	local E2 = E2Start :: number
	local RowOffset = 0 :: number

	if FullCover then
		if SkipZTest and SkipZWrite then
			const LastOffset = TileH * TileRowStride - 4 :: number
			for BufferOffset = 0, LastOffset, 4 do
				buffer.writeu32(TilePixelBuf, BufferOffset, PackedColor)
			end
			return
		end

		if SkipZTest then
			for _ = 0, TileH - 1 do
				local CurZ = E0 * SInvZ0 + E1 * SInvZ1 + E2 * SInvZ2 :: number
				const EndOffset = RowOffset + MaxOffsetX * 4 :: number
				for BufferOffset = RowOffset, EndOffset, 4 do
					buffer.writef32(TileZBuf, BufferOffset, CurZ)
					buffer.writeu32(TilePixelBuf, BufferOffset, PackedColor)
					CurZ += InvZStepX
				end
				E0 += E0StepY
				E1 += E1StepY
				E2 += E2StepY
				RowOffset += TileRowStride
			end
			return
		end

		if SkipZWrite then
			for _ = 0, TileH - 1 do
				local CurZ = E0 * SInvZ0 + E1 * SInvZ1 + E2 * SInvZ2 :: number
				const EndOffset = RowOffset + MaxOffsetX * 4 :: number
				for BufferOffset = RowOffset, EndOffset, 4 do
					if CurZ > buffer.readf32(TileZBuf, BufferOffset) then
						buffer.writeu32(TilePixelBuf, BufferOffset, PackedColor)
					end
					CurZ += InvZStepX
				end
				E0 += E0StepY
				E1 += E1StepY
				E2 += E2StepY
				RowOffset += TileRowStride
			end
			return
		end

		for _ = 0, TileH - 1 do
			local CurZ = E0 * SInvZ0 + E1 * SInvZ1 + E2 * SInvZ2 :: number
			const EndOffset = RowOffset + MaxOffsetX * 4 :: number
			for BufferOffset = RowOffset, EndOffset, 4 do
				if CurZ > buffer.readf32(TileZBuf, BufferOffset) then
					buffer.writef32(TileZBuf, BufferOffset, CurZ)
					buffer.writeu32(TilePixelBuf, BufferOffset, PackedColor)
				end
				CurZ += InvZStepX
			end
			E0 += E0StepY
			E1 += E1StepY
			E2 += E2StepY
			RowOffset += TileRowStride
		end
		return
	end

	for _ = 0, TileH - 1 do
		local SpanStart = 0 :: number
		local SpanEnd = MaxOffsetX :: number

		if E0StepX > 0 then
			if E0 < 0 then
				const q = (-E0 + E0StepX - 1) // E0StepX :: number
				if q > SpanStart then SpanStart = q end
			end
		elseif E0StepX < 0 then
			if E0 < 0 then SpanStart, SpanEnd = 1, 0 else
				const q = E0 // -E0StepX :: number
				if q < SpanEnd then SpanEnd = q end
			end
		elseif E0 < 0 then SpanStart, SpanEnd = 1, 0 end

		if SpanStart <= SpanEnd then
			if E1StepX > 0 then
				if E1 < 0 then
					const q = (-E1 + E1StepX - 1) // E1StepX :: number
					if q > SpanStart then SpanStart = q end
				end
			elseif E1StepX < 0 then
				if E1 < 0 then SpanStart, SpanEnd = 1, 0 else
					const q = E1 // -E1StepX :: number
					if q < SpanEnd then SpanEnd = q end
				end
			elseif E1 < 0 then SpanStart, SpanEnd = 1, 0 end
		end

		if SpanStart <= SpanEnd then
			if E2StepX > 0 then
				if E2 < 0 then
					const q = (-E2 + E2StepX - 1) // E2StepX :: number
					if q > SpanStart then SpanStart = q end
				end
			elseif E2StepX < 0 then
				if E2 < 0 then SpanStart, SpanEnd = 1, 0 else
					const q = E2 // -E2StepX :: number
					if q < SpanEnd then SpanEnd = q end
				end
			elseif E2 < 0 then SpanStart, SpanEnd = 1, 0 end
		end

		if SpanStart <= SpanEnd then
			const StartOffset = RowOffset + SpanStart * 4 :: number
			const EndOffset = RowOffset + SpanEnd * 4 :: number
			if SkipZTest and SkipZWrite then
				for BufferOffset = StartOffset, EndOffset, 4 do
					buffer.writeu32(TilePixelBuf, BufferOffset, PackedColor)
				end
			elseif SkipZTest then
				local CurZ = (E0 * SInvZ0 + E1 * SInvZ1 + E2 * SInvZ2) + SpanStart * InvZStepX :: number
				for BufferOffset = StartOffset, EndOffset, 4 do
					buffer.writef32(TileZBuf, BufferOffset, CurZ)
					buffer.writeu32(TilePixelBuf, BufferOffset, PackedColor)
					CurZ += InvZStepX
				end
			elseif SkipZWrite then
				local CurZ = (E0 * SInvZ0 + E1 * SInvZ1 + E2 * SInvZ2) + SpanStart * InvZStepX :: number
				for BufferOffset = StartOffset, EndOffset, 4 do
					if CurZ > buffer.readf32(TileZBuf, BufferOffset) then
						buffer.writeu32(TilePixelBuf, BufferOffset, PackedColor)
					end
					CurZ += InvZStepX
				end
			else
				local CurZ = (E0 * SInvZ0 + E1 * SInvZ1 + E2 * SInvZ2) + SpanStart * InvZStepX :: number
				for BufferOffset = StartOffset, EndOffset, 4 do
					if CurZ > buffer.readf32(TileZBuf, BufferOffset) then
						buffer.writef32(TileZBuf, BufferOffset, CurZ)
						buffer.writeu32(TilePixelBuf, BufferOffset, PackedColor)
					end
					CurZ += InvZStepX
				end
			end
		end

		E0 += E0StepY
		E1 += E1StepY
		E2 += E2StepY
		RowOffset += TileRowStride
	end
end

return TileSpanHelper
