--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const TextureHelper = require(script.Parent.TextureHelper)

-- Configs --
const TEXTURE_SIZE = SystemsConfigs.TextureSize :: number

-- Buffers
const DefaultWoodBuffer = TextureHelper.CreateProceduralWoodTexture(TEXTURE_SIZE) :: buffer
const DefaultStudBuffer = TextureHelper.CreateProceduralStudTexture(TEXTURE_SIZE) :: buffer

local NextDynamicId = 1 :: number

local TextureTable = {}

-- ============================================================================
-- 1. TEXTURE TRANSLATOR, DEDUPLICATED URL REGISTRY & 64x64 BUFFER CACHE
-- ============================================================================

-- Translator table: numeric ECS TextureId -> texture name
TextureTable.IdToName = {
	[1] = "WoodTexture",
	[2] = "StudTexture",
} :: { [number]: string }

-- Reverse translator table: texture name -> numeric ECS TextureId
TextureTable.NameToId = {
	WoodTexture = 1,
	StudTexture = 2,
} :: { [string]: number }

-- URL translator maps for deduplication and client-side decoding
TextureTable.IdToUrl = {} :: { [number]: string }
TextureTable.UrlToId = {} :: { [string]: number }

-- Cached 64x64 RGBA texture buffers indexed by numeric ECS TextureId
TextureTable.CachedBuffers = {
	[1] = DefaultWoodBuffer,
	[2] = DefaultStudBuffer,
} :: { [number]: buffer }

--[=[
	Trims surrounding whitespace from a raw Roblox asset URL.
	@param RawUrl string -- Raw Roblox texture URL.
	@return string -- Normalized URL string.
]=]
function TextureTable.NormalizeUrl(RawUrl: string): string
	return (string.match(RawUrl, "^%s*(.-)%s*$") or "") :: string
end

--[=[
	Decodes a raw Roblox texture URL into a 64x64 RGBA buffer using the renderer's EditableImage pipeline.
	@param RawUrl string -- Raw Roblox asset URL (e.g. "rbxassetid://123456789").
	@param FallbackBuffer buffer? -- Optional fallback 64x64 buffer if Url is empty or fails to load.
	@return (buffer, boolean) -- Decoded (or fallback) 64x64 RGBA buffer, and true if decoded from RawUrl.
]=]
function TextureTable.DecodeRawUrl(RawUrl: string, FallbackBuffer: buffer?): (buffer, boolean)
	return TextureHelper.DecodeUrlToBuffer(RawUrl, FallbackBuffer, TEXTURE_SIZE)
end

--[=[
	Returns a deterministic procedural 64x64 fallback buffer for a given TextureId slot.
	@param TextureId number -- Numeric TextureId slot.
	@return buffer -- Procedural 64x64 RGBA buffer.
]=]
local function GetFallbackBufferForSlot(TextureId: number): buffer
	if TextureId % 2 == 1 then
		return DefaultWoodBuffer
	end
	return DefaultStudBuffer
end

--[=[
	Clears all dynamic and default entries from TextureTable before scanning Workspace decals.
]=]
function TextureTable.ResetEntries()
	table.clear(TextureTable.IdToName)
	table.clear(TextureTable.NameToId)
	table.clear(TextureTable.IdToUrl)
	table.clear(TextureTable.UrlToId)
	table.clear(TextureTable.CachedBuffers)
	NextDynamicId = 1
end

--[=[
	Populates fallback WoodTexture (1) and StudTexture (2) entries if no decals were registered.
]=]
function TextureTable.EnsureDefaultEntries()
	if next(TextureTable.IdToName) ~= nil then
		return
	end

	TextureTable.IdToName[1] = "WoodTexture"
	TextureTable.IdToName[2] = "StudTexture"
	TextureTable.NameToId["WoodTexture"] = 1
	TextureTable.NameToId["StudTexture"] = 2
	TextureTable.CachedBuffers[1] = DefaultWoodBuffer
	TextureTable.CachedBuffers[2] = DefaultStudBuffer
	NextDynamicId = 3
end

--[=[
	Registers a texture URL into TextureTable, ignoring empty or duplicate URLs, and caches its 64x64 buffer.
	@param RawUrl string -- Raw Roblox Decal.Texture URL.
	@param TextureName string? -- Optional human-readable name for the translator table.
	@param DecodeNow boolean? -- Whether to immediately decode via AssetService (defaults to true).
	@return (number, boolean) -- Assigned (or existing) TextureId, and true if newly registered (false if empty or duplicate).
]=]
function TextureTable.RegisterUrl(RawUrl: string, TextureName: string?, DecodeNow: boolean?): (number, boolean)
	const NormalizedUrl = TextureTable.NormalizeUrl(RawUrl)
	if NormalizedUrl == "" then
		return 0, false
	end

	-- Ignore duplicate URLs and return the already-registered TextureId
	const ExistingId = TextureTable.UrlToId[NormalizedUrl]
	if ExistingId then
		return ExistingId, false
	end

	const AssignedId = NextDynamicId :: number
	NextDynamicId += 1

	const ResolvedName = if TextureName and TextureName ~= ""
		then TextureName
		else ("Decal_" .. tostring(AssignedId))

	TextureTable.IdToName[AssignedId] = ResolvedName
	if not TextureTable.NameToId[ResolvedName] then
		TextureTable.NameToId[ResolvedName] = AssignedId
	end
	TextureTable.IdToUrl[AssignedId] = NormalizedUrl
	TextureTable.UrlToId[NormalizedUrl] = AssignedId

	const FallbackBuffer = GetFallbackBufferForSlot(AssignedId)
	if DecodeNow ~= false then
		const DecodedBuffer = TextureTable.DecodeRawUrl(NormalizedUrl, FallbackBuffer)
		TextureTable.CachedBuffers[AssignedId] = DecodedBuffer
	else
		TextureTable.CachedBuffers[AssignedId] = FallbackBuffer
	end

	return AssignedId, true
