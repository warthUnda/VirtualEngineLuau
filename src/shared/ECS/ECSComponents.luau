--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSTypes = require(script.Parent.ECSTypes)
const ECSBitfield = require(script.Parent.ECSBitfield)

-- Configs --
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
-- 1. FREE-LIST ENTITY LIFECYCLE & ISOLATED COMPONENT FACTORIES
-- ============================================================================

--[=[
	Updates synchronized high-water mark counts across the ECS count table.
	@param Counts ECSTypes.ECSTable -- Target ECS count table.
	@param HighWaterCount number -- New high-water entity index bound.
]=]
function ECSComponents.SetEntityCount(Counts: ECSTypes.ECSTable, HighWaterCount: number)
	Counts.EntityECSCount = HighWaterCount
	Counts.OrientationECSCount = HighWaterCount
	Counts.PositionECSCount = HighWaterCount
	Counts.VisualECSCount = HighWaterCount
	Counts.SizeECSCount = HighWaterCount
	Counts.DirectionsECSCount = HighWaterCount
	Counts.PropertiesECSCount = HighWaterCount
end

--[=[
	Allocates a 1-based entity slot by popping from the flat FreeSlotsBuffer stack or advancing the high-water mark.
	@param Counts ECSTypes.ECSTable -- Target ECS count table.
	@param ActiveFlags buffer -- Per-slot active occupancy buffer (1 = active, 0 = empty).
	@param FreeSlotsBuffer buffer -- Pre-allocated u32 free-slot stack buffer.
	@param FreeSlotTop number -- Current stack depth in FreeSlotsBuffer.
	@param StaticBuffer buffer? -- Optional static geometry marker buffer.
	@param IsStatic boolean? -- Optional static marker flag.
	@return (number, number) -- Allocated 1-based EntityId (or 0 if at capacity) and updated FreeSlotTop.
]=]
function ECSComponents.RegisterEntity(
	Counts: ECSTypes.ECSTable,
	ActiveFlags: buffer,
	FreeSlotsBuffer: buffer,
	FreeSlotTop: number,
	StaticBuffer: buffer?,
	IsStatic: boolean?
): (number, number)
	const HighWater = Counts.EntityECSCount :: number
	local NextTop = FreeSlotTop :: number
	local SlotId = 0 :: number

	while NextTop > 0 do
		NextTop -= 1
		const Candidate = buffer.readu32(FreeSlotsBuffer, NextTop * 4) :: number
		if Candidate >= 1 and Candidate <= HighWater and buffer.readu8(ActiveFlags, Candidate - 1) == 0 then
			SlotId = Candidate
			break
		end
	end

	if SlotId == 0 then
		if HighWater >= MAX_ENTITIES then
			return 0, NextTop
		end
		SlotId = HighWater + 1
		ECSComponents.SetEntityCount(Counts, SlotId)
	end

	Counts.ActiveEntityCount += 1
	buffer.writeu8(ActiveFlags, SlotId - 1, 1)
	if StaticBuffer then
		buffer.writeu8(StaticBuffer, SlotId - 1, if IsStatic then 1 else 0)
	end
	return SlotId, NextTop
end

--[=[
	Frees an entity slot in place into FreeSlotsBuffer without moving any other entities, trimming trailing empty slots.
	@param EntityId number -- 1-based entity slot to release.
	@param Counts ECSTypes.ECSTable -- Target ECS count table.
	@param ActiveFlags buffer -- Per-slot active occupancy buffer.
	@param FreeSlotsBuffer buffer -- Pre-allocated u32 free-slot stack buffer.
	@param FreeSlotTop number -- Current stack depth in FreeSlotsBuffer.
	@param StaticBuffer buffer? -- Optional static geometry marker buffer.
	@param PropertiesBuffer buffer? -- Optional properties bitfield buffer to zero out.
	@return number -- Updated FreeSlotTop stack depth.
]=]
function ECSComponents.DeleteEntity(
	EntityId: number,
	Counts: ECSTypes.ECSTable,
	ActiveFlags: buffer,
	FreeSlotsBuffer: buffer,
	FreeSlotTop: number,
	StaticBuffer: buffer?,
	PropertiesBuffer: buffer?
): number
	const HighWater = Counts.EntityECSCount :: number
	if EntityId < 1 or EntityId > HighWater or buffer.readu8(ActiveFlags, EntityId - 1) == 0 then
		return FreeSlotTop
	end

	buffer.writeu8(ActiveFlags, EntityId - 1, 0)
	if PropertiesBuffer then
		buffer.writeu32(PropertiesBuffer, (EntityId - 1) * PROPERTIES_STRIDE, 0)
	end
	if StaticBuffer then
		buffer.writeu8(StaticBuffer, EntityId - 1, 0)
	end

	const RemainingActive = Counts.ActiveEntityCount - 1 :: number
	if RemainingActive <= 0 then
		Counts.ActiveEntityCount = 0
		ECSComponents.SetEntityCount(Counts, 0)
		return 0
	end
	Counts.ActiveEntityCount = RemainingActive

	if EntityId == HighWater then
		local TrimmedHigh = HighWater - 1 :: number
		while TrimmedHigh > 0 and buffer.readu8(ActiveFlags, TrimmedHigh - 1) == 0 do
			TrimmedHigh -= 1
		end
		ECSComponents.SetEntityCount(Counts, TrimmedHigh)
		return FreeSlotTop
	end

	buffer.writeu32(FreeSlotsBuffer, FreeSlotTop * 4, EntityId)
	return FreeSlotTop + 1
end

--[=[
	Constructs an isolated Vector3 component stream buffer and layout encoder.
	@return ECSTypes.Vector3Component -- Initialized Vector3 component interface.
]=]
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

--[=[
	Constructs an isolated visual color component stream buffer and layout encoder.
	@return ECSTypes.VisualComponent -- Initialized Visual component interface.
]=]
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

--[=[
	Constructs an isolated directions (look, up, right basis) component stream buffer and layout encoder.
	@return ECSTypes.DirectionsComponent -- Initialized Directions component interface.
]=]
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

--[=[
	Constructs an isolated properties bitfield component stream buffer or encodes directly into an existing buffer.
	@param TargetBuffer buffer? -- Optional target buffer to encode layout directly into.
	@param MemoryOffset number? -- Optional memory offset for direct encoding.
	@param CanCollide boolean? -- Optional CanCollide bit flag.
	@param IsVisible boolean? -- Optional IsVisible bit flag.
	@param Anchored boolean? -- Optional Anchored bit flag.
	@param DynamicId number? -- Optional DynamicId identifier.
	@param TextureId number? -- Optional TextureId index.
	@param ShapeId number? -- Optional ShapeId index.
	@return any -- Encoded offset (number) if writing to buffer, or ECSTypes.PropertiesComponent table.
]=]
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
