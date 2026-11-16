--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSTypes = require(script.Parent.ECSTypes)
const ECSBitfield = require(script.Parent.ECSBitfield)

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const VISUAL_STRIDE = (SystemsConfigs.ECSVisualStride or 4) :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const COMPONENT_BUFFER_SIZE = SystemsConfigs.ECSComponentBufferSize :: number
const DIRECTION_BUFFER_SIZE = SystemsConfigs.ECSDirectionBufferSize :: number
const VISUAL_BUFFER_SIZE = (SystemsConfigs.ECSVisualBufferSize or (SystemsConfigs.ECSMaxEntities * VISUAL_STRIDE)) :: number
const PROPERTIES_BUFFER_SIZE = SystemsConfigs.ECSPropertiesBufferSize :: number
const MAX_ENTITIES = SystemsConfigs.ECSMaxEntities :: number

-- Tables --
local ECSComponents = {}

-- Functions --
-- ============================================================================
-- 1. ENTITY LIFECYCLE & ISOLATED COMPONENT FACTORIES
-- ============================================================================

--[=[
	Registers a new entity slot across the synchronized ECS count table.
]=]
function ECSComponents.RegisterEntity(Counts: ECSTypes.ECSTable, StaticBuffer: buffer?, IsStatic: boolean?): number
	const CurrentCount = Counts.EntityECSCount :: number
	if CurrentCount >= MAX_ENTITIES then
		return 0
	end

	const NextCount = CurrentCount + 1 :: number
	Counts.EntityECSCount = NextCount
	Counts.OrientationECSCount = NextCount
	Counts.PositionECSCount = NextCount
	Counts.VisualECSCount = NextCount
	Counts.SizeECSCount = NextCount
	Counts.DirectionsECSCount = NextCount
	Counts.PropertiesECSCount = NextCount

	if StaticBuffer then
		buffer.writeu8(StaticBuffer, NextCount - 1, if IsStatic then 1 else 0)
	end
	return NextCount
end

--[=[
	Directly resets all component count fields in the ECS table.
]=]
function ECSComponents.SetEntityCount(Counts: ECSTypes.ECSTable, EntityCount: number)
	Counts.EntityECSCount = EntityCount
	Counts.OrientationECSCount = EntityCount
	Counts.PositionECSCount = EntityCount
	Counts.VisualECSCount = EntityCount
	Counts.SizeECSCount = EntityCount
	Counts.DirectionsECSCount = EntityCount
	Counts.PropertiesECSCount = EntityCount
end

--[=[
	Deletes an entity using O(1) swap-and-pop compaction to keep component buffers contiguous.
]=]
function ECSComponents.DeleteEntity(
	EntityId: number,
	Counts: ECSTypes.ECSTable,
	PositionBuffer: buffer,
	OrientationBuffer: buffer?,
	VisualBuffer: buffer,
	SizeBuffer: buffer,
	DirectionsBuffer: buffer,
	StaticBuffer: buffer?,
	PropertiesBuffer: buffer?
)
	const LastEntityId = Counts.EntityECSCount :: number
	if EntityId < 1 or EntityId > LastEntityId then
		return
	end

	if EntityId ~= LastEntityId then
		const TargetOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
		const LastOffset = (LastEntityId - 1) * COMPONENT_STRIDE :: number

		buffer.copy(PositionBuffer, TargetOffset, PositionBuffer, LastOffset, COMPONENT_STRIDE)
		if OrientationBuffer and OrientationBuffer ~= DirectionsBuffer then
			buffer.copy(OrientationBuffer, TargetOffset, OrientationBuffer, LastOffset, COMPONENT_STRIDE)
		end
		buffer.copy(VisualBuffer, (EntityId - 1) * VISUAL_STRIDE, VisualBuffer, (LastEntityId - 1) * VISUAL_STRIDE, VISUAL_STRIDE)
		buffer.copy(SizeBuffer, TargetOffset, SizeBuffer, LastOffset, COMPONENT_STRIDE)
		buffer.copy(DirectionsBuffer, (EntityId - 1) * DIRECTION_STRIDE, DirectionsBuffer, (LastEntityId - 1) * DIRECTION_STRIDE, DIRECTION_STRIDE)

		if PropertiesBuffer then
			buffer.writeu32(PropertiesBuffer, (EntityId - 1) * PROPERTIES_STRIDE, buffer.readu32(PropertiesBuffer, (LastEntityId - 1) * PROPERTIES_STRIDE))
		end
		if StaticBuffer then
			buffer.writeu8(StaticBuffer, EntityId - 1, buffer.readu8(StaticBuffer, LastEntityId - 1))
		end
	end

	if PropertiesBuffer then
		buffer.writeu32(PropertiesBuffer, (LastEntityId - 1) * PROPERTIES_STRIDE, 0)
	end
	if StaticBuffer then
		buffer.writeu8(StaticBuffer, LastEntityId - 1, 0)
	end

	ECSComponents.SetEntityCount(Counts, LastEntityId - 1)
