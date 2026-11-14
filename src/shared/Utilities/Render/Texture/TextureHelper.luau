--!strict
--!native
--!optimize 2

-- Services --
const AssetService = game:GetService("AssetService")
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Modules --
const RenderConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Configs"):WaitForChild("RenderConfig"))

-- Configs --
const TEXTURE_SIZE = RenderConfig.TextureSize :: number

local TextureHelper = {}

-- ============================================================================
-- 1. PROCEDURAL TEXTURES & 64x64 URL DECODING
-- ============================================================================

--[=[
	Packs RGBA channels (0-255) into a little-endian 32-bit unsigned integer.
	@param RedChannel number -- Red channel (0-255).
	@param GreenChannel number -- Green channel (0-255).
	@param BlueChannel number -- Blue channel (0-255).
	@param AlphaChannel number -- Alpha channel (0-255).
	@return number -- Packed 32-bit RGBA pixel value.
]=]
local function PackRGBA(RedChannel: number, GreenChannel: number, BlueChannel: number, AlphaChannel: number): number
	return bit32.bor(
		RedChannel,
		bit32.lshift(GreenChannel, 8),
		bit32.lshift(BlueChannel, 16),
		bit32.lshift(AlphaChannel, 24)
	)
end

--[=[
	Generates a seamlessly tileable power-of-two procedural wood plank texture with grain rings, seams, and bevels.
	@param TargetSize number -- Width and height of the square texture in texels.
	@return buffer -- RGBA pixel buffer of size TargetSize * TargetSize * 4.
]=]
function TextureHelper.CreateProceduralWoodTexture(TargetSize: number): buffer
	const PixelBuffer = buffer.create(TargetSize * TargetSize * 4) :: buffer
	const InvSize = 1 / TargetSize :: number
	const TwoPi = math.pi * 2 :: number
	const PlankHeight = math.max(8, TargetSize // 4) :: number

	for TexelY = 0, TargetSize - 1 do
		const NormV = (TexelY + 0.5) * InvSize :: number
		const AngleV = NormV * TwoPi :: number
		const CosV = math.cos(AngleV) :: number
		const SinV = math.sin(AngleV) :: number
		const PlankIndex = TexelY // PlankHeight :: number
		const PlankLocalY = TexelY % PlankHeight :: number
		const IsHorizontalSeam = (PlankLocalY == 0) :: boolean
		const RowOffset = TexelY * TargetSize * 4 :: number

		for TexelX = 0, TargetSize - 1 do
			const NormU = (TexelX + 0.5) * InvSize :: number
			const AngleU = NormU * TwoPi :: number
			const CosU = math.cos(AngleU) :: number
			const SinU = math.sin(AngleU) :: number

			-- Offset vertical plank seams per row for staggered wood planks
			const SeamX = (TexelX + PlankIndex * (TargetSize // 2)) % TargetSize :: number
			const IsVerticalSeam = (SeamX == 0) :: boolean

			-- Elongated horizontal wood grain noise
			const GrainWarp = math.noise(CosU * 1.1 + PlankIndex * 2.3, SinU * 1.1, CosV * 4.2 + SinV * 4.2) :: number
			const RingPattern = math.sin((NormV * 14 + GrainWarp * 2.4 + PlankIndex * 0.7) * math.pi) :: number
			const FineFiber = math.noise(CosU * 3.5, SinU * 3.5, NormV * 24 + PlankIndex * 5.1) :: number
			const PlankTintOffset = ((PlankIndex % 3) - 1) * 10 :: number

			local ShadeFactor = 0.5 + 0.32 * RingPattern + 0.18 * FineFiber :: number
			ShadeFactor = math.clamp(ShadeFactor, 0.12, 1.0)

			local Red = math.clamp(math.floor(110 + ShadeFactor * 92 + PlankTintOffset), 40, 220) :: number
			local Green = math.clamp(math.floor(66 + ShadeFactor * 64 + PlankTintOffset * 0.7), 24, 155) :: number
			local Blue = math.clamp(math.floor(32 + ShadeFactor * 36 + PlankTintOffset * 0.4), 12, 90) :: number

			if IsHorizontalSeam or IsVerticalSeam then
				Red = math.floor(Red * 0.42)
				Green = math.floor(Green * 0.42)
				Blue = math.floor(Blue * 0.42)
			elseif PlankLocalY == 1 or SeamX == 1 then
				Red = math.min(240, Red + 18)
				Green = math.min(185, Green + 14)
				Blue = math.min(115, Blue + 10)
			end

			buffer.writeu32(PixelBuffer, RowOffset + TexelX * 4, PackRGBA(Red, Green, Blue, 255))
		end
	end

	return PixelBuffer
end

--[=[
	Generates a high-contrast power-of-two procedural Roblox stud and checker grid template texture.
	@param TargetSize number -- Width and height of the square texture in texels.
	@return buffer -- RGBA pixel buffer of size TargetSize * TargetSize * 4.
]=]
function TextureHelper.CreateProceduralStudTexture(TargetSize: number): buffer
	const PixelBuffer = buffer.create(TargetSize * TargetSize * 4) :: buffer
	const CellSize = math.max(4, TargetSize // 2) :: number
	const HalfCell = CellSize * 0.5 :: number
	const BorderThickness = math.max(1, TargetSize // 24) :: number
	const StudOuterRadius = CellSize * 0.34 :: number
	const StudInnerRadius = CellSize * 0.22 :: number
	const StudCenterRadius = CellSize * 0.09 :: number

	for TexelY = 0, TargetSize - 1 do
		const QuadrantY = TexelY // CellSize :: number
		const CellY = TexelY % CellSize :: number
		const OffsetY = (CellY + 0.5) - HalfCell :: number
		const RowOffset = TexelY * TargetSize * 4 :: number

		for TexelX = 0, TargetSize - 1 do
			const QuadrantX = TexelX // CellSize :: number
			const CellX = TexelX % CellSize :: number
			const OffsetX = (CellX + 0.5) - HalfCell :: number
			const DistanceFromCenter = math.sqrt(OffsetX * OffsetX + OffsetY * OffsetY) :: number

			const IsLightTile = ((QuadrantX + QuadrantY) % 2 == 0) :: boolean
			local Shade = if IsLightTile then 236 else 160 :: number

			if
				CellX < BorderThickness
				or CellY < BorderThickness
				or CellX >= CellSize - BorderThickness
				or CellY >= CellSize - BorderThickness
			then
				Shade = 68
			elseif DistanceFromCenter <= StudCenterRadius then
				Shade = 95
			elseif DistanceFromCenter <= StudInnerRadius then
				Shade = if IsLightTile then 205 else 225
			elseif DistanceFromCenter <= StudOuterRadius then
				if OffsetX + OffsetY < 0 then
					Shade = 250
				else
					Shade = 60
				end
			end

			buffer.writeu32(
				PixelBuffer,
				RowOffset + TexelX * 4,
				PackRGBA(math.max(0, Shade - 8), Shade, math.min(255, Shade + 10), 255)
			)
		end
	end

	return PixelBuffer
end

--[=[
	Resamples a source RGBA pixel buffer to a square TargetSize x TargetSize buffer using nearest-neighbor sampling.
	@param SourceBuffer buffer -- Source RGBA pixel buffer.
	@param SourceWidth number -- Source image width in pixels.
	@param SourceHeight number -- Source image height in pixels.
	@param TargetSize number -- Target square texture size in texels.
	@return buffer -- Resampled RGBA pixel buffer.
]=]
function TextureHelper.ResampleTextureBuffer(
	SourceBuffer: buffer,
	SourceWidth: number,
	SourceHeight: number,
	TargetSize: number
): buffer
	if SourceWidth == TargetSize and SourceHeight == TargetSize then
		return SourceBuffer
	end

	const DestBuffer = buffer.create(TargetSize * TargetSize * 4) :: buffer
	const ScaleX = SourceWidth / TargetSize :: number
	const ScaleY = SourceHeight / TargetSize :: number

	for DestY = 0, TargetSize - 1 do
		const SourceY = math.min(SourceHeight - 1, math.floor(DestY * ScaleY)) :: number
		const SourceRowOffset = SourceY * SourceWidth * 4 :: number
		const DestRowOffset = DestY * TargetSize * 4 :: number

		for DestX = 0, TargetSize - 1 do
			const SourceX = math.min(SourceWidth - 1, math.floor(DestX * ScaleX)) :: number
			const Texel = buffer.readu32(SourceBuffer, SourceRowOffset + SourceX * 4) :: number
			buffer.writeu32(DestBuffer, DestRowOffset + DestX * 4, Texel)
		end
	end

	return DestBuffer
end

--[=[
	Decodes a raw Roblox texture URL into a TargetSize x TargetSize RGBA buffer using EditableImage, falling back to FallbackBuffer on empty URI or load failure.
	@param RawUrl string -- Raw Roblox texture URL (e.g. "rbxassetid://..." or "rbxasset://...").
	@param FallbackBuffer buffer? -- Optional precomputed fallback buffer if decoding fails or URL is empty.
	@param TargetSize number? -- Optional square target size in texels (defaults to RenderConfig.TextureSize).
	@return (buffer, boolean) -- Decoded (or fallback) 64x64 RGBA buffer, and true if decoded from the URL.
]=]
function TextureHelper.DecodeUrlToBuffer(
	RawUrl: string,
	FallbackBuffer: buffer?,
	TargetSize: number?
): (buffer, boolean)
	const ResolvedSize = TargetSize or TEXTURE_SIZE :: number
	if RawUrl ~= "" then
		const Success: boolean, LoadedResult: any = pcall(function()
			return AssetService:CreateEditableImageAsync(Content.fromUri(RawUrl))
		end)

		if Success and LoadedResult then
			const EditableImage = LoadedResult :: EditableImage
			const ImageSize = EditableImage.Size :: Vector2
			const RawPixels = EditableImage:ReadPixelsBuffer(Vector2.zero, ImageSize) :: buffer
			EditableImage:Destroy()

			const Resampled = TextureHelper.ResampleTextureBuffer(RawPixels, ImageSize.X, ImageSize.Y, ResolvedSize)
			return Resampled, true
		end
	end

	if FallbackBuffer then
		return FallbackBuffer, false
	end

	return TextureHelper.CreateProceduralStudTexture(ResolvedSize), false
end

return TextureHelper
