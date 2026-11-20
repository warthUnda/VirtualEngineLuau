--!strict
--!native
--!optimize 2

--[=[
	@class TileTexturedSpanHelper
	Perspective-correct adaptive 16px/8px textured span and 32x32 tile rasterizer with
	vertical/horizontal bounds clamping, hoisted branchless linear edge-X stepping, and linear attribute stepping.
]=]

-- Libraries --
const TileShadedTexHelper = require(script.Parent:WaitForChild("TileShadedTexHelper"))

-- Tables --
local TileTexturedSpanHelper = {}

-- Functions --
-- ============================================================================
-- 1. ADAPTIVE PERSPECTIVE-CORRECT TEXTURED SPAN & TILE RASTERIZATION
-- ============================================================================

--[=[
	Draws a single horizontal perspective-correct textured scanline span (legacy 20-arg contract).
]=]
function TileTexturedSpanHelper.DrawTexturedSpan(
	StartOffset: number,
	EndOffset: number,
	StartInvZ: number,
	StartUOverZ: number,
	StartVOverZ: number,
	InvZStepX: number,
	UOverZStepX: number,
	VOverZStepX: number,
	TexBuf: buffer,
	TexW: number,
	TexWMask: number,
	TexHMask: number,
	ShadeMode: number,
	ShadeR: number,
	ShadeG: number,
	ShadeB: number,
	SkipZTest: boolean,
	PixelBuf: buffer,
	ZBuf: buffer
)
	const RawR = if ShadeMode == 0 then 255 elseif ShadeR > 0 then ShadeR - 1 else 0 :: number
	const RawG = if ShadeMode == 0 then 255 elseif ShadeMode == 1 then RawR elseif ShadeG > 0 then ShadeG - 1 else 0 :: number
	const RawB = if ShadeMode == 0 then 255 elseif ShadeMode == 1 then RawR elseif ShadeB > 0 then ShadeB - 1 else 0 :: number
	const PackedColor = bit32.bor(RawR, bit32.lshift(RawG, 8), bit32.lshift(RawB, 16), 0xFF000000) :: number
	const TexH = TexHMask + 1 :: number
	const ShadedTex = TileShadedTexHelper.GetShadedTexture(TexBuf, PackedColor, TexW, TexH)

	TileShadedTexHelper.DrawPreShadedSpan(
		StartOffset, EndOffset,
		StartInvZ, StartUOverZ, StartVOverZ,
		InvZStepX, UOverZStepX, VOverZStepX,
		ShadedTex, TexW, TexH, TexWMask, TexHMask, SkipZTest,
		PixelBuf, ZBuf, false
	)
end

--[=[
	Rasterizes a textured triangle across a single `TileW x TileH` L1 tile buffer.
]=]
function TileTexturedSpanHelper.RasterizeTexturedTile(
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
	SU0: number,
	SV0: number,
	SU1: number,
	SV1: number,
	SU2: number,
	SV2: number,
	PackedColor: number,
	ActiveTex: buffer,
	TextureWidth: number,
	TexWMask: number,
	TexHMask: number,
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
	const UStepX = E0StepX * SU0 + E1StepX * SU1 + E2StepX * SU2 :: number
	const VStepX = E0StepX * SV0 + E1StepX * SV1 + E2StepX * SV2 :: number
	const UStepY = E0StepY * SU0 + E1StepY * SU1 + E2StepY * SU2 :: number
	const VStepY = E0StepY * SV0 + E1StepY * SV1 + E2StepY * SV2 :: number
	const ZOrigin = if InvZOrigin ~= nil then InvZOrigin else (E0Start * SInvZ0 + E1Start * SInvZ1 + E2Start * SInvZ2) :: number
	const ZStepY = if InvZStepY ~= nil then InvZStepY else (E0StepY * SInvZ0 + E1StepY * SInvZ1 + E2StepY * SInvZ2) :: number
	const UOrigin = E0Start * SU0 + E1Start * SU1 + E2Start * SU2 :: number
	const VOrigin = E0Start * SV0 + E1Start * SV1 + E2Start * SV2 :: number

	const TileRowBytes = TileW * 4 :: number
	const DxMax = TileW - 1 :: number
	const TextureHeight = TexHMask + 1 :: number
	const ShadedTex = TileShadedTexHelper.GetShadedTexture(ActiveTex, PackedColor, TextureWidth, TextureHeight)
	const DrawPreShaded = TileShadedTexHelper.DrawPreShadedSpan

	if FullCover then
		local RowInvZ, RowU, RowV = ZOrigin, UOrigin, VOrigin
		local TileRowOff = 0 :: number
		const EndDelta = DxMax * 4 :: number
		for _ = 0, TileH - 1 do
			DrawPreShaded(
				TileRowOff, TileRowOff + EndDelta,
				RowInvZ, RowU, RowV,
				InvZStepX, UStepX, VStepX,
				ShadedTex, TextureWidth, TextureHeight, TexWMask, TexHMask, SkipZTest,
				TilePixelBuf, TileZBuf, SkipZWrite
			)
			RowInvZ += ZStepY; RowU += UStepY; RowV += VStepY
			TileRowOff += TileRowBytes
		end
		return
	end

	local RowStart = if RowMinIn ~= nil then RowMinIn else 0 :: number
	local RowEnd = if RowMaxIn ~= nil then RowMaxIn else (TileH - 1) :: number
	const ColMin = if ColMinIn ~= nil then ColMinIn else 0 :: number
	const ColMax = if ColMaxIn ~= nil then ColMaxIn else DxMax :: number

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

	local TileRowOff = RowStart * TileRowBytes :: number
	local RowInvZ = ZOrigin + RowStart * ZStepY :: number
	local RowU = UOrigin + RowStart * UStepY :: number
	local RowV = VOrigin + RowStart * VStepY :: number

	for _ = RowStart, RowEnd do
		const RawS = math.ceil(if LX0 > LX1 then LX0 else LX1) :: number
		const RawE = math.floor(if RX0 < RX1 then RX0 else RX1) :: number
		const SpanS = if RawS > ColMin then RawS else ColMin :: number
		const SpanE = if RawE < ColMax then RawE else ColMax :: number
		if SpanS <= SpanE then
			DrawPreShaded(
				TileRowOff + SpanS * 4, TileRowOff + SpanE * 4,
				RowInvZ + SpanS * InvZStepX, RowU + SpanS * UStepX, RowV + SpanS * VStepX,
				InvZStepX, UStepX, VStepX,
				ShadedTex, TextureWidth, TextureHeight, TexWMask, TexHMask, SkipZTest,
				TilePixelBuf, TileZBuf, SkipZWrite
			)
		end
		LX0 += LStep0; LX1 += LStep1; RX0 += RStep0; RX1 += RStep1
		RowInvZ += ZStepY; RowU += UStepY; RowV += VStepY
		TileRowOff += TileRowBytes
	end
end

return TileTexturedSpanHelper
