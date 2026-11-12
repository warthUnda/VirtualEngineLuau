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

-- Tables --
local StaticFolder = Workspace:FindFirstChild(STATIC_FOLDER_NAME) :: Folder?

local ECSBuilderHelper = {}

-- ============================================================================
-- 1. WORKSPACE BASEPART ECS REGISTRATION HELPER
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

	const PropertiesOffset = (EntityId - 1) * PROPERTIES_STRIDE :: number
	PropertiesData.CreateLayout(PropertiesOffset, Part.CanCollide, Part.Transparency < 1, Part.Anchored, 0)
end

return ECSBuilderHelper
