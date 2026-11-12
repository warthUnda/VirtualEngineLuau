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

local TestHelper = {}

-- ============================================================================
-- 1. CLIENT TEST FIXTURES
-- ============================================================================

--[=[
	Creates an isolated ECSStorage instance for client unit tests.
	@return ECSMain.ECSStorage -- Fresh ECS storage instance.
]=]
function TestHelper.CreateTestStorage(): ECSMain.ECSStorage
	return ECSMain.CreateStorage(false)
end

--[=[
	Populates an entity slot in an ECS storage with explicit component values.
	@param Storage ECSMain.ECSStorage -- Target storage.
	@param Pos Vector3 -- World position.
	@param Look Vector3 -- Basis LookVector.
	@param Up Vector3 -- Basis UpVector.
	@param Right Vector3 -- Basis RightVector.
	@param Size Vector3 -- Part dimensions.
	@param Color Color3 -- Display color.
	@return number -- Entity ID.
]=]
function TestHelper.PopulateEntity(
	Storage: ECSMain.ECSStorage,
	Pos: Vector3,
	Look: Vector3,
	Up: Vector3,
	Right: Vector3,
	Size: Vector3,
	Color: Color3
): number
	const EntityId = Storage.ECSData.RegisterEntity() :: number
	const Offset = (EntityId - 1) * COMPONENT_STRIDE :: number
	const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number

	Storage.PositionData.CreateLayout(Offset, Pos.X, Pos.Y, Pos.Z)
	Storage.OrientationData.CreateLayout(Offset, Look.X, Look.Y, Look.Z)
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
	Storage.SizeData.CreateLayout(Offset, Size.X, Size.Y, Size.Z)
	Storage.VisualData.CreateLayout(
		Offset,
		math.floor(Color.R * 255),
		math.floor(Color.G * 255),
		math.floor(Color.B * 255)
	)

	return EntityId
end

return TestHelper
