--!strict
--!native
--!optimize 2

-- Services --
const AssetService = game:GetService("AssetService")
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const TEXTURE_SIZE = SystemsConfigs.TextureSize :: number
const DEFAULT_TEXTURE_URI = SystemsConfigs.DefaultTextureUri :: string

-- Tables --
-- Predefined seamless blood splatter & clot centers: { CenterU, CenterV, Radius, Intensity }
const SPLATTER_DROPS = {
	{ 0.18, 0.22, 0.19, 1.0 },
	{ 0.65, 0.16, 0.15, 0.9 },
	{ 0.42, 0.54, 0.24, 1.0 },
	{ 0.82, 0.68, 0.18, 0.95 },
	{ 0.24, 0.78, 0.16, 0.85 },
	{ 0.55, 0.88, 0.14, 0.9 },
	{ 0.10, 0.50, 0.13, 0.8 },
	{ 0.88, 0.35, 0.15, 0.9 },
} :: { { number } }

-- Buffers
local CachedDefaultTexture: buffer? = nil

local TextureHelper = {}

-- ============================================================================
-- 1. PROCEDURAL BLOOD TEXTURE & ROBLOX ASSET TEXTURE LOADING
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
	Generates a high-contrast, seamlessly tileable power-of-two procedural blood texture with splatters, clots, drips, and wet highlights.
	@param TargetSize number -- Width and height of the square texture in texels.
	@return buffer -- RGBA pixel buffer of size TargetSize * TargetSize * 4.
]=]
function TextureHelper.CreateProceduralTemplateTexture(TargetSize: number): buffer
	const PixelBuffer = buffer.create(TargetSize * TargetSize * 4) :: buffer
	const InvSize = 1 / TargetSize :: number
	const TwoPi = math.pi * 2 :: number

	for TexelY = 0, TargetSize - 1 do
		const NormV = (TexelY + 0.5) * InvSize :: number
		const AngleV = NormV * TwoPi :: number
		const CosV = math.cos(AngleV) :: number
		const SinV = math.sin(AngleV) :: number
		const RowOffset = TexelY * TargetSize * 4 :: number

		for TexelX = 0, TargetSize - 1 do
			const NormU = (TexelX + 0.5) * InvSize :: number
			const AngleU = NormU * TwoPi :: number
			const CosU = math.cos(AngleU) :: number
			const SinU = math.sin(AngleU) :: number

			-- Seamless toroidal Perlin noise across multiple octaves
			const CoarseNoise = math.noise(CosU * 1.4 + SinV * 0.7, SinU * 1.4 + CosV * 0.7, 3.1) :: number
			const MediumNoise = math.noise(CosU * 3.2 - SinV * 1.9, SinU * 3.2 + CosV * 1.9, 7.4) :: number
			const FineNoise = math.noise(CosU * 6.5 + CosV * 4.1, SinU * 6.5 - SinV * 4.1, 13.7) :: number

			-- Vertical blood drip streaks (high frequency in U, stretched in V)
			const DripWave = math.noise(CosU * 5.5, SinU * 5.5, CosV * 1.1 + 19.3) :: number
			const DripStreak = math.clamp((DripWave + 0.15) * 1.6, 0, 1) :: number

			-- Accumulate organic splatter blobs and dark coagulated clot centers
			local SplatterMask = 0 :: number
			local ClotMask = 0 :: number
			local WetHighlight = 0 :: number

			for DropIdx = 1, #SPLATTER_DROPS do
				const Drop = SPLATTER_DROPS[DropIdx]
				local DeltaU = (NormU - Drop[1] + 0.5) % 1 - 0.5 :: number
				local DeltaV = (NormV - Drop[2] + 0.5) % 1 - 0.5 :: number

				-- Stretch slightly downward for gravity drip look
				if DeltaV > 0 then
					DeltaV *= 0.72
				else
					DeltaV *= 1.15
				end

				const Dist = math.sqrt(DeltaU * DeltaU + DeltaV * DeltaV) :: number
				const JaggedRadius = Drop[3] * (1 + MediumNoise * 0.38 + FineNoise * 0.18) :: number

				if Dist < JaggedRadius then
					const DropFactor = (1 - Dist / JaggedRadius) * Drop[4] :: number
					if DropFactor > SplatterMask then
						SplatterMask = DropFactor
					end

					-- Thick dark coagulated core inside the splatter
					if Dist < JaggedRadius * 0.42 then
						const CoreFactor = 1 - (Dist / (JaggedRadius * 0.42)) :: number
						if CoreFactor > ClotMask then
							ClotMask = CoreFactor
						end
					end

					-- Wet specular glint near the upper-left rim of fresh drops
					if DeltaU < 0 and DeltaV < 0 and Dist > JaggedRadius * 0.48 and Dist < JaggedRadius * 0.72 then
						WetHighlight = 1
					end
				end
			end

			-- Combine base flesh/dried blood with bright arterial splatters and dark clots
			const OrganicVariation = CoarseNoise * 0.5 + MediumNoise * 0.35 + FineNoise * 0.15 :: number

			-- Base dark dried blood background
			local Red = math.clamp(math.floor(95 + OrganicVariation * 55 + DripStreak * 45), 35, 165) :: number
			local Green = math.clamp(math.floor(4 + OrganicVariation * 6), 0, 16) :: number
			local Blue = math.clamp(math.floor(6 + OrganicVariation * 8), 0, 20) :: number

			-- Vivid crimson arterial splatter layer
			if SplatterMask > 0 then
				const FreshRed = math.clamp(math.floor(195 + SplatterMask * 55 + FineNoise * 20), 170, 255) :: number
				const Blend = math.clamp(SplatterMask * 1.8, 0, 1) :: number
				Red = math.floor(Red * (1 - Blend) + FreshRed * Blend)
				Green = math.floor(Green * (1 - Blend) + 10 * Blend)
				Blue = math.floor(Blue * (1 - Blend) + 12 * Blend)
			end

			-- Deep dark coagulated blood clots and veins
			if ClotMask > 0 or OrganicVariation < -0.22 then
				const DarkFactor = math.max(ClotMask * 0.85, math.clamp((-OrganicVariation - 0.22) * 2.2, 0, 0.8)) :: number
				Red = math.floor(Red * (1 - DarkFactor) + 28 * DarkFactor)
				Green = math.floor(Green * (1 - DarkFactor))
				Blue = math.floor(Blue * (1 - DarkFactor) + 2 * DarkFactor)
			end

			-- Glossy wet blood highlight
			if WetHighlight > 0 and FineNoise > -0.1 then
				Red = 255
				Green = 75
				Blue = 70
			end

			buffer.writeu32(PixelBuffer, RowOffset + TexelX * 4, PackRGBA(Red, Green, Blue, 255))
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
	Returns the cached synchronous procedural blood texture buffer and its dimensions.
	@return (buffer, number, number) -- TextureBuffer, TextureWidth, TextureHeight.
]=]
function TextureHelper.GetDefaultTexture(): (buffer, number, number)
	if not CachedDefaultTexture then
		CachedDefaultTexture = TextureHelper.CreateProceduralTemplateTexture(TEXTURE_SIZE)
	end

	return CachedDefaultTexture :: buffer, TEXTURE_SIZE, TEXTURE_SIZE
