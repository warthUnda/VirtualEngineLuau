--!native
--!optimize 2

-- Services --
const ServerScriptService = game:GetService("ServerScriptService") :: ServerScriptService

-- Static References --
const Workspace = workspace :: Workspace
const StorageFolder = ServerScriptService.Server.Objects.ObjectsECS.Storage :: Folder

-- Modules --
const ECSData = require(StorageFolder.ECSData) :: ModuleScript
const PositionData = require(StorageFolder.PositionData) :: ModuleScript
const OrientationData = require(StorageFolder.OrientationData) :: ModuleScript
const VisualData = require(StorageFolder.VisualData) :: ModuleScript
const SizeData = require(StorageFolder.SizeData) :: ModuleScript
const DirectionsData = require(StorageFolder.DirectionsData) :: ModuleScript

-- Configs --
const ENTITY_STRIDE = 12 :: number
const DIRECTION_STRIDE = 36 :: number

-- Tables --
local StaticFolder = Workspace:FindFirstChild("Static") :: Folder?

-- Registers one BasePart into the ECS component buffers.
local function PopulatePart(Part: BasePart)
	if not StaticFolder then
		StaticFolder = Workspace:FindFirstChild("Static") :: Folder?
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
end

-- ============================================================================
-- 1. WORKSPACE SEED & LISTENER
-- ============================================================================

-- Seed the ECS with everything already present in the workspace.
for _, Descendant: Instance in ipairs(Workspace:GetDescendants()) do
	if Descendant:IsA("BasePart") then
		PopulatePart(Descendant)
	end
end

-- Keep the ECS populated as parts are added at runtime.
Workspace.DescendantAdded:Connect(function(Descendant: Instance)
	if Descendant:IsA("BasePart") then
		PopulatePart(Descendant)
	end
end)
