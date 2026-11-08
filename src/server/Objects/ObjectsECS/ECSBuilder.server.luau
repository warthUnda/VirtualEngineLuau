-- Services --
local Workspace = workspace :: Workspace

-- Modules --
local ECSData = require(game.ServerScriptService.Server.Objects.ObjectsECS.Storage.ECSData)
local PositionData = require(game.ServerScriptService.Server.Objects.ObjectsECS.Storage.PositionData)
local OrientationData = require(game.ServerScriptService.Server.Objects.ObjectsECS.Storage.OrientationData)
local VisualData = require(game.ServerScriptService.Server.Objects.ObjectsECS.Storage.VisualData)
local SizeData = require(game.ServerScriptService.Server.Objects.ObjectsECS.Storage.SizeData)
local DirectionsData = require(game.ServerScriptService.Server.Objects.ObjectsECS.Storage.DirectionsData)

local ENTITY_STRIDE = 12 :: number
local DIRECTION_STRIDE = 36 :: number

-- Registers one BasePart into the ECS component buffers.
local function PopulatePart(Part: BasePart)
	local EntityId = ECSData.RegisterEntity() :: number
	local Offset = (EntityId - 1) * ENTITY_STRIDE
	local DirectionOffset = (EntityId - 1) * DIRECTION_STRIDE

	PositionData.CreateLayout(Offset, Part.Position.X, Part.Position.Y, Part.Position.Z)

	local LookVector = Part.CFrame.LookVector
	local UpVector = Part.CFrame.UpVector
	local RightVector = Part.CFrame.RightVector

	-- Orientation is stored as the part's facing direction (simplified 3-float layout).
	OrientationData.CreateLayout(Offset, LookVector.X, LookVector.Y, LookVector.Z)
	DirectionsData.CreateLayout(
		DirectionOffset,
		LookVector.X, LookVector.Y, LookVector.Z,
		UpVector.X, UpVector.Y, UpVector.Z,
		RightVector.X, RightVector.Y, RightVector.Z
	)

	SizeData.CreateLayout(Offset, Part.Size.X, Part.Size.Y, Part.Size.Z)

	VisualData.CreateLayout(
		Offset,
		math.floor(Part.Color.R * 255),
		math.floor(Part.Color.G * 255),
		math.floor(Part.Color.B * 255)
	)
end

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