end

--[=[
	Loads an optional Roblox texture URI or returns the procedural blood texture.
	@param TextureUri string? -- Optional asset URI override (defaults to SystemsConfigs.DefaultTextureUri).
	@param TargetSize number? -- Optional square target size in texels (defaults to SystemsConfigs.TextureSize).
	@return (buffer, number, number) -- TextureBuffer, TextureWidth, TextureHeight.
]=]
function TextureHelper.LoadRobloxTemplateTexture(TextureUri: string?, TargetSize: number?): (buffer, number, number)
	const ResolvedUri = TextureUri or DEFAULT_TEXTURE_URI :: string
	const ResolvedSize = TargetSize or TEXTURE_SIZE :: number
	const BaseTemplate = TextureHelper.CreateProceduralTemplateTexture(ResolvedSize)

	if ResolvedUri == "" then
		return BaseTemplate, ResolvedSize, ResolvedSize
	end

	const Success: boolean, LoadedResult: any = pcall(function()
		return AssetService:CreateEditableImageAsync(Content.fromUri(ResolvedUri))
	end)

	if Success and LoadedResult then
		const EditableImage = LoadedResult :: EditableImage
		const ImageSize = EditableImage.Size :: Vector2
		const RawPixels = EditableImage:ReadPixelsBuffer(Vector2.zero, ImageSize) :: buffer
		EditableImage:Destroy()

		const Resampled = TextureHelper.ResampleTextureBuffer(RawPixels, ImageSize.X, ImageSize.Y, ResolvedSize)
		return Resampled, ResolvedSize, ResolvedSize
	end

	return BaseTemplate, ResolvedSize, ResolvedSize
end

return TextureHelper
