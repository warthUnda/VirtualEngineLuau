--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const ServerScriptService = game:GetService("ServerScriptService")

-- Static References --
const Workspace = workspace :: Workspace

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const VerticeFile = require(ReplicatedStorage.Shared.Utilities.Render.Core.VerticeFile)
const TextureTable = require(ReplicatedStorage.Shared.Utilities.Render.Texture.TextureTable)
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
const CORE_EVENTS_FOLDER_NAME = SystemsConfigs.CoreEventsFolderName :: string
const TEXTURE_SYNC_REMOTE_EVENT_NAME = SystemsConfigs.TextureSyncRemoteEventName :: string

-- Tables --
const PART_TYPE_TO_SHAPE_ID = {
	[Enum.PartType.Block] = VerticeFile.ShapeToId.Cube,
	[Enum.PartType.Ball] = VerticeFile.ShapeToId.Sphere,
	[Enum.PartType.Cylinder] = VerticeFile.ShapeToId.Cylinder,
	[Enum.PartType.Wedge] = VerticeFile.ShapeToId.Triangle,
	[Enum.PartType.CornerWedge] = VerticeFile.ShapeToId.Triangle,
} :: { [Enum.PartType]: number }

local StaticFolder = Workspace:FindFirstChild(STATIC_FOLDER_NAME) :: Folder?

local ECSBuilderHelper = {}

-- ============================================================================
-- 1. WORKSPACE DECAL DISCOVERY & TEXTURE TABLE POPULATION
-- ============================================================================

--[=[
	Checks whether an instance belongs to any connected player's character model.
	@param TargetInstance Instance -- Instance to test.
	@return boolean -- True if owned by a player character.
]=]
function ECSBuilderHelper.IsPlayerCharacterInstance(TargetInstance: Instance): boolean
	for _, PlayerObject: Player in ipairs(Players:GetPlayers()) do
		const Character = PlayerObject.Character
		if Character and (TargetInstance == Character or TargetInstance:IsDescendantOf(Character)) then
			return true
		end
	end

	if Players:GetPlayerFromCharacter(TargetInstance) then
		return true
	end

	const AncestorModel = TargetInstance:FindFirstAncestorWhichIsA("Model")
	if AncestorModel and Players:GetPlayerFromCharacter(AncestorModel) then
		return true
	end

	return false
end

--[=[
	Registers a Workspace Decal's Texture URL into TextureTable (ignoring duplicate URLs), caches its 64x64 buffer, and replicates the entry.
	@param DecalInstance Decal -- Source Roblox Decal instance.
	@return number -- Assigned (or existing) TextureTable ID (0 if URL is empty).
]=]
function ECSBuilderHelper.RegisterDecal(DecalInstance: Decal): number
	if ECSBuilderHelper.IsPlayerCharacterInstance(DecalInstance) then
		return 0 -- RETURNS NIL AKA NO TEXTURE
	end

	const TextureId: number, IsNew: boolean = TextureTable.RegisterUrl(DecalInstance.Texture, DecalInstance.Name, false)
	if TextureId == 0 then -- this means that the texture is NIL
		return 0
	end

	if IsNew then
		const CoreEvents = ReplicatedStorage:FindFirstChild(CORE_EVENTS_FOLDER_NAME)
		const TextureSyncEvent = if CoreEvents
			then CoreEvents:FindFirstChild(TEXTURE_SYNC_REMOTE_EVENT_NAME)
			else nil
		if TextureSyncEvent and TextureSyncEvent:IsA("RemoteEvent") then
			TextureSyncEvent:FireAllClients(TextureTable.ExportEntries())
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
	if Part:IsA("Terrain") or ECSBuilderHelper.IsPlayerCharacterInstance(Part) then
		return
	end

	if not StaticFolder or not StaticFolder.Parent then
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

	local ShapeId = VerticeFile.ShapeToId.Cube :: number
	const ShapeIdAttr = Part:GetAttribute("ShapeId")
	const ShapeNameAttr = Part:GetAttribute("Shape")

	if typeof(ShapeIdAttr) == "number" and VerticeFile.IdToShape[ShapeIdAttr] ~= nil then
		ShapeId = ShapeIdAttr
	elseif typeof(ShapeNameAttr) == "string" and VerticeFile.ShapeToId[ShapeNameAttr] ~= nil then
		ShapeId = VerticeFile.ShapeToId[ShapeNameAttr]
	elseif Part:IsA("WedgePart") or Part:IsA("CornerWedgePart") then
		ShapeId = VerticeFile.ShapeToId.Triangle
	elseif Part:IsA("Part") then
		ShapeId = PART_TYPE_TO_SHAPE_ID[Part.Shape] or VerticeFile.ShapeToId.Cube
	end

	const PropertiesOffset = (EntityId - 1) * PROPERTIES_STRIDE :: number
	PropertiesData.CreateLayout(
		PropertiesOffset,
		Part.CanCollide,
		Part.Transparency < 1,
		Part.Anchored,
		0,
		TextureId,
		ShapeId
	)
end

return ECSBuilderHelper
