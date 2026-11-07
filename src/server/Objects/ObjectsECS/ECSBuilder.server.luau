-- Services --
local Workspace = workspace :: Workspace

-- Modules --
local ECSData = require(game.ServerScriptService.Server.Objects.ObjectsECS.Storage.ECSData)
local PositionData = require(game.ServerScriptService.Server.Objects.ObjectsECS.Storage.PositionData)
local OrientationData = require(game.ServerScriptService.Server.Objects.ObjectsECS.Storage.OrientationData)
local VisualData = require(game.ServerScriptService.Server.Objects.ObjectsECS.Storage.VisualData)

local ENTITY_STRIDE = 12 :: number

-- Registers one BasePart into the ECS component buffers.
local function PopulatePart(Part: BasePart)
	local EntityId = ECSData.RegisterEntity() :: number
	local Offset = (EntityId - 1) * ENTITY_STRIDE

	PositionData.CreateLayout(Offset, Part.Position.X, Part.Position.Y, Part.Position.Z)

	-- Orientation is stored as the part's facing direction (simplified 3-float layout).
	local LookVector = Part.CFrame.LookVector
	OrientationData.CreateLayout(Offset, LookVector.X, LookVector.Y, LookVector.Z)

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
