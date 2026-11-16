--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const RenderConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Configs"):WaitForChild("RenderConfig"))
const TextureHelper = require(script.Parent.TextureHelper)

-- Configs --
const TEXTURE_SIZE = RenderConfig.TextureSize :: number

export type TextureEntry = {
	Id: number,
	Url: string,
	Name: string,
}

-- Variables --
local NextDynamicId = 1 :: number

-- Tables --
local TextureTable = {}
TextureTable.Entries = {} :: { [number]: TextureEntry }
TextureTable.IdToName = {} :: { [number]: string }
TextureTable.NameToId = {} :: { [string]: number }
TextureTable.IdToUrl = {} :: { [number]: string }
TextureTable.UrlToId = {} :: { [string]: number }
TextureTable.CachedBuffers = {} :: { [number]: buffer }

-- Functions --
-- ============================================================================
-- 1. TEXTURE TRANSLATOR, DEDUPLICATED URL REGISTRY & 64x64 BUFFER CACHE
-- ============================================================================

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
	@param RawUrl string -- Raw Roblox asset URL.
	@return (buffer?, boolean) -- Decoded 64x64 RGBA buffer (or nil if empty/failed), and true if decoded.
]=]
function TextureTable.DecodeRawUrl(RawUrl: string): (buffer?, boolean)
	return TextureHelper.DecodeUrlToBuffer(RawUrl, TEXTURE_SIZE)
end

--[=[
	Clears all dynamic entries from TextureTable before scanning Workspace decals.
]=]
function TextureTable.ResetEntries()
	table.clear(TextureTable.Entries)
	table.clear(TextureTable.IdToName)
	table.clear(TextureTable.NameToId)
	table.clear(TextureTable.IdToUrl)
	table.clear(TextureTable.UrlToId)
	table.clear(TextureTable.CachedBuffers)
	NextDynamicId = 1
end

--[=[
	Registers a texture URL into TextureTable, ignoring empty or duplicate URLs, and optionally caches its 64x64 buffer.
	@param RawUrl string -- Raw Roblox Decal.Texture URL.
	@param TextureName string? -- Optional human-readable name for the translator table.
	@param DecodeNow boolean? -- Whether to immediately decode via AssetService (defaults to true).
	@return (number, boolean) -- Assigned (or existing) TextureId, and true if newly registered.
]=]
function TextureTable.RegisterUrl(RawUrl: string, TextureName: string?, DecodeNow: boolean?): (number, boolean)
	const NormalizedUrl = TextureTable.NormalizeUrl(RawUrl)
	if NormalizedUrl == "" then
		return 0, false
	end

	const ExistingId = TextureTable.UrlToId[NormalizedUrl]
	if ExistingId then
		return ExistingId, false
	end

	const AssignedId = NextDynamicId :: number
	NextDynamicId += 1

	const ResolvedName = if TextureName and TextureName ~= "" then TextureName else ("Decal_" .. tostring(AssignedId))
	TextureTable.IdToName[AssignedId] = ResolvedName
	if not TextureTable.NameToId[ResolvedName] then
		TextureTable.NameToId[ResolvedName] = AssignedId
	end
	TextureTable.IdToUrl[AssignedId] = NormalizedUrl
	TextureTable.UrlToId[NormalizedUrl] = AssignedId
	TextureTable.Entries[AssignedId] = { Id = AssignedId, Url = NormalizedUrl, Name = ResolvedName }

	if DecodeNow ~= false then
		const DecodedBuffer = TextureTable.DecodeRawUrl(NormalizedUrl)
		if DecodedBuffer then
			TextureTable.CachedBuffers[AssignedId] = DecodedBuffer
		end
	end

	return AssignedId, true
end

