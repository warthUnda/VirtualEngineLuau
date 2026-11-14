--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const ServerScriptService = game:GetService("ServerScriptService")

-- Static References --
const Workspace = workspace :: Workspace

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const TextureTable = require(ReplicatedStorage.Shared.Utilities.Render.Core.TextureTable)
const Storage = require(ServerScriptService.Server.Objects.ObjectsECS.Storage)
const ECSData = Storage.ECSData
const PositionData = Storage.PositionData
const OrientationData = Storage.OrientationData
const VisualData = Storage.VisualData
const SizeData = Storage.SizeData
const DirectionsData = Storage.DirectionsData
const PropertiesData = Storage.PropertiesData

-- Configs --
const ENTITY_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const STATIC_FOLDER_NAME = SystemsConfigs.StaticObjectsFolderName :: string
const TEXTURE_REGISTRY_FOLDER_NAME = SystemsConfigs.TextureRegistryFolderName :: string

-- Tables --
local StaticFolder = Workspace:FindFirstChild(STATIC_FOLDER_NAME) :: Folder?
local TextureRegistryFolder = ReplicatedStorage:FindFirstChild(TEXTURE_REGISTRY_FOLDER_NAME) :: Folder?
if not TextureRegistryFolder then
	const NewFolder = Instance.new("Folder")
	NewFolder.Name = TEXTURE_REGISTRY_FOLDER_NAME
	NewFolder.Parent = ReplicatedStorage
	TextureRegistryFolder = NewFolder
end

local ECSBuilderHelper = {}

-- ============================================================================
-- 1. WORKSPACE DECAL DISCOVERY & TEXTURE TABLE POPULATION
-- ============================================================================

--[=[
	Registers a Workspace Decal's Texture URL into TextureTable (ignoring duplicate URLs), caches its 64x64 buffer, and replicates the entry.
	@param DecalInstance Decal -- Source Roblox Decal instance.
	@return number -- Assigned (or existing) TextureTable ID (0 if URL is empty).
]=]
function ECSBuilderHelper.RegisterDecal(DecalInstance: Decal): number
	const TextureId: number, IsNew: boolean = TextureTable.RegisterUrl(DecalInstance.Texture, DecalInstance.Name, true)
	if TextureId == 0 then
		return 0
	end

	if IsNew then
		const RegistryFolder = TextureRegistryFolder :: Folder
		const ExistingEntry = RegistryFolder:FindFirstChild(tostring(TextureId))
		if not ExistingEntry then
			const EntryValue = Instance.new("StringValue")
			EntryValue.Name = tostring(TextureId)
			EntryValue.Value = TextureTable.IdToUrl[TextureId] or ""
			EntryValue:SetAttribute("TextureName", TextureTable.TranslateIdToName(TextureId))
			EntryValue.Parent = RegistryFolder
		end
	end

	return TextureId
end

--[=[
	Scans RootInstance descendants for Decals and populates TextureTable with unique URLs.
	@param RootInstance Instance -- Root container to scan (typically Workspace).
]=]
function ECSBuilderHelper.ScanWorkspaceDecals(RootInstance: Instance)
	TextureTable.ResetEntries()

	for _, Entry: Instance in ipairs((TextureRegistryFolder :: Folder):GetChildren()) do
		Entry:Destroy()
	end

	for _, Descendant: Instance in ipairs(RootInstance:GetDescendants()) do
		if Descendant:IsA("Decal") then
			ECSBuilderHelper.RegisterDecal(Descendant)
		end
	end
end

-- ============================================================================
-- 2. WORKSPACE BASEPART ECS REGISTRATION HELPER
-- ============================================================================

--[=[
	Ingests a workspace BasePart into the server ECS storage buffers (position, orientation, basis, size, color, properties).
	@param Part BasePart -- Source Roblox BasePart instance.
]=]
function ECSBuilderHelper.PopulatePart(Part: BasePart)
	if Part:IsA("Terrain") then
		return
	end

	if not StaticFolder then
		StaticFolder = Workspace:FindFirstChild(STATIC_FOLDER_NAME) :: Folder?
	end

	const IsStatic = if StaticFolder then Part:IsDescendantOf(StaticFolder) else false
	const EntityId = ECSData.RegisterEntity(IsStatic) :: number
	const Offset = (EntityId - 1) * ENTITY_STRIDE :: number
	const DirectionOffset = (EntityId - 1) * DIRECTION_STRIDE :: number

	const PartPosition = Part.Position :: Vector3
	PositionData.CreateLayout(Offset, PartPosition.X, PartPosition.Y, PartPosition.Z)

	const PartCFrame = Part.CFrame :: CFrame
	const LookVector = PartCFrame.LookVector :: Vector3
	const UpVector = PartCFrame.UpVector :: Vector3
	const RightVector = PartCFrame.RightVector :: Vector3

	-- Orientation is stored as the part's facing direction (simplified 3-float layout).
	OrientationData.CreateLayout(Offset, LookVector.X, LookVector.Y, LookVector.Z)
	DirectionsData.CreateLayout(
		DirectionOffset,
		LookVector.X,
		LookVector.Y,
		LookVector.Z,
		UpVector.X,
		UpVector.Y,
		UpVector.Z,
		RightVector.X,
		RightVector.Y,
		RightVector.Z
	)

	const PartSize = Part.Size :: Vector3
	SizeData.CreateLayout(Offset, PartSize.X, PartSize.Y, PartSize.Z)

	const PartColor = Part.Color :: Color3
	VisualData.CreateLayout(
		Offset,
		math.floor(PartColor.R * 255),
		math.floor(PartColor.G * 255),
		math.floor(PartColor.B * 255)
	)

	local TextureId = 0 :: number
	const TextureIdAttr = Part:GetAttribute("TextureId")
	if typeof(TextureIdAttr) == "number" and TextureIdAttr > 0 then
		TextureId = TextureIdAttr
	else
		const TextureNameAttr = Part:GetAttribute("TextureName")
		if typeof(TextureNameAttr) == "string" then
			const TranslatedId = TextureTable.TranslateNameToId(TextureNameAttr) :: number
			if TranslatedId > 0 then
				TextureId = TranslatedId
			end
		else
			const PartDecal = Part:FindFirstChildWhichIsA("Decal", true) :: Decal?
			if PartDecal and PartDecal.Texture ~= "" then
				const DecalTextureId = ECSBuilderHelper.RegisterDecal(PartDecal) :: number
				if DecalTextureId > 0 then
					TextureId = DecalTextureId
				end
			end
		end
	end

	const PropertiesOffset = (EntityId - 1) * PROPERTIES_STRIDE :: number
	PropertiesData.CreateLayout(PropertiesOffset, Part.CanCollide, Part.Transparency < 1, Part.Anchored, 0, TextureId)
end

return ECSBuilderHelper
