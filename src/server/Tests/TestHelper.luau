--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number

local TestHelper = {}

-- ============================================================================
-- 1. ECS ENTITY TEST FACTORIES
-- ============================================================================

--[=[
	Spawns an oriented box entity inside an ECSStorage with complete transform and property layouts.
	@param Storage ECSMain.ECSStorage -- Target ECS storage.
	@param BoxCFrame CFrame -- World transform CFrame.
	@param Size Vector3 -- Part bounding size.
	@param IsStatic boolean? -- True if static unmoving geometry.
	@param CanCollide boolean? -- True if solid for collision queries.
	@param Anchored boolean? -- True if physics anchored.
	@param DynamicObject any? -- Optional bound OOP object instance.
	@return (number, number) -- EntityId, DynamicId.
]=]
function TestHelper.SpawnBoxEntity(
	Storage: ECSMain.ECSStorage,
	BoxCFrame: CFrame,
	Size: Vector3,
	IsStatic: boolean?,
	CanCollide: boolean?,
	Anchored: boolean?,
	DynamicObject: any?
): (number, number)
	const StaticFlag = if IsStatic ~= nil then IsStatic else true
	const CollideFlag = if CanCollide ~= nil then CanCollide else true
	const AnchoredFlag = if Anchored ~= nil then Anchored else StaticFlag

	const EntityId = Storage.ECSData.RegisterEntity(StaticFlag) :: number
	const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
	const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
	const PropOffset = (EntityId - 1) * PROPERTIES_STRIDE :: number

	const Pos = BoxCFrame.Position
	const Look = BoxCFrame.LookVector
	const Up = BoxCFrame.UpVector
	const Right = BoxCFrame.RightVector

	Storage.PositionData.CreateLayout(CompOffset, Pos.X, Pos.Y, Pos.Z)
	Storage.SizeData.CreateLayout(CompOffset, Size.X, Size.Y, Size.Z)
	Storage.DirectionsData.CreateLayout(
		DirOffset,
		Look.X,
		Look.Y,
		Look.Z,
		Up.X,
		Up.Y,
		Up.Z,
		Right.X,
		Right.Y,
		Right.Z
	)
	Storage.PropertiesData.CreateLayout(PropOffset, CollideFlag, true, AnchoredFlag, 0)

	local DynamicId = 0 :: number
	if DynamicObject ~= nil then
		DynamicId = Storage.DynamicObjectsList.AddObject(DynamicObject, EntityId)
	end

	return EntityId, DynamicId
end

--[=[
	Updates an existing entity's CFrame transform in the ECS storage buffers.
	@param Storage ECSMain.ECSStorage -- Target ECS storage.
	@param EntityId number -- Target entity ID.
	@param NewCFrame CFrame -- New world transform CFrame.
]=]
function TestHelper.MoveEntity(Storage: ECSMain.ECSStorage, EntityId: number, NewCFrame: CFrame)
	const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
	const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number

	const Pos = NewCFrame.Position
	const Look = NewCFrame.LookVector
	const Up = NewCFrame.UpVector
	const Right = NewCFrame.RightVector

	Storage.PositionData.CreateLayout(CompOffset, Pos.X, Pos.Y, Pos.Z)
	Storage.DirectionsData.CreateLayout(
		DirOffset,
		Look.X,
		Look.Y,
		Look.Z,
		Up.X,
		Up.Y,
		Up.Z,
		Right.X,
		Right.Y,
		Right.Z
	)
end

return TestHelper