end

function ECSComponents.CreateVector3Component(): ECSTypes.Vector3Component
	const ComponentBuffer = buffer.create(COMPONENT_BUFFER_SIZE) :: buffer
	return {
		CreateLayout = function(MemoryOffset: number, X: number, Y: number, Z: number): number
			return ECSBitfield.CreateVector3Layout(ComponentBuffer, MemoryOffset, X, Y, Z)
		end,
		GetData = function(): buffer
			return ComponentBuffer
		end,
	}
end

function ECSComponents.CreateVisualComponent(): ECSTypes.VisualComponent
	const VisualBuffer = buffer.create(VISUAL_BUFFER_SIZE) :: buffer
	return {
		CreateLayout = function(MemoryOffset: number, R: number, G: number, B: number, A: number?): number
			return ECSBitfield.CreateVisualLayout(VisualBuffer, MemoryOffset, R, G, B, A)
		end,
		GetData = function(): buffer
			return VisualBuffer
		end,
	}
end

function ECSComponents.CreateDirectionsComponent(): ECSTypes.DirectionsComponent
	const DirectionsBuffer = buffer.create(DIRECTION_BUFFER_SIZE) :: buffer
	return {
		CreateLayout = function(
			MemoryOffset: number,
			LookX: number, LookY: number, LookZ: number,
			UpX: number, UpY: number, UpZ: number,
			RightX: number, RightY: number, RightZ: number
		): number
			return ECSBitfield.CreateDirectionsLayout(DirectionsBuffer, MemoryOffset, LookX, LookY, LookZ, UpX, UpY, UpZ, RightX, RightY, RightZ)
		end,
		GetData = function(): buffer
			return DirectionsBuffer
		end,
	}
end

function ECSComponents.CreatePropertiesComponent(
	TargetBuffer: buffer?, MemoryOffset: number?,
	CanCollide: boolean?, IsVisible: boolean?, Anchored: boolean?,
	DynamicId: number?, TextureId: number?, ShapeId: number?
): any
	if TargetBuffer and MemoryOffset then
		return ECSBitfield.CreatePropertiesLayout(TargetBuffer, MemoryOffset, CanCollide, IsVisible, Anchored, DynamicId, TextureId, ShapeId)
	end

	const PropertiesBuffer = buffer.create(PROPERTIES_BUFFER_SIZE) :: buffer
	return {
		CreateLayout = function(
			Offset: number, Collide: boolean?, Visible: boolean?, IsAnchored: boolean?,
			DynId: number?, TexId: number?, ShpId: number?
		): number
			return ECSBitfield.CreatePropertiesLayout(PropertiesBuffer, Offset, Collide, Visible, IsAnchored, DynId, TexId, ShpId)
		end,
		GetData = function(): buffer
			return PropertiesBuffer
		end,
	}
end

return ECSComponents