end

--[=[
	Registers and decodes a replicated TextureId + URL entry into TextureTable.CachedBuffers, skipping duplicates.
	@param TextureId number -- Replicated numeric TextureId.
	@param RawUrl string -- Raw Roblox Decal.Texture URL.
	@param TextureName string? -- Optional texture name.
	@return (buffer, boolean) -- Cached 64x64 RGBA buffer, and true if newly decoded/updated.
]=]
function TextureTable.RegisterEntryWithId(TextureId: number, RawUrl: string, TextureName: string?): (buffer, boolean)
	const NormalizedUrl = TextureTable.NormalizeUrl(RawUrl)
	const FallbackBuffer = GetFallbackBufferForSlot(TextureId)
	if NormalizedUrl == "" then
		TextureTable.CachedBuffers[TextureId] = TextureTable.CachedBuffers[TextureId] or FallbackBuffer
		return TextureTable.CachedBuffers[TextureId], false
	end

	if TextureTable.IdToUrl[TextureId] == NormalizedUrl and TextureTable.CachedBuffers[TextureId] then
		return TextureTable.CachedBuffers[TextureId], false
	end

	-- If this URL was already decoded under another slot, reuse its cached 64x64 buffer without re-downloading
	const ExistingUrlId = TextureTable.UrlToId[NormalizedUrl]
	if ExistingUrlId and TextureTable.CachedBuffers[ExistingUrlId] then
		const SharedBuffer = TextureTable.CachedBuffers[ExistingUrlId]
		TextureTable.IdToUrl[TextureId] = NormalizedUrl
		TextureTable.CachedBuffers[TextureId] = SharedBuffer
		if TextureName and TextureName ~= "" then
			TextureTable.IdToName[TextureId] = TextureName
			if not TextureTable.NameToId[TextureName] then
				TextureTable.NameToId[TextureName] = TextureId
			end
		end
		return SharedBuffer, true
	end

	const ResolvedName = if TextureName and TextureName ~= ""
		then TextureName
		else ("Decal_" .. tostring(TextureId))

	TextureTable.IdToName[TextureId] = ResolvedName
	if not TextureTable.NameToId[ResolvedName] then
		TextureTable.NameToId[ResolvedName] = TextureId
	end
	TextureTable.IdToUrl[TextureId] = NormalizedUrl
	TextureTable.UrlToId[NormalizedUrl] = TextureId

	if TextureId >= NextDynamicId then
		NextDynamicId = TextureId + 1
	end

	const DecodedBuffer = TextureTable.DecodeRawUrl(NormalizedUrl, FallbackBuffer)
	TextureTable.CachedBuffers[TextureId] = DecodedBuffer
	return DecodedBuffer, true
end

--[=[
	Returns a sorted array of all currently registered TextureIds in TextureTable.
	@return { number } -- Sorted list of registered numeric TextureIds.
]=]
function TextureTable.GetRegisteredIds(): { number }
	const Ids = {} :: { number }
	for TextureId in pairs(TextureTable.IdToName) do
		table.insert(Ids, TextureId)
	end
	table.sort(Ids)
	return Ids
end

--[=[
	Translates a numeric ECS TextureId into its registered texture name.
	@param TextureId number -- Numeric TextureId stored in the ECS Properties bitfield.
	@return string -- Texture name (defaults to "WoodTexture" if unknown).
]=]
function TextureTable.TranslateIdToName(TextureId: number): string
	return TextureTable.IdToName[TextureId] or "WoodTexture"
end

--[=[
	Translates a texture name into its numeric ECS TextureId.
	@param TextureName string -- Registered texture name (e.g. "WoodTexture", "StudTexture", or Decal name).
	@return number -- Numeric TextureId (0 if not registered).
]=]
function TextureTable.TranslateNameToId(TextureName: string): number
	return TextureTable.NameToId[TextureName] or 0
end

--[=[
	Returns the cached 64x64 RGBA texture buffer for a given TextureId.
	@param TextureId number -- Numeric TextureId from the ECS Properties bitfield.
	@return buffer -- Cached 64x64 RGBA pixel buffer.
]=]
function TextureTable.GetTextureBuffer(TextureId: number): buffer
	const Cached = TextureTable.CachedBuffers[TextureId]
	if Cached then
		return Cached
	end

	return TextureTable.CachedBuffers[1] or DefaultWoodBuffer
end

--[=[
	Returns the table of all cached 64x64 RGBA texture buffers keyed by TextureId.
	@return { [number]: buffer } -- Cached texture buffer map.
]=]
function TextureTable.GetAllCachedBuffers(): { [number]: buffer }
	return TextureTable.CachedBuffers
end

return TextureTable
