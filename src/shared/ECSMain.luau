--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs")) :: ModuleScript

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const COMPONENT_BUFFER_SIZE = SystemsConfigs.ECSComponentBufferSize :: number
const DIRECTION_BUFFER_SIZE = SystemsConfigs.ECSDirectionBufferSize :: number
const MAX_ENTITIES = SystemsConfigs.ECSMaxEntities :: number

export type ECSTable = {
	OrientationECSCount: number,
	PositionECSCount: number,
	VisualECSCount: number,
	SizeECSCount: number,
	DirectionsECSCount: number,
	EntityECSCount: number,
}

local ECSMain = {}

-- ============================================================================
-- 1. COMPONENT STORAGE FACTORIES
-- ============================================================================

-- Used by 3-float (12-byte stride) component modules: PositionData, OrientationData, SizeData.
function ECSMain.CreateVector3Component()
	const ComponentBuffer = buffer.create(COMPONENT_BUFFER_SIZE) :: buffer
	local Component = {}

	function Component.CreateLayout(MemoryOffset: number, X: number, Y: number, Z: number): number
		buffer.writef32(ComponentBuffer, MemoryOffset, X)
		buffer.writef32(ComponentBuffer, MemoryOffset + 4, Y)
		buffer.writef32(ComponentBuffer, MemoryOffset + 8, Z)

		return MemoryOffset + COMPONENT_STRIDE
	end

	function Component.GetData(): buffer
		return ComponentBuffer
	end

	return Component
end

-- Used by VisualData (RGB u8 channels stored in a 12-byte stride layout).
function ECSMain.CreateVisualComponent()
	const VisualBuffer = buffer.create(COMPONENT_BUFFER_SIZE) :: buffer
	local VisualComponent = {}

	function VisualComponent.CreateLayout(MemoryOffset: number, R: number, G: number, B: number): number
		buffer.writeu8(VisualBuffer, MemoryOffset, R)
		buffer.writeu8(VisualBuffer, MemoryOffset + 1, G)
		buffer.writeu8(VisualBuffer, MemoryOffset + 2, B)

		return MemoryOffset + COMPONENT_STRIDE
	end

	function VisualComponent.GetData(): buffer
		return VisualBuffer
	end

	return VisualComponent
end

-- Used by DirectionsData (LookVector, UpVector, RightVector stored as 9 x f32 = 36-byte stride).
function ECSMain.CreateDirectionsComponent()
	const DirectionsBuffer = buffer.create(DIRECTION_BUFFER_SIZE) :: buffer
	local DirectionsComponent = {}

	function DirectionsComponent.CreateLayout(
		MemoryOffset: number,
		LookX: number,
		LookY: number,
		LookZ: number,
		UpX: number,
		UpY: number,
		UpZ: number,
		RightX: number,
		RightY: number,
		RightZ: number
	): number
		buffer.writef32(DirectionsBuffer, MemoryOffset, LookX)
		buffer.writef32(DirectionsBuffer, MemoryOffset + 4, LookY)
		buffer.writef32(DirectionsBuffer, MemoryOffset + 8, LookZ)

		buffer.writef32(DirectionsBuffer, MemoryOffset + 12, UpX)
		buffer.writef32(DirectionsBuffer, MemoryOffset + 16, UpY)
		buffer.writef32(DirectionsBuffer, MemoryOffset + 20, UpZ)

		buffer.writef32(DirectionsBuffer, MemoryOffset + 24, RightX)
		buffer.writef32(DirectionsBuffer, MemoryOffset + 28, RightY)
		buffer.writef32(DirectionsBuffer, MemoryOffset + 32, RightZ)

		return MemoryOffset + DIRECTION_STRIDE
	end

	function DirectionsComponent.GetData(): buffer
		return DirectionsBuffer
	end

	return DirectionsComponent
end

function ECSMain.CreatePropertiesComponent()
	local Register = 0

	Register = bit32.bor(
		0,
		bit32.lshift(1, 1), -- CanCollide
		bit32.lshift(1, 2), -- IsVisible
		bit32.lshift(1, 3), -- Anchored
		bit32.lshift(1, 4), -- Has dynamic oop / oject list id?
		bit32.lshift(5, 20) -- DYNAMIC OOP / OBJECTS LIST ID
	)
end

-- ============================================================================
-- 2. ECS ENTITY REGISTRY & LIFECYCLE FACTORY
-- ============================================================================

