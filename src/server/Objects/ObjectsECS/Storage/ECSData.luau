--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const Storage = script.Parent :: Folder

-- Modules --
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain")) :: ModuleScript
const PositionData = require(Storage:WaitForChild("PositionData")) :: ModuleScript
const OrientationData = require(Storage:WaitForChild("OrientationData")) :: ModuleScript
const VisualData = require(Storage:WaitForChild("VisualData")) :: ModuleScript
const SizeData = require(Storage:WaitForChild("SizeData")) :: ModuleScript
const DirectionsData = require(Storage:WaitForChild("DirectionsData")) :: ModuleScript

-- Configs --
const COMPONENT_STRIDE = 12 :: number

-- Buffers
const PositionBuffer = PositionData.GetData() :: buffer
const OrientationBuffer = OrientationData.GetData() :: buffer
const VisualBuffer = VisualData.GetData() :: buffer
const SizeBuffer = SizeData.GetData() :: buffer
const DirectionsBuffer = DirectionsData.GetData() :: buffer

const MAX_ENTITIES = buffer.len(PositionBuffer) // COMPONENT_STRIDE :: number
const StaticBuffer = buffer.create(MAX_ENTITIES) :: buffer

local ECSData = {}

ECSData.ECSDataTable = {
	OrientationECSCount = 0,
	PositionECSCount = 0,
	VisualECSCount = 0,
	SizeECSCount = 0,
	DirectionsECSCount = 0,

	EntityECSCount = 0,
}

function ECSData.GetCounts(): { [string]: number }
	return ECSData.ECSDataTable
end

function ECSData.GetStaticData(): buffer
	return StaticBuffer
end

function ECSData.RegisterEntity(IsStatic: boolean?): number
	return ECSMain.RegisterEntity(ECSData.ECSDataTable, StaticBuffer, IsStatic)
end

function ECSData.SetEntityCount(EntityCount: number)
	ECSMain.SetEntityCount(ECSData.ECSDataTable, EntityCount)
end

function ECSData.DeleteEntity(EntityId: number)
	ECSMain.DeleteEntity(
		EntityId,
		ECSData.ECSDataTable,
		PositionBuffer,
		OrientationBuffer,
		VisualBuffer,
		SizeBuffer,
		DirectionsBuffer,
		StaticBuffer
	)
end

return ECSData
