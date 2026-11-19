--!strict
--!native
--!optimize 2

--[=[
	@class TileTexturedSpanHelper
	Perspective-correct adaptive 16px/8px textured span and 32x32 tile rasterizer.
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
	SkipZWrite: boolean?
)
	const UStepX = E0StepX * SU0 + E1StepX * SU1 + E2StepX * SU2 :: number
	const VStepX = E0StepX * SV0 + E1StepX * SV1 + E2StepX * SV2 :: number
	const TileRowBytes = TileW * 4 :: number
	const DxMax = TileW - 1 :: number
	const TextureHeight = TexHMask + 1 :: number
	const ShadedTex = TileShadedTexHelper.GetShadedTexture(ActiveTex, PackedColor, TextureWidth, TextureHeight)

	const DrawPreShaded = TileShadedTexHelper.DrawPreShadedSpan
	local RowE0, RowE1, RowE2 = E0Start, E1Start, E2Start
	local TileRowOff = 0 :: number

	for _ = 0, TileH - 1 do
		local SpanS = 0 :: number
		local SpanE = DxMax :: number
		if not FullCover then
			if E0StepX > 0 then
				if RowE0 < 0 then
					const q = (-RowE0 + E0StepX - 1) // E0StepX :: number
					if q > SpanS then SpanS = q end
				end
			elseif E0StepX < 0 then
				if RowE0 < 0 then SpanS, SpanE = 1, 0 else
					const q = RowE0 // -E0StepX :: number
					if q < SpanE then SpanE = q end
				end
			elseif RowE0 < 0 then SpanS, SpanE = 1, 0 end

			if SpanS <= SpanE then
				if E1StepX > 0 then
					if RowE1 < 0 then
						const q = (-RowE1 + E1StepX - 1) // E1StepX :: number
						if q > SpanS then SpanS = q end
					end
				elseif E1StepX < 0 then
					if RowE1 < 0 then SpanS, SpanE = 1, 0 else
						const q = RowE1 // -E1StepX :: number
						if q < SpanE then SpanE = q end
					end
				elseif RowE1 < 0 then SpanS, SpanE = 1, 0 end
			end

			if SpanS <= SpanE then
				if E2StepX > 0 then
					if RowE2 < 0 then
						const q = (-RowE2 + E2StepX - 1) // E2StepX :: number
						if q > SpanS then SpanS = q end
					end
				elseif E2StepX < 0 then
					if RowE2 < 0 then SpanS, SpanE = 1, 0 else
						const q = RowE2 // -E2StepX :: number
						if q < SpanE then SpanE = q end
					end
				elseif RowE2 < 0 then SpanS, SpanE = 1, 0 end
			end
		end

		if SpanS <= SpanE then
			const RowInvZ = RowE0 * SInvZ0 + RowE1 * SInvZ1 + RowE2 * SInvZ2 :: number
			const RowU = RowE0 * SU0 + RowE1 * SU1 + RowE2 * SU2 :: number
			const RowV = RowE0 * SV0 + RowE1 * SV1 + RowE2 * SV2 :: number
			DrawPreShaded(
				TileRowOff + SpanS * 4, TileRowOff + SpanE * 4,
				RowInvZ + SpanS * InvZStepX, RowU + SpanS * UStepX, RowV + SpanS * VStepX,
				InvZStepX, UStepX, VStepX,
				ShadedTex, TextureWidth, TextureHeight, TexWMask, TexHMask, SkipZTest,
				TilePixelBuf, TileZBuf, SkipZWrite
			)
		end

		RowE0 += E0StepY
		RowE1 += E1StepY
		RowE2 += E2StepY
		TileRowOff += TileRowBytes
	end
end

return TileTexturedSpanHelper