function ECSMain.CreateECSData(StorageFolder: Folder)
	const PositionData = require(StorageFolder:WaitForChild("PositionData")) :: ModuleScript
	const OrientationData = require(StorageFolder:WaitForChild("OrientationData")) :: ModuleScript
	const VisualData = require(StorageFolder:WaitForChild("VisualData")) :: ModuleScript
	const SizeData = require(StorageFolder:WaitForChild("SizeData")) :: ModuleScript
	const DirectionsData = require(StorageFolder:WaitForChild("DirectionsData")) :: ModuleScript

	const PositionBuffer = PositionData.GetData() :: buffer
	const OrientationBuffer = OrientationData.GetData() :: buffer
	const VisualBuffer = VisualData.GetData() :: buffer
	const SizeBuffer = SizeData.GetData() :: buffer
	const DirectionsBuffer = DirectionsData.GetData() :: buffer
	const StaticBuffer = buffer.create(MAX_ENTITIES) :: buffer

	local ECSData = {}

	ECSData.ECSDataTable = {
		OrientationECSCount = 0,
		PositionECSCount = 0,
		VisualECSCount = 0,
		SizeECSCount = 0,
		DirectionsECSCount = 0,

		EntityECSCount = 0,
	} :: ECSTable

	function ECSData.GetCounts(): { [string]: number }
		return ECSData.ECSDataTable
	end

	function ECSData.GetStaticData(): buffer
		return StaticBuffer
	end

	function ECSData.RegisterEntity(IsStatic: boolean?): number
		const Counts = ECSData.ECSDataTable
		const NextCount = Counts.EntityECSCount + 1 :: number

		Counts.EntityECSCount = NextCount
		Counts.OrientationECSCount = NextCount
		Counts.PositionECSCount = NextCount
		Counts.VisualECSCount = NextCount
		Counts.SizeECSCount = NextCount
		Counts.DirectionsECSCount = NextCount

		if NextCount <= MAX_ENTITIES then
			buffer.writeu8(StaticBuffer, NextCount - 1, if IsStatic then 1 else 0)
		end

		return NextCount
	end

	function ECSData.SetEntityCount(EntityCount: number)
		const Counts = ECSData.ECSDataTable

		Counts.EntityECSCount = EntityCount
		Counts.OrientationECSCount = EntityCount
		Counts.PositionECSCount = EntityCount
		Counts.VisualECSCount = EntityCount
		Counts.SizeECSCount = EntityCount
		Counts.DirectionsECSCount = EntityCount
	end

	function ECSData.DeleteEntity(EntityId: number)
		const Counts = ECSData.ECSDataTable
		const LastEntityId = Counts.EntityECSCount :: number

		if EntityId < 1 or EntityId > LastEntityId then
			return
		end

		if EntityId ~= LastEntityId then
			const TargetOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
			const LastOffset = (LastEntityId - 1) * COMPONENT_STRIDE :: number

			buffer.copy(PositionBuffer, TargetOffset, PositionBuffer, LastOffset, COMPONENT_STRIDE)
			buffer.copy(OrientationBuffer, TargetOffset, OrientationBuffer, LastOffset, COMPONENT_STRIDE)
			buffer.copy(VisualBuffer, TargetOffset, VisualBuffer, LastOffset, COMPONENT_STRIDE)
			buffer.copy(SizeBuffer, TargetOffset, SizeBuffer, LastOffset, COMPONENT_STRIDE)

			const TargetDirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
			const LastDirOffset = (LastEntityId - 1) * DIRECTION_STRIDE :: number
			buffer.copy(DirectionsBuffer, TargetDirOffset, DirectionsBuffer, LastDirOffset, DIRECTION_STRIDE)

			buffer.writeu8(StaticBuffer, EntityId - 1, buffer.readu8(StaticBuffer, LastEntityId - 1))
		end

		buffer.writeu8(StaticBuffer, LastEntityId - 1, 0)

		const NewCount = LastEntityId - 1 :: number
		Counts.EntityECSCount = NewCount
		Counts.OrientationECSCount = NewCount
		Counts.PositionECSCount = NewCount
		Counts.VisualECSCount = NewCount
		Counts.SizeECSCount = NewCount
		Counts.DirectionsECSCount = NewCount
	end

	return ECSData
end

return ECSMain