--[=[
	Registers and decodes a replicated TextureId + URL entry into TextureTable.CachedBuffers, skipping duplicates.
	@param TextureId number -- Replicated numeric TextureId.
	@param RawUrl string -- Raw Roblox Decal.Texture URL.
	@param TextureName string? -- Optional texture name.
	@return (buffer?, boolean) -- Cached 64x64 RGBA buffer (or nil), and true if newly decoded/updated.
]=]
function TextureTable.RegisterEntryWithId(TextureId: number, RawUrl: string, TextureName: string?): (buffer?, boolean)
	const NormalizedUrl = TextureTable.NormalizeUrl(RawUrl)
	if NormalizedUrl == "" then
		return TextureTable.CachedBuffers[TextureId], false
	end
	if TextureTable.IdToUrl[TextureId] == NormalizedUrl and TextureTable.CachedBuffers[TextureId] then
		return TextureTable.CachedBuffers[TextureId], false
	end

	const ExistingUrlId = TextureTable.UrlToId[NormalizedUrl]
	if ExistingUrlId and TextureTable.CachedBuffers[ExistingUrlId] then
		const SharedBuffer = TextureTable.CachedBuffers[ExistingUrlId]
		TextureTable.IdToUrl[TextureId] = NormalizedUrl
		TextureTable.CachedBuffers[TextureId] = SharedBuffer
		const ResolvedSharedName = if TextureName and TextureName ~= ""
			then TextureName
			else (TextureTable.IdToName[TextureId] or ("Decal_" .. tostring(TextureId)))
		if TextureName and TextureName ~= "" then
			TextureTable.IdToName[TextureId] = TextureName
			if not TextureTable.NameToId[TextureName] then
				TextureTable.NameToId[TextureName] = TextureId
			end
		end
		TextureTable.Entries[TextureId] = { Id = TextureId, Url = NormalizedUrl, Name = ResolvedSharedName }
		return SharedBuffer, true
	end

	const ResolvedName = if TextureName and TextureName ~= "" then TextureName else ("Decal_" .. tostring(TextureId))
	TextureTable.IdToName[TextureId] = ResolvedName
	if not TextureTable.NameToId[ResolvedName] then
		TextureTable.NameToId[ResolvedName] = TextureId
	end
	TextureTable.IdToUrl[TextureId] = NormalizedUrl
	TextureTable.UrlToId[NormalizedUrl] = TextureId
	TextureTable.Entries[TextureId] = { Id = TextureId, Url = NormalizedUrl, Name = ResolvedName }
	if TextureId >= NextDynamicId then
		NextDynamicId = TextureId + 1
	end

	const DecodedBuffer = TextureTable.DecodeRawUrl(NormalizedUrl)
	if DecodedBuffer then
		TextureTable.CachedBuffers[TextureId] = DecodedBuffer
		return DecodedBuffer, true
	end
	return nil, false
end

--[=[
	Returns a sorted array of all currently registered TextureEntry records from TextureTable.Entries.
	@return { TextureEntry } -- Sorted list of registered texture entries.
]=]
function TextureTable.ExportEntries(): { TextureEntry }
	const Exported = {} :: { TextureEntry }
	for _, Entry: TextureEntry in pairs(TextureTable.Entries) do
		table.insert(Exported, Entry)
	end
	table.sort(Exported, function(A: TextureEntry, B: TextureEntry): boolean
		return A.Id < B.Id
	end)
	return Exported
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
	@return string -- Texture name (empty string if unknown).
]=]
function TextureTable.TranslateIdToName(TextureId: number): string
	return TextureTable.IdToName[TextureId] or ""
end

--[=[
	Translates a texture name into its numeric ECS TextureId.
	@param TextureName string -- Registered texture name.
	@return number -- Numeric TextureId (0 if not registered).
]=]
function TextureTable.TranslateNameToId(TextureName: string): number
	return TextureTable.NameToId[TextureName] or 0
end

--[=[
	Returns the cached 64x64 RGBA texture buffer for a given TextureId, or nil if not cached.
	@param TextureId number -- Numeric TextureId from the ECS Properties bitfield.
	@return buffer? -- Cached 64x64 RGBA pixel buffer (or nil).
]=]
function TextureTable.GetTextureBuffer(TextureId: number): buffer?
	return TextureTable.CachedBuffers[TextureId]
end

--[=[
	Returns the table of all cached 64x64 RGBA texture buffers keyed by TextureId.
	@return { [number]: buffer } -- Cached texture buffer map.
]=]
function TextureTable.GetAllCachedBuffers(): { [number]: buffer }
	return TextureTable.CachedBuffers
end

return TextureTable
