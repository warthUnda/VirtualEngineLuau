--!strict
--!native
--!optimize 2

--[=[
	@class RasterizerMath
	Exact scanline edge clipping and band-invariant span rasterization using inlined exact
	integer edge clipping, clean untextured numeric loops, and adaptive 16px/8px SWAR textured spans.
]=]

-- Libraries --
const TileTexturedSpanHelper = require(script.Parent:WaitForChild("TileTexturedSpanHelper"))

-- Tables --
local RasterizerMath = {}

-- Functions --
-- ============================================================================
-- 1. EXACT SCANLINE EDGE CLIPPING & BAND-INVARIANT SPAN RASTERIZATION
-- ============================================================================

--[=[
	Clips an active horizontal raster scanline span against a single linear edge function.
	@param RowEdgeWeight number -- Initial edge value at span start.
	@param EdgeStepX number -- Edge value differential per horizontal pixel step.
	@param SpanStartOffsetX number -- Current span start pixel offset.
	@param SpanEndOffsetX number -- Current span end pixel offset.
	@return (number, number) -- Clipped (SpanStartOffsetX, SpanEndOffsetX).
]=]
function RasterizerMath.ClipSpanEdge(
	RowEdgeWeight: number,
	EdgeStepX: number,
	SpanStartOffsetX: number,
	SpanEndOffsetX: number
): (number, number)
	if EdgeStepX == 0 then
		if RowEdgeWeight < 0 then
			return 1, 0
		end
		return SpanStartOffsetX, SpanEndOffsetX
	end
	if EdgeStepX > 0 then
		if RowEdgeWeight < 0 then
			return math.max(SpanStartOffsetX, (-RowEdgeWeight + EdgeStepX - 1) // EdgeStepX), SpanEndOffsetX
		end
		return SpanStartOffsetX, SpanEndOffsetX
	end
	if RowEdgeWeight < 0 then
		return 1, 0
	end
	return SpanStartOffsetX, math.min(SpanEndOffsetX, RowEdgeWeight // -EdgeStepX)
end

--[=[
	Rasterizes a 2D screen-space triangle with perspective-correct texture mapping into color and Z-depth buffers.
	@return (number, number) -- Modified scanline row range (MinY, MaxY).
]=]
function RasterizerMath.RasterizeTriangleSpan(
	Vertex0X: number,
	Vertex0Y: number,
	ScaledInverseZ0: number,
	ScaledUOverZ0: number,
	ScaledVOverZ0: number,
	Vertex1X: number,
	Vertex1Y: number,
	ScaledInverseZ1: number,
	ScaledUOverZ1: number,
	ScaledVOverZ1: number,
	Vertex2X: number,
	Vertex2Y: number,
	ScaledInverseZ2: number,
	ScaledUOverZ2: number,
	ScaledVOverZ2: number,
	PackedColor: number,
	TextureBuffer: buffer?,
	TextureWidth: number,
	TextureHeight: number,
	WIDTH: number,
	HEIGHT: number,
	RowStride: number,
	PixelBuffer: buffer,
	ZBuffer: buffer,
	BandStartY: number?,
	BandEndY: number?
): (number, number)
	const EffectiveBandStartY = BandStartY or 0 :: number
	const EffectiveBandEndY = BandEndY or (HEIGHT - 1) :: number
	const MinX = math.max(0, math.min(Vertex0X, Vertex1X, Vertex2X)) :: number
	const MaxX = math.min(WIDTH - 1, math.max(Vertex0X, Vertex1X, Vertex2X)) :: number
	const MinY = math.max(EffectiveBandStartY, math.min(Vertex0Y, Vertex1Y, Vertex2Y)) :: number
	const MaxY = math.min(EffectiveBandEndY, math.max(Vertex0Y, Vertex1Y, Vertex2Y)) :: number
	if MinX > MaxX or MinY > MaxY then
		return HEIGHT, -1
	end

	const E0StepX = Vertex2Y - Vertex1Y :: number
	const E1StepX = Vertex0Y - Vertex2Y :: number
	const E2StepX = Vertex1Y - Vertex0Y :: number
	const E0StepY = Vertex1X - Vertex2X :: number
	const E1StepY = Vertex2X - Vertex0X :: number
	const E2StepY = Vertex0X - Vertex1X :: number
	const InverseZStepX = E0StepX * ScaledInverseZ0 + E1StepX * ScaledInverseZ1 + E2StepX * ScaledInverseZ2 :: number

	local E0 = (MinX - Vertex1X) * E0StepX + (MinY - Vertex1Y) * E0StepY :: number
	local E1 = (MinX - Vertex2X) * E1StepX + (MinY - Vertex2Y) * E1StepY :: number
	local E2 = (MinX - Vertex0X) * E2StepX + (MinY - Vertex0Y) * E2StepY :: number
	const MaxSpanOffsetX = MaxX - MinX :: number
	local RowOffset = ((MinY - EffectiveBandStartY) * WIDTH + MinX) * 4 :: number

	if TextureBuffer then
		const SU0 = ScaledUOverZ0 * TextureWidth :: number
		const SV0 = ScaledVOverZ0 * TextureHeight :: number
		const SU1 = ScaledUOverZ1 * TextureWidth :: number
		const SV1 = ScaledVOverZ1 * TextureHeight :: number
		const SU2 = ScaledUOverZ2 * TextureWidth :: number
		const SV2 = ScaledVOverZ2 * TextureHeight :: number
		const UOverZStepX = E0StepX * SU0 + E1StepX * SU1 + E2StepX * SU2 :: number
		const VOverZStepX = E0StepX * SV0 + E1StepX * SV1 + E2StepX * SV2 :: number
		const TextureWidthMask = TextureWidth - 1 :: number
		const TextureHeightMask = TextureHeight - 1 :: number

		local ShadeR = bit32.band(PackedColor, 0xFF) :: number
		local ShadeG = bit32.band(bit32.rshift(PackedColor, 8), 0xFF) :: number
		local ShadeB = bit32.band(bit32.rshift(PackedColor, 16), 0xFF) :: number
		ShadeR = if ShadeR > 0 then ShadeR + 1 else 0
		ShadeG = if ShadeG > 0 then ShadeG + 1 else 0
		ShadeB = if ShadeB > 0 then ShadeB + 1 else 0
		const ShadeMode = if ShadeR >= 256 and ShadeG >= 256 and ShadeB >= 256
			then 0
			elseif ShadeR == ShadeG and ShadeG == ShadeB then 1
			else 2 :: number
		const DrawTexSpan = TileTexturedSpanHelper.DrawTexturedSpan

		for _ = MinY, MaxY do
			local SpanS = 0 :: number
			local SpanE = MaxSpanOffsetX :: number
			if E0StepX > 0 then
				if E0 < 0 then
					const q = (-E0 + E0StepX - 1) // E0StepX :: number
					if q > SpanS then SpanS = q end
				end
			elseif E0StepX < 0 then
				if E0 < 0 then SpanS, SpanE = 1, 0 else
					const q = E0 // -E0StepX :: number
					if q < SpanE then SpanE = q end
				end
			elseif E0 < 0 then SpanS, SpanE = 1, 0 end

			if SpanS <= SpanE then
				if E1StepX > 0 then
					if E1 < 0 then
						const q = (-E1 + E1StepX - 1) // E1StepX :: number
						if q > SpanS then SpanS = q end
					end
				elseif E1StepX < 0 then
					if E1 < 0 then SpanS, SpanE = 1, 0 else
						const q = E1 // -E1StepX :: number
						if q < SpanE then SpanE = q end
					end
				elseif E1 < 0 then SpanS, SpanE = 1, 0 end
			end

			if SpanS <= SpanE then
				if E2StepX > 0 then
					if E2 < 0 then
						const q = (-E2 + E2StepX - 1) // E2StepX :: number
						if q > SpanS then SpanS = q end
					end
				elseif E2StepX < 0 then
					if E2 < 0 then SpanS, SpanE = 1, 0 else
						const q = E2 // -E2StepX :: number
						if q < SpanE then SpanE = q end
					end
				elseif E2 < 0 then SpanS, SpanE = 1, 0 end
			end

			if SpanS <= SpanE then
				const RowInvZ = E0 * ScaledInverseZ0 + E1 * ScaledInverseZ1 + E2 * ScaledInverseZ2 :: number
				const RowU = E0 * SU0 + E1 * SU1 + E2 * SU2 :: number
				const RowV = E0 * SV0 + E1 * SV1 + E2 * SV2 :: number
				DrawTexSpan(
					RowOffset + SpanS * 4, RowOffset + SpanE * 4,
					RowInvZ + SpanS * InverseZStepX, RowU + SpanS * UOverZStepX, RowV + SpanS * VOverZStepX,
					InverseZStepX, UOverZStepX, VOverZStepX,
					TextureBuffer, TextureWidth, TextureWidthMask, TextureHeightMask,
					ShadeMode, ShadeR, ShadeG, ShadeB, false,
					PixelBuffer, ZBuffer
				)
			end
			E0 += E0StepY
			E1 += E1StepY
			E2 += E2StepY
			RowOffset += RowStride
		end
		return MinY, MaxY
	end

	for _ = MinY, MaxY do
		local SpanS = 0 :: number
		local SpanE = MaxSpanOffsetX :: number
		if E0StepX > 0 then
			if E0 < 0 then
				const q = (-E0 + E0StepX - 1) // E0StepX :: number
				if q > SpanS then SpanS = q end
			end
		elseif E0StepX < 0 then
			if E0 < 0 then SpanS, SpanE = 1, 0 else
				const q = E0 // -E0StepX :: number
				if q < SpanE then SpanE = q end
			end
		elseif E0 < 0 then SpanS, SpanE = 1, 0 end

		if SpanS <= SpanE then
			if E1StepX > 0 then
				if E1 < 0 then
					const q = (-E1 + E1StepX - 1) // E1StepX :: number
					if q > SpanS then SpanS = q end
				end
			elseif E1StepX < 0 then
				if E1 < 0 then SpanS, SpanE = 1, 0 else
					const q = E1 // -E1StepX :: number
					if q < SpanE then SpanE = q end
				end
			elseif E1 < 0 then SpanS, SpanE = 1, 0 end
		end

		if SpanS <= SpanE then
			if E2StepX > 0 then
				if E2 < 0 then
					const q = (-E2 + E2StepX - 1) // E2StepX :: number
					if q > SpanS then SpanS = q end
				end
			elseif E2StepX < 0 then
				if E2 < 0 then SpanS, SpanE = 1, 0 else
					const q = E2 // -E2StepX :: number
					if q < SpanE then SpanE = q end
				end
			elseif E2 < 0 then SpanS, SpanE = 1, 0 end
		end

		if SpanS <= SpanE then
			const RowInverseZ = E0 * ScaledInverseZ0 + E1 * ScaledInverseZ1 + E2 * ScaledInverseZ2 :: number
			local CurZ = RowInverseZ + SpanS * InverseZStepX :: number
			const StartOffset = RowOffset + SpanS * 4 :: number
			const EndOffset = RowOffset + SpanE * 4 :: number
			for BufferOffset = StartOffset, EndOffset, 4 do
				if CurZ > buffer.readf32(ZBuffer, BufferOffset) then
					buffer.writef32(ZBuffer, BufferOffset, CurZ)
					buffer.writeu32(PixelBuffer, BufferOffset, PackedColor)
				end
				CurZ += InverseZStepX
			end
		end

		E0 += E0StepY
		E1 += E1StepY
		E2 += E2StepY
		RowOffset += RowStride
	end

	return MinY, MaxY
end

return RasterizerMath
