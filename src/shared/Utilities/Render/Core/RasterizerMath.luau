--!strict
--!native
--!optimize 2

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
	@param Vertex0X number -- Screen vertex 0 X.
	@param Vertex0Y number -- Screen vertex 0 Y.
	@param ScaledInverseZ0 number -- Pre-scaled 1/Z depth for vertex 0.
	@param ScaledUOverZ0 number -- Pre-scaled U/Z coordinate for vertex 0.
	@param ScaledVOverZ0 number -- Pre-scaled V/Z coordinate for vertex 0.
	@param Vertex1X number -- Screen vertex 1 X.
	@param Vertex1Y number -- Screen vertex 1 Y.
	@param ScaledInverseZ1 number -- Pre-scaled 1/Z depth for vertex 1.
	@param ScaledUOverZ1 number -- Pre-scaled U/Z coordinate for vertex 1.
	@param ScaledVOverZ1 number -- Pre-scaled V/Z coordinate for vertex 1.
	@param Vertex2X number -- Screen vertex 2 X.
	@param Vertex2Y number -- Screen vertex 2 Y.
	@param ScaledInverseZ2 number -- Pre-scaled 1/Z depth for vertex 2.
	@param ScaledUOverZ2 number -- Pre-scaled U/Z coordinate for vertex 2.
	@param ScaledVOverZ2 number -- Pre-scaled V/Z coordinate for vertex 2.
	@param PackedColor number -- Packed 32-bit RGBA shade/tint color.
	@param TextureBuffer buffer? -- Optional source RGBA texture buffer (nil renders untextured solid PackedColor).
	@param TextureWidth number -- Texture width in texels.
	@param TextureHeight number -- Texture height in texels.
	@param WIDTH number -- Target framebuffer width.
	@param HEIGHT number -- Target framebuffer height.
	@param RowStride number -- Byte stride per horizontal scanline row.
	@param PixelBuffer buffer -- Destination color pixel buffer.
	@param ZBuffer buffer -- Destination 32-bit float Z-buffer.
	@param BandStartY number? -- Optional inclusive scanline band start Y.
	@param BandEndY number? -- Optional inclusive scanline band end Y.
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

	const Edge0StepX = Vertex2Y - Vertex1Y :: number
	const Edge1StepX = Vertex0Y - Vertex2Y :: number
	const Edge2StepX = Vertex1Y - Vertex0Y :: number
	const Edge0StepY = Vertex1X - Vertex2X :: number
	const Edge1StepY = Vertex2X - Vertex0X :: number
	const Edge2StepY = Vertex0X - Vertex1X :: number
	const InverseZStepX = Edge0StepX * ScaledInverseZ0
		+ Edge1StepX * ScaledInverseZ1
		+ Edge2StepX * ScaledInverseZ2 :: number

	local EdgeWeight0 = (MinX - Vertex1X) * Edge0StepX + (MinY - Vertex1Y) * Edge0StepY :: number
	local EdgeWeight1 = (MinX - Vertex2X) * Edge1StepX + (MinY - Vertex2Y) * Edge1StepY :: number
	local EdgeWeight2 = (MinX - Vertex0X) * Edge2StepX + (MinY - Vertex0Y) * Edge2StepY :: number
	const MaxSpanOffsetX = MaxX - MinX :: number
	local RowOffset = ((MinY - EffectiveBandStartY) * WIDTH + MinX) * 4 :: number
	const ClipSpan = RasterizerMath.ClipSpanEdge

	if TextureBuffer then
		const UOverZStepX = Edge0StepX * ScaledUOverZ0 + Edge1StepX * ScaledUOverZ1 + Edge2StepX * ScaledUOverZ2 :: number
		const VOverZStepX = Edge0StepX * ScaledVOverZ0 + Edge1StepX * ScaledVOverZ1 + Edge2StepX * ScaledVOverZ2 :: number
		const TextureWidthMask = TextureWidth - 1 :: number
		const TextureHeightMask = TextureHeight - 1 :: number

		local ShadeRed = bit32.band(PackedColor, 0xFF) :: number
		local ShadeGreen = bit32.band(bit32.rshift(PackedColor, 8), 0xFF) :: number
		local ShadeBlue = bit32.band(bit32.rshift(PackedColor, 16), 0xFF) :: number
		ShadeRed = if ShadeRed > 0 then ShadeRed + 1 else 0
		ShadeGreen = if ShadeGreen > 0 then ShadeGreen + 1 else 0
		ShadeBlue = if ShadeBlue > 0 then ShadeBlue + 1 else 0
		const FullBrightTint = (ShadeRed >= 256 and ShadeGreen >= 256 and ShadeBlue >= 256) :: boolean

		for _ = MinY, MaxY do
			local SpanStartOffsetX: number, SpanEndOffsetX: number = ClipSpan(EdgeWeight0, Edge0StepX, 0, MaxSpanOffsetX)
			if SpanStartOffsetX <= SpanEndOffsetX then
				SpanStartOffsetX, SpanEndOffsetX = ClipSpan(EdgeWeight1, Edge1StepX, SpanStartOffsetX, SpanEndOffsetX)
			end
			if SpanStartOffsetX <= SpanEndOffsetX then
				SpanStartOffsetX, SpanEndOffsetX = ClipSpan(EdgeWeight2, Edge2StepX, SpanStartOffsetX, SpanEndOffsetX)
			end

			if SpanStartOffsetX <= SpanEndOffsetX then
				const RowInverseZ = EdgeWeight0 * ScaledInverseZ0 + EdgeWeight1 * ScaledInverseZ1 + EdgeWeight2 * ScaledInverseZ2 :: number
				const RowUOverZ = EdgeWeight0 * ScaledUOverZ0 + EdgeWeight1 * ScaledUOverZ1 + EdgeWeight2 * ScaledUOverZ2 :: number
				const RowVOverZ = EdgeWeight0 * ScaledVOverZ0 + EdgeWeight1 * ScaledVOverZ1 + EdgeWeight2 * ScaledVOverZ2 :: number

				local BufferOffset = RowOffset + SpanStartOffsetX * 4 :: number
				const EndOffset = RowOffset + SpanEndOffsetX * 4 :: number
				local InterpolatedInverseZ = RowInverseZ + SpanStartOffsetX * InverseZStepX :: number
				local InterpolatedUOverZ = RowUOverZ + SpanStartOffsetX * UOverZStepX :: number
				local InterpolatedVOverZ = RowVOverZ + SpanStartOffsetX * VOverZStepX :: number

				while BufferOffset <= EndOffset do
					const RemainingPixels = ((EndOffset - BufferOffset) // 4) + 1 :: number
					const ChunkPixels = if RemainingPixels > 8 then 8 else RemainingPixels :: number
					const DepthStart = 1 / InterpolatedInverseZ :: number
					local CurU = InterpolatedUOverZ * DepthStart :: number
					local CurV = InterpolatedVOverZ * DepthStart :: number
					const DepthEnd = 1 / (InterpolatedInverseZ + ChunkPixels * InverseZStepX) :: number
					const InvChunk = if ChunkPixels == 8 then 0.125 else (1 / ChunkPixels) :: number
					const StepU = ((InterpolatedUOverZ + ChunkPixels * UOverZStepX) * DepthEnd - CurU) * InvChunk :: number
					const StepV = ((InterpolatedVOverZ + ChunkPixels * VOverZStepX) * DepthEnd - CurV) * InvChunk :: number

					for _ = 1, ChunkPixels do
						if InterpolatedInverseZ > buffer.readf32(ZBuffer, BufferOffset) then
							buffer.writef32(ZBuffer, BufferOffset, InterpolatedInverseZ)
							const TexelX = math.clamp(math.floor(CurU * TextureWidth), 0, TextureWidthMask) :: number
							const TexelY = math.clamp(math.floor(CurV * TextureHeight), 0, TextureHeightMask) :: number
							const TexelColor = buffer.readu32(TextureBuffer, (TexelY * TextureWidth + TexelX) * 4) :: number

							if FullBrightTint then
								buffer.writeu32(PixelBuffer, BufferOffset, bit32.bor(TexelColor, 0xFF000000))
							else
								const OutRed = bit32.rshift(bit32.band(TexelColor, 0xFF) * ShadeRed, 8) :: number
								const OutGreen = bit32.rshift(bit32.band(bit32.rshift(TexelColor, 8), 0xFF) * ShadeGreen, 8) :: number
								const OutBlue = bit32.rshift(bit32.band(bit32.rshift(TexelColor, 16), 0xFF) * ShadeBlue, 8) :: number
								buffer.writeu32(PixelBuffer, BufferOffset, bit32.bor(OutRed, bit32.lshift(OutGreen, 8), bit32.lshift(OutBlue, 16), 0xFF000000))
							end
						end
						InterpolatedInverseZ += InverseZStepX
						CurU += StepU
						CurV += StepV
						BufferOffset += 4
					end

					InterpolatedUOverZ += ChunkPixels * UOverZStepX
					InterpolatedVOverZ += ChunkPixels * VOverZStepX
				end
			end

			EdgeWeight0 += Edge0StepY
			EdgeWeight1 += Edge1StepY
			EdgeWeight2 += Edge2StepY
			RowOffset += RowStride
		end
		return MinY, MaxY
	end

	for _ = MinY, MaxY do
		local SpanStartOffsetX: number, SpanEndOffsetX: number = ClipSpan(EdgeWeight0, Edge0StepX, 0, MaxSpanOffsetX)
		if SpanStartOffsetX <= SpanEndOffsetX then
			SpanStartOffsetX, SpanEndOffsetX = ClipSpan(EdgeWeight1, Edge1StepX, SpanStartOffsetX, SpanEndOffsetX)
		end
		if SpanStartOffsetX <= SpanEndOffsetX then
			SpanStartOffsetX, SpanEndOffsetX = ClipSpan(EdgeWeight2, Edge2StepX, SpanStartOffsetX, SpanEndOffsetX)
		end

		if SpanStartOffsetX <= SpanEndOffsetX then
			const RowInverseZ = EdgeWeight0 * ScaledInverseZ0 + EdgeWeight1 * ScaledInverseZ1 + EdgeWeight2 * ScaledInverseZ2 :: number
			local BufferOffset = RowOffset + SpanStartOffsetX * 4 :: number
			const EndOffset = RowOffset + SpanEndOffsetX * 4 :: number
			local InterpolatedInverseZ = RowInverseZ + SpanStartOffsetX * InverseZStepX :: number

			while BufferOffset <= EndOffset do
				if InterpolatedInverseZ > buffer.readf32(ZBuffer, BufferOffset) then
					buffer.writef32(ZBuffer, BufferOffset, InterpolatedInverseZ)
					buffer.writeu32(PixelBuffer, BufferOffset, PackedColor)
				end
				InterpolatedInverseZ += InverseZStepX
				BufferOffset += 4
			end
		end

		EdgeWeight0 += Edge0StepY
		EdgeWeight1 += Edge1StepY
		EdgeWeight2 += Edge2StepY
		RowOffset += RowStride
	end

	return MinY, MaxY
end

return RasterizerMath
