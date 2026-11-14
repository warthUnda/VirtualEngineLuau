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
-- 1. TEXTURE RESAMPLING & 64x64 URL DECODING
-- ============================================================================

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
	Decodes a raw Roblox texture URL into a TargetSize x TargetSize RGBA buffer using EditableImage.
	@param RawUrl string -- Raw Roblox texture URL (e.g. "rbxassetid://..." or "rbxasset://...").
	@param TargetSize number? -- Optional square target size in texels (defaults to RenderConfig.TextureSize).
	@return (buffer?, boolean) -- Decoded RGBA buffer (or nil on empty URI / load failure), and true if decoded.
]=]
function TextureHelper.DecodeUrlToBuffer(RawUrl: string, TargetSize: number?): (buffer?, boolean)
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

	return nil, false
end

return TextureHelper
