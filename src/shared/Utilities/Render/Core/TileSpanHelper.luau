--!strict
--!native
--!optimize 2

--[=[
	@class TileSpanHelper
	Hoisted branchless linear edge-X scanline rasterizer for 32x32 untextured tiles with
	vertical/horizontal bounds clamping, linear `RowInvZ` stepping, and hoisted `SkipZTest`/`SkipZWrite` loops.
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
	SkipZWrite: boolean?,
	InvZOrigin: number?,
	InvZStepY: number?,
	RowMinIn: number?,
	RowMaxIn: number?,
	ColMinIn: number?,
	ColMaxIn: number?
)
	const TileRowStride = TileW * 4 :: number
	const MaxOffsetX = TileW - 1 :: number
	const ZOrigin = if InvZOrigin ~= nil then InvZOrigin else (E0Start * SInvZ0 + E1Start * SInvZ1 + E2Start * SInvZ2) :: number
	const ZStepY = if InvZStepY ~= nil then InvZStepY else (E0StepY * SInvZ0 + E1StepY * SInvZ1 + E2StepY * SInvZ2) :: number

	if FullCover then
		if SkipZTest and SkipZWrite then
			const TotalBytes = TileH * TileRowStride :: number
			const UnrollLimit = TotalBytes - 16 :: number
			local BufferOffset = 0 :: number
			while BufferOffset <= UnrollLimit do
				buffer.writeu32(TilePixelBuf, BufferOffset, PackedColor)
				buffer.writeu32(TilePixelBuf, BufferOffset + 4, PackedColor)
				buffer.writeu32(TilePixelBuf, BufferOffset + 8, PackedColor)
				buffer.writeu32(TilePixelBuf, BufferOffset + 12, PackedColor)
				BufferOffset += 16
			end
			while BufferOffset < TotalBytes do
				buffer.writeu32(TilePixelBuf, BufferOffset, PackedColor)
				BufferOffset += 4
			end
			return
		end

		local RowInvZ = ZOrigin :: number
		local RowOffset = 0 :: number
		if SkipZTest then
			for _ = 0, TileH - 1 do
				local CurZ = RowInvZ :: number
				const EndOffset = RowOffset + MaxOffsetX * 4 :: number
				for BufferOffset = RowOffset, EndOffset, 4 do
					buffer.writef32(TileZBuf, BufferOffset, CurZ)
					buffer.writeu32(TilePixelBuf, BufferOffset, PackedColor)
					CurZ += InvZStepX
				end
				RowInvZ += ZStepY
				RowOffset += TileRowStride
			end
			return
		end

		if SkipZWrite then
			for _ = 0, TileH - 1 do
				local CurZ = RowInvZ :: number
				const EndOffset = RowOffset + MaxOffsetX * 4 :: number
				for BufferOffset = RowOffset, EndOffset, 4 do
					if CurZ > buffer.readf32(TileZBuf, BufferOffset) then
						buffer.writeu32(TilePixelBuf, BufferOffset, PackedColor)
					end
					CurZ += InvZStepX
				end
				RowInvZ += ZStepY
				RowOffset += TileRowStride
			end
			return
		end

		for _ = 0, TileH - 1 do
			local CurZ = RowInvZ :: number
			const EndOffset = RowOffset + MaxOffsetX * 4 :: number
			for BufferOffset = RowOffset, EndOffset, 4 do
				if CurZ > buffer.readf32(TileZBuf, BufferOffset) then
					buffer.writef32(TileZBuf, BufferOffset, CurZ)
					buffer.writeu32(TilePixelBuf, BufferOffset, PackedColor)
				end
				CurZ += InvZStepX
			end
			RowInvZ += ZStepY
			RowOffset += TileRowStride
		end
		return
	end

	local RowStart = if RowMinIn ~= nil then RowMinIn else 0 :: number
	local RowEnd = if RowMaxIn ~= nil then RowMaxIn else (TileH - 1) :: number
	const ColMin = if ColMinIn ~= nil then ColMinIn else 0 :: number
	const ColMax = if ColMaxIn ~= nil then ColMaxIn else MaxOffsetX :: number

	if RowMinIn == nil then
		if E0StepX == 0 then
			const EVal = E0Start + RowStart * E0StepY :: number
			if E0StepY > 0 then
				if EVal < 0 then RowStart += (-EVal + E0StepY - 1) // E0StepY end
			elseif E0StepY < 0 then
				if EVal < 0 then return end
				const Lim = RowStart + EVal // -E0StepY :: number
				if Lim < RowEnd then RowEnd = Lim end
			elseif EVal < 0 then return end
		end
		if E1StepX == 0 then
			const EVal = E1Start + RowStart * E1StepY :: number
			if E1StepY > 0 then
				if EVal < 0 then RowStart += (-EVal + E1StepY - 1) // E1StepY end
			elseif E1StepY < 0 then
				if EVal < 0 then return end
				const Lim = RowStart + EVal // -E1StepY :: number
				if Lim < RowEnd then RowEnd = Lim end
			elseif EVal < 0 then return end
		end
		if E2StepX == 0 then
			const EVal = E2Start + RowStart * E2StepY :: number
			if E2StepY > 0 then
				if EVal < 0 then RowStart += (-EVal + E2StepY - 1) // E2StepY end
			elseif E2StepY < 0 then
				if EVal < 0 then return end
				const Lim = RowStart + EVal // -E2StepY :: number
				if Lim < RowEnd then RowEnd = Lim end
			elseif EVal < 0 then return end
		end
		if RowStart > RowEnd then
			return
		end
	end

	local LX0, LStep0, LX1, LStep1 = ColMin, 0, ColMin, 0
	local RX0, RStep0, RX1, RStep1 = ColMax, 0, ColMax, 0
	local HasL0, HasR0 = false, false

	if E0StepX > 0 then
		const Inv = 1 / E0StepX :: number
		LX0, LStep0, HasL0 = -(E0Start + RowStart * E0StepY) * Inv - 1e-9, -E0StepY * Inv, true
	elseif E0StepX < 0 then
		const Inv = 1 / E0StepX :: number
		RX0, RStep0, HasR0 = -(E0Start + RowStart * E0StepY) * Inv + 1e-9, -E0StepY * Inv, true
	end

	if E1StepX > 0 then
		const Inv = 1 / E1StepX :: number
		const XVal, XStep = -(E1Start + RowStart * E1StepY) * Inv - 1e-9, -E1StepY * Inv
		if not HasL0 then LX0, LStep0, HasL0 = XVal, XStep, true else LX1, LStep1 = XVal, XStep end
	elseif E1StepX < 0 then
		const Inv = 1 / E1StepX :: number
		const XVal, XStep = -(E1Start + RowStart * E1StepY) * Inv + 1e-9, -E1StepY * Inv
		if not HasR0 then RX0, RStep0, HasR0 = XVal, XStep, true else RX1, RStep1 = XVal, XStep end
	end

	if E2StepX > 0 then
		const Inv = 1 / E2StepX :: number
		const XVal, XStep = -(E2Start + RowStart * E2StepY) * Inv - 1e-9, -E2StepY * Inv
		if not HasL0 then LX0, LStep0 = XVal, XStep else LX1, LStep1 = XVal, XStep end
	elseif E2StepX < 0 then
		const Inv = 1 / E2StepX :: number
		const XVal, XStep = -(E2Start + RowStart * E2StepY) * Inv + 1e-9, -E2StepY * Inv
		if not HasR0 then RX0, RStep0 = XVal, XStep else RX1, RStep1 = XVal, XStep end
	end

	local RowOffset = RowStart * TileRowStride :: number
	local RowInvZ = ZOrigin + RowStart * ZStepY :: number

	if SkipZTest and SkipZWrite then
		for _ = RowStart, RowEnd do
			const RawS = math.ceil(if LX0 > LX1 then LX0 else LX1) :: number
			const RawE = math.floor(if RX0 < RX1 then RX0 else RX1) :: number
			const SpanS = if RawS > ColMin then RawS else ColMin :: number
			const SpanE = if RawE < ColMax then RawE else ColMax :: number
			if SpanS <= SpanE then
				for BufferOffset = RowOffset + SpanS * 4, RowOffset + SpanE * 4, 4 do
					buffer.writeu32(TilePixelBuf, BufferOffset, PackedColor)
				end
			end
			LX0 += LStep0; LX1 += LStep1; RX0 += RStep0; RX1 += RStep1
			RowOffset += TileRowStride
		end
		return
	end

	if SkipZTest then
		for _ = RowStart, RowEnd do
			const RawS = math.ceil(if LX0 > LX1 then LX0 else LX1) :: number
			const RawE = math.floor(if RX0 < RX1 then RX0 else RX1) :: number
			const SpanS = if RawS > ColMin then RawS else ColMin :: number
			const SpanE = if RawE < ColMax then RawE else ColMax :: number
			if SpanS <= SpanE then
				local CurZ = RowInvZ + SpanS * InvZStepX :: number
				for BufferOffset = RowOffset + SpanS * 4, RowOffset + SpanE * 4, 4 do
					buffer.writef32(TileZBuf, BufferOffset, CurZ)
					buffer.writeu32(TilePixelBuf, BufferOffset, PackedColor)
					CurZ += InvZStepX
				end
			end
			LX0 += LStep0; LX1 += LStep1; RX0 += RStep0; RX1 += RStep1
			RowInvZ += ZStepY
			RowOffset += TileRowStride
		end
		return
	end

	if SkipZWrite then
		for _ = RowStart, RowEnd do
			const RawS = math.ceil(if LX0 > LX1 then LX0 else LX1) :: number
			const RawE = math.floor(if RX0 < RX1 then RX0 else RX1) :: number
			const SpanS = if RawS > ColMin then RawS else ColMin :: number
			const SpanE = if RawE < ColMax then RawE else ColMax :: number
			if SpanS <= SpanE then
				local CurZ = RowInvZ + SpanS * InvZStepX :: number
				for BufferOffset = RowOffset + SpanS * 4, RowOffset + SpanE * 4, 4 do
					if CurZ > buffer.readf32(TileZBuf, BufferOffset) then
						buffer.writeu32(TilePixelBuf, BufferOffset, PackedColor)
					end
					CurZ += InvZStepX
				end
			end
			LX0 += LStep0; LX1 += LStep1; RX0 += RStep0; RX1 += RStep1
			RowInvZ += ZStepY
			RowOffset += TileRowStride
		end
		return
	end

	for _ = RowStart, RowEnd do
		const RawS = math.ceil(if LX0 > LX1 then LX0 else LX1) :: number
		const RawE = math.floor(if RX0 < RX1 then RX0 else RX1) :: number
		const SpanS = if RawS > ColMin then RawS else ColMin :: number
		const SpanE = if RawE < ColMax then RawE else ColMax :: number
		if SpanS <= SpanE then
			local CurZ = RowInvZ + SpanS * InvZStepX :: number
			for BufferOffset = RowOffset + SpanS * 4, RowOffset + SpanE * 4, 4 do
				if CurZ > buffer.readf32(TileZBuf, BufferOffset) then
					buffer.writef32(TileZBuf, BufferOffset, CurZ)
					buffer.writeu32(TilePixelBuf, BufferOffset, PackedColor)
				end
				CurZ += InvZStepX
			end
		end
		LX0 += LStep0; LX1 += LStep1; RX0 += RStep0; RX1 += RStep1
		RowInvZ += ZStepY
		RowOffset += TileRowStride
	end
end

return TileSpanHelper
