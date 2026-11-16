--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

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
const MAX_DYNAMIC_ID = SystemsConfigs.DynamicObjectsMaxCount :: number

const FLAG_CAN_COLLIDE = bit32.lshift(1, 1) :: number
const FLAG_IS_VISIBLE = bit32.lshift(1, 2) :: number
const FLAG_ANCHORED = bit32.lshift(1, 3) :: number
const FLAG_HAS_DYNAMIC_ID = bit32.lshift(1, 4) :: number
const TEXTURE_ID_SHIFT = 5 :: number
const MAX_TEXTURE_ID = 255 :: number
const TEXTURE_ID_MASK = bit32.lshift(MAX_TEXTURE_ID, TEXTURE_ID_SHIFT) :: number
const SHAPE_ID_SHIFT = 13 :: number
const MAX_SHAPE_ID = 7 :: number
const SHAPE_ID_MASK = bit32.lshift(MAX_SHAPE_ID, SHAPE_ID_SHIFT) :: number
const DYNAMIC_ID_SHIFT = 22 :: number
const LOWER_FLAGS_MASK = 0x003FFFFF :: number

export type ECSTable = {
	OrientationECSCount: number,
	PositionECSCount: number,
	VisualECSCount: number,
	SizeECSCount: number,
	DirectionsECSCount: number,
	PropertiesECSCount: number?,
	EntityECSCount: number,
}

export type DynamicListCounts = {
	ActiveCount: number,
	NextId: number,
}

export type Vector3Component = {
	CreateLayout: (MemoryOffset: number, X: number, Y: number, Z: number) -> number,
	GetData: () -> buffer,
}

export type VisualComponent = {
	CreateLayout: (MemoryOffset: number, R: number, G: number, B: number) -> number,
	GetData: () -> buffer,
}

export type DirectionsComponent = {
	CreateLayout: (
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
	) -> number,
	GetData: () -> buffer,
}

export type PropertiesComponent = {
	CreateLayout: (
		MemoryOffset: number,
		CanCollide: boolean?,
		IsVisible: boolean?,
		Anchored: boolean?,
		DynamicId: number?,
		TextureId: number?,
		ShapeId: number?
	) -> number,
	GetData: () -> buffer,
}

export type ECSDataComponent = {
	ECSDataTable: ECSTable,
	GetCounts: () -> ECSTable,
	GetStaticData: () -> buffer,
	GetDirtyFlags: () -> buffer,
	GetVersionBuffer: () -> buffer,
	MarkDirty: (EntityId: number) -> (),
	ClearDirty: (EntityId: number) -> (),
	SetSwapPopCallback: (Callback: ((DeletedEntityId: number, MovedFromEntityId: number) -> ())?) -> (),
	RegisterEntity: (IsStatic: boolean?) -> number,
	SetEntityCount: (EntityCount: number) -> (),
	DeleteEntity: (EntityId: number) -> (),
}

export type DynamicObjectsComponent = {
	ObjectsTable: { [number]: any },
	Counts: DynamicListCounts,
	AddObject: (ObjectInstance: any, EntityId: number?) -> number,
	SetObjectAtId: (DynamicId: number, ObjectInstance: any, EntityId: number?) -> boolean,
	GetObject: (DynamicId: number) -> any,
	GetObjectFromRegister: (Register: number) -> any,
	GetObjectByEntityId: (EntityId: number) -> any,
	BindEntity: (DynamicId: number, EntityId: number) -> (),
	GetBoundEntityId: (DynamicId: number) -> number,
	RemoveObject: (DynamicId: number) -> (),
	GetData: () -> { [number]: any },
}

export type ECSStorage = {
	PositionData: Vector3Component,
	OrientationData: Vector3Component,
	VisualData: VisualComponent,
	SizeData: Vector3Component,
	DirectionsData: DirectionsComponent,
	PropertiesData: PropertiesComponent,
	ECSData: ECSDataComponent,
	DynamicObjectsList: DynamicObjectsComponent,
}

-- Tables --
local ECSMain = {}

-- ============================================================================
-- 1. COMPONENT LAYOUT WRITERS & BITPACKED PROPERTIES HELPERS
-- ============================================================================

--[=[
	Writes 3D Vector3 float components (X, Y, Z) into a component buffer.
	@param TargetBuffer buffer -- Target ECS component buffer.
	@param MemoryOffset number -- Byte offset in buffer.
	@param X number -- Vector component X.
	@param Y number -- Vector component Y.
	@param Z number -- Vector component Z.
	@return number -- Next component byte offset.
]=]
function ECSMain.CreateVector3Layout(
	TargetBuffer: buffer,
	MemoryOffset: number,
	X: number,
	Y: number,
	Z: number
): number
	buffer.writef32(TargetBuffer, MemoryOffset, X)
	buffer.writef32(TargetBuffer, MemoryOffset + 4, Y)
	buffer.writef32(TargetBuffer, MemoryOffset + 8, Z)

	return MemoryOffset + COMPONENT_STRIDE
end

--[=[
	Writes 8-bit RGB color channels into a component buffer.
	@param TargetBuffer buffer -- Target visual component buffer.
	@param MemoryOffset number -- Byte offset in buffer.
	@param R number -- Red color channel (0-255).
	@param G number -- Green color channel (0-255).
	@param B number -- Blue color channel (0-255).
	@return number -- Next component byte offset.
]=]
function ECSMain.CreateVisualLayout(
	TargetBuffer: buffer,
	MemoryOffset: number,
	R: number,
	G: number,
	B: number,
	A: number?
): number
	buffer.writeu8(TargetBuffer, MemoryOffset, R)
	buffer.writeu8(TargetBuffer, MemoryOffset + 1, G)
	buffer.writeu8(TargetBuffer, MemoryOffset + 2, B)
	buffer.writeu8(TargetBuffer, MemoryOffset + 3, A or 255)

	return MemoryOffset + VISUAL_STRIDE
end

--[=[
	Writes orientation direction unit vectors (Look, Up, Right) into a direction buffer.
	@param TargetBuffer buffer -- Target directions buffer.
	@param MemoryOffset number -- Byte offset in buffer.
	@param LookX number -- LookVector X.
	@param LookY number -- LookVector Y.
	@param LookZ number -- LookVector Z.
	@param UpX number -- UpVector X.
	@param UpY number -- UpVector Y.
	@param UpZ number -- UpVector Z.
	@param RightX number -- RightVector X.
	@param RightY number -- RightVector Y.
	@param RightZ number -- RightVector Z.
	@return number -- Next direction byte offset.
]=]
function ECSMain.CreateDirectionsLayout(
	TargetBuffer: buffer,
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
	buffer.writef32(TargetBuffer, MemoryOffset, LookX)
	buffer.writef32(TargetBuffer, MemoryOffset + 4, LookY)
	buffer.writef32(TargetBuffer, MemoryOffset + 8, LookZ)

	buffer.writef32(TargetBuffer, MemoryOffset + 12, UpX)
	buffer.writef32(TargetBuffer, MemoryOffset + 16, UpY)
	buffer.writef32(TargetBuffer, MemoryOffset + 20, UpZ)

	buffer.writef32(TargetBuffer, MemoryOffset + 24, RightX)
	buffer.writef32(TargetBuffer, MemoryOffset + 28, RightY)
	buffer.writef32(TargetBuffer, MemoryOffset + 32, RightZ)

	return MemoryOffset + DIRECTION_STRIDE
end

--[=[
	Packs boolean flags, texture ID, and dynamic object ID into a single 32-bit property register.
	@param CanCollide boolean? -- Collision enabled flag.
	@param IsVisible boolean? -- Visibility flag.
	@param Anchored boolean? -- Anchored physics state flag.
	@param DynamicId number? -- Bound dynamic OOP object ID (bits 22-31, 0-1023).
	@param TextureId number? -- TextureTable ID (bits 5-12, 0-255).
	@param ShapeId number? -- VerticeFile shape ID (bits 13-15, 0-7).
	@return number -- Packed 32-bit register.
]=]
function ECSMain.PackProperties(
	CanCollide: boolean?,
	IsVisible: boolean?,
	Anchored: boolean?,
	DynamicId: number?,
	TextureId: number?,
	ShapeId: number?
): number
	const CollideBit = if CanCollide ~= false then 1 else 0 :: number
	const VisibleBit = if IsVisible ~= false then 1 else 0 :: number
	const AnchoredBit = if Anchored ~= false then 1 else 0 :: number
	const ClampedDynamicId = if DynamicId and DynamicId > 0
		then math.min(DynamicId, MAX_DYNAMIC_ID)
		else 0 :: number
	const HasDynamicBit = if ClampedDynamicId > 0 then 1 else 0 :: number
	const ClampedTextureId = if TextureId and TextureId > 0
		then math.clamp(math.floor(TextureId), 0, MAX_TEXTURE_ID)
		else 0 :: number
	const ClampedShapeId = if ShapeId and ShapeId > 0
		then math.clamp(math.floor(ShapeId), 0, MAX_SHAPE_ID)
		else 0 :: number

	return bit32.bor(
		0,
		bit32.lshift(CollideBit, 1), -- CanCollide
		bit32.lshift(VisibleBit, 2), -- IsVisible
		bit32.lshift(AnchoredBit, 3), -- Anchored
		bit32.lshift(HasDynamicBit, 4), -- Has dynamic oop / object list id?
		bit32.lshift(ClampedTextureId, TEXTURE_ID_SHIFT), -- TextureTable ID (bits 5-12)
		bit32.lshift(ClampedShapeId, SHAPE_ID_SHIFT), -- VerticeFile Shape ID (bits 13-15)
		bit32.lshift(ClampedDynamicId, DYNAMIC_ID_SHIFT) -- DYNAMIC OOP / OBJECTS LIST ID (bits 22-31)
	)
end

--[=[
	Packs and writes an entity's 32-bit property register into the properties buffer.
	@param TargetBuffer buffer -- Target properties buffer.
	@param MemoryOffset number -- Byte offset in buffer.
	@param CanCollide boolean? -- Collision enabled flag.
	@param IsVisible boolean? -- Visibility flag.
	@param Anchored boolean? -- Anchored physics state flag.
	@param DynamicId number? -- Bound dynamic OOP object ID.
	@param TextureId number? -- TextureTable ID (0-255).
	@param ShapeId number? -- VerticeFile shape ID (0-7).
	@return number -- Next properties byte offset.
]=]
function ECSMain.CreatePropertiesLayout(
	TargetBuffer: buffer,
	MemoryOffset: number,
	CanCollide: boolean?,
	IsVisible: boolean?,
	Anchored: boolean?,
	DynamicId: number?,
	TextureId: number?,
	ShapeId: number?
): number
	const Register = ECSMain.PackProperties(CanCollide, IsVisible, Anchored, DynamicId, TextureId, ShapeId) :: number
	buffer.writeu32(TargetBuffer, MemoryOffset, Register)

	return MemoryOffset + PROPERTIES_STRIDE
end

--[=[
	Checks whether the CanCollide bit is set in a 32-bit property register.
	@param Register number -- 32-bit property register.
	@return boolean -- True if collidable.
]=]
function ECSMain.CanEntityCollide(Register: number): boolean
	return bit32.btest(Register, FLAG_CAN_COLLIDE)
end

--[=[
	Checks whether the IsVisible bit is set in a 32-bit property register.
	@param Register number -- 32-bit property register.
	@return boolean -- True if visible.
]=]
function ECSMain.IsEntityVisible(Register: number): boolean
	return bit32.btest(Register, FLAG_IS_VISIBLE)
end

--[=[
	Checks whether the Anchored bit is set in a 32-bit property register.
	@param Register number -- 32-bit property register.
	@return boolean -- True if anchored.
]=]
function ECSMain.IsEntityAnchored(Register: number): boolean
	return bit32.btest(Register, FLAG_ANCHORED)
end

--[=[
	Checks whether an entity has a bound dynamic OOP object ID in its register.
	@param Register number -- 32-bit property register.
	@return boolean -- True if a dynamic ID is present.
]=]
function ECSMain.HasEntityDynamicId(Register: number): boolean
	return bit32.btest(Register, FLAG_HAS_DYNAMIC_ID)
end

--[=[
	Extracts the 3-bit VerticeFile shape ID from a 32-bit property register.
	@param Register number -- Packed 32-bit property register.
	@return number -- Shape ID (0-7).
]=]
function ECSMain.GetEntityShapeId(Register: number): number
	return bit32.band(bit32.rshift(Register, SHAPE_ID_SHIFT), MAX_SHAPE_ID)
end

--[=[
	Updates an entity's 3-bit VerticeFile shape ID in-place inside the properties buffer without altering other flags.
	@param PropertiesBuffer buffer -- Properties buffer.
	@param EntityId number -- Target entity ID.
	@param ShapeId number -- New Shape ID (0-7).
]=]
function ECSMain.SetEntityShapeId(PropertiesBuffer: buffer, EntityId: number, ShapeId: number)
	const Offset = (EntityId - 1) * PROPERTIES_STRIDE :: number
	const CurrentRegister = buffer.readu32(PropertiesBuffer, Offset) :: number
	const BaseFlags = bit32.band(CurrentRegister, bit32.bnot(SHAPE_ID_MASK)) :: number
	const ClampedShapeId = math.clamp(math.floor(ShapeId), 0, MAX_SHAPE_ID) :: number
	buffer.writeu32(PropertiesBuffer, Offset, bit32.bor(BaseFlags, bit32.lshift(ClampedShapeId, SHAPE_ID_SHIFT)))
end

--[=[
	Extracts the bound dynamic OOP object ID from a 32-bit property register.
	@param Register number -- 32-bit property register.
	@return number -- Extracted dynamic ID (or 0 if none).
]=]
function ECSMain.GetEntityDynamicId(Register: number): number
	if not bit32.btest(Register, FLAG_HAS_DYNAMIC_ID) then
		return 0
	end

	return bit32.rshift(Register, DYNAMIC_ID_SHIFT)
end

--[=[
	Updates an entity's dynamic OOP ID in-place inside the properties buffer.
	@param PropertiesBuffer buffer -- Properties buffer.
	@param EntityId number -- Target entity ID.
	@param DynamicId number -- New dynamic OOP object ID (0 to clear).
]=]
function ECSMain.SetEntityDynamicId(PropertiesBuffer: buffer, EntityId: number, DynamicId: number)
	const Offset = (EntityId - 1) * PROPERTIES_STRIDE :: number
	const CurrentRegister = buffer.readu32(PropertiesBuffer, Offset) :: number
	const BaseFlags = bit32.band(CurrentRegister, LOWER_FLAGS_MASK) :: number

	if DynamicId <= 0 then
		buffer.writeu32(PropertiesBuffer, Offset, bit32.band(BaseFlags, bit32.bnot(FLAG_HAS_DYNAMIC_ID)))
		return
	end

	const ClampedId = math.min(DynamicId, MAX_DYNAMIC_ID) :: number
	const UpdatedRegister = bit32.bor(BaseFlags, FLAG_HAS_DYNAMIC_ID, bit32.lshift(ClampedId, DYNAMIC_ID_SHIFT)) :: number
	buffer.writeu32(PropertiesBuffer, Offset, UpdatedRegister)
end

--[=[
	Extracts the TextureTable ID (bits 5-12) from a 32-bit property register.
	@param Register number -- 32-bit property register.
	@return number -- Extracted texture ID (0-255).
]=]
function ECSMain.GetEntityTextureId(Register: number): number
	return bit32.band(bit32.rshift(Register, TEXTURE_ID_SHIFT), MAX_TEXTURE_ID)
end

--[=[
	Updates an entity's TextureTable ID in-place inside the properties buffer without altering other flags or DynamicId.
	@param PropertiesBuffer buffer -- Properties buffer.
	@param EntityId number -- Target entity ID.
	@param TextureId number -- New TextureTable ID (0-255).
]=]
function ECSMain.SetEntityTextureId(PropertiesBuffer: buffer, EntityId: number, TextureId: number)
	const Offset = (EntityId - 1) * PROPERTIES_STRIDE :: number
	const CurrentRegister = buffer.readu32(PropertiesBuffer, Offset) :: number
	const ClearedRegister = bit32.band(CurrentRegister, bit32.bnot(TEXTURE_ID_MASK)) :: number
	const ClampedTextureId = math.clamp(math.floor(TextureId), 0, MAX_TEXTURE_ID) :: number

	buffer.writeu32(PropertiesBuffer, Offset, bit32.bor(ClearedRegister, bit32.lshift(ClampedTextureId, TEXTURE_ID_SHIFT)))
end

-- ============================================================================
-- 2. ENTITY REGISTRATION & LIFECYCLE FUNCTIONS
-- ============================================================================

--[=[
	Registers a new entity slot across the synchronized ECS count table.
	@param Counts ECSTable -- Table tracking active component counts.
	@param StaticBuffer buffer? -- Optional static entity marker buffer.
	@param IsStatic boolean? -- True if entity is unmoving static geometry.
	@return number -- New unique EntityId.
]=]
function ECSMain.RegisterEntity(Counts: ECSTable, StaticBuffer: buffer?, IsStatic: boolean?): number
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
	@param Counts ECSTable -- Table tracking active component counts.
	@param EntityCount number -- Desired entity count.
]=]
function ECSMain.SetEntityCount(Counts: ECSTable, EntityCount: number)
	Counts.EntityECSCount = EntityCount
	Counts.OrientationECSCount = EntityCount
	Counts.PositionECSCount = EntityCount
	Counts.VisualECSCount = EntityCount
	Counts.SizeECSCount = EntityCount
	Counts.DirectionsECSCount = EntityCount
	Counts.PropertiesECSCount = EntityCount
end

--[=[
	Deletes an entity using O(1) swap-and-pop compaction to keep buffers contiguous.
	@param EntityId number -- Entity ID to remove.
	@param Counts ECSTable -- Component count table.
	@param PositionBuffer buffer -- World position buffer.
	@param OrientationBuffer buffer -- Orientation vector buffer.
	@param VisualBuffer buffer -- Visual color buffer.
	@param SizeBuffer buffer -- Part bounding size buffer.
	@param DirectionsBuffer buffer -- Basis unit vectors buffer.
	@param StaticBuffer buffer? -- Optional static marker buffer.
	@param PropertiesBuffer buffer? -- Optional bitpacked properties buffer.
]=]
function ECSMain.DeleteEntity(
	EntityId: number,
	Counts: ECSTable,
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

		const TargetVisualOffset = (EntityId - 1) * VISUAL_STRIDE :: number
		const LastVisualOffset = (LastEntityId - 1) * VISUAL_STRIDE :: number
		buffer.copy(VisualBuffer, TargetVisualOffset, VisualBuffer, LastVisualOffset, VISUAL_STRIDE)

		buffer.copy(SizeBuffer, TargetOffset, SizeBuffer, LastOffset, COMPONENT_STRIDE)

		const TargetDirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
		const LastDirOffset = (LastEntityId - 1) * DIRECTION_STRIDE :: number
		buffer.copy(DirectionsBuffer, TargetDirOffset, DirectionsBuffer, LastDirOffset, DIRECTION_STRIDE)

		if PropertiesBuffer then
			const TargetPropOffset = (EntityId - 1) * PROPERTIES_STRIDE :: number
			const LastPropOffset = (LastEntityId - 1) * PROPERTIES_STRIDE :: number
			buffer.writeu32(PropertiesBuffer, TargetPropOffset, buffer.readu32(PropertiesBuffer, LastPropOffset))
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

	const NewCount = LastEntityId - 1 :: number
	Counts.EntityECSCount = NewCount
	Counts.OrientationECSCount = NewCount
	Counts.PositionECSCount = NewCount
	Counts.VisualECSCount = NewCount
	Counts.SizeECSCount = NewCount
	Counts.DirectionsECSCount = NewCount
	Counts.PropertiesECSCount = NewCount
end

-- ============================================================================
-- 3. COMPONENT & UNIFIED STORAGE FACTORIES
-- ============================================================================

--[=[
	Creates an isolated Vector3 component storage buffer and accessor interface.
	@return Vector3Component -- Initialized Vector3 component interface.
]=]
function ECSMain.CreateVector3Component(): Vector3Component
	const ComponentBuffer = buffer.create(COMPONENT_BUFFER_SIZE) :: buffer
	local Component = {}

	function Component.CreateLayout(MemoryOffset: number, X: number, Y: number, Z: number): number
		return ECSMain.CreateVector3Layout(ComponentBuffer, MemoryOffset, X, Y, Z)
	end

	function Component.GetData(): buffer
		return ComponentBuffer
	end

	return Component
end

--[=[
	Creates an isolated Visual RGB component storage buffer and accessor interface.
	@return VisualComponent -- Initialized Visual component interface.
]=]
function ECSMain.CreateVisualComponent(): VisualComponent
	const VisualBuffer = buffer.create(VISUAL_BUFFER_SIZE) :: buffer
	local Component = {}

	function Component.CreateLayout(MemoryOffset: number, R: number, G: number, B: number, A: number?): number
		return ECSMain.CreateVisualLayout(VisualBuffer, MemoryOffset, R, G, B, A)
	end

	function Component.GetData(): buffer
		return VisualBuffer
	end

	return Component
end

--[=[
	Creates an isolated basis directions component buffer and accessor interface.
	@return DirectionsComponent -- Initialized directions component interface.
]=]
function ECSMain.CreateDirectionsComponent(): DirectionsComponent
	const DirectionsBuffer = buffer.create(DIRECTION_BUFFER_SIZE) :: buffer
	local Component = {}

	function Component.CreateLayout(
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
		return ECSMain.CreateDirectionsLayout(
			DirectionsBuffer,
			MemoryOffset,
			LookX,
			LookY,
			LookZ,
			UpX,
			UpY,
			UpZ,
			RightX,
			RightY,
			RightZ
		)
	end

	function Component.GetData(): buffer
		return DirectionsBuffer
	end

	return Component
end

--[=[
	Creates or writes into a bitpacked properties component buffer.
	@param TargetBuffer buffer? -- Optional target buffer (if writing directly).
	@param MemoryOffset number? -- Optional byte offset (if writing directly).
	@param CanCollide boolean? -- Collision flag.
	@param IsVisible boolean? -- Visibility flag.
	@param Anchored boolean? -- Anchored flag.
	@param DynamicId number? -- Dynamic OOP ID.
	@return any -- Returns component table if creating, or next offset if writing.
]=]
function ECSMain.CreatePropertiesComponent(
	TargetBuffer: buffer?,
	MemoryOffset: number?,
	CanCollide: boolean?,
	IsVisible: boolean?,
	Anchored: boolean?,
	DynamicId: number?,
	TextureId: number?,
	ShapeId: number?
): any
	if TargetBuffer and MemoryOffset then
		return ECSMain.CreatePropertiesLayout(
			TargetBuffer,
			MemoryOffset,
			CanCollide,
			IsVisible,
			Anchored,
			DynamicId,
			TextureId,
			ShapeId
		)
	end

	const PropertiesBuffer = buffer.create(PROPERTIES_BUFFER_SIZE) :: buffer
	local PropertiesComponent = {}

	function PropertiesComponent.CreateLayout(
		Offset: number,
		Collide: boolean?,
		Visible: boolean?,
		IsAnchored: boolean?,
		DynId: number?,
		TexId: number?,
		ShpId: number?
	): number
		return ECSMain.CreatePropertiesLayout(PropertiesBuffer, Offset, Collide, Visible, IsAnchored, DynId, TexId, ShpId)
	end

	function PropertiesComponent.GetData(): buffer
		return PropertiesBuffer
	end

	return PropertiesComponent
end

--[=[
	Creates a dynamic OOP objects table linked to entity property registers.
	@param PropertiesBuffer buffer -- The entity properties buffer to link IDs into.
	@return DynamicObjectsComponent -- Initialized dynamic objects registry.
]=]
function ECSMain.CreateDynamicObjectsComponent(PropertiesBuffer: buffer): DynamicObjectsComponent
	local ObjectsTable = {} :: { [number]: any }
	local FreeIds = {} :: { number }
	const EntityIdByDynamicId = buffer.create((MAX_DYNAMIC_ID + 1) * 4) :: buffer

	local Counts: DynamicListCounts = {
		ActiveCount = 0,
		NextId = 0,
	}

	local DynamicObjectsList = {}
	DynamicObjectsList.ObjectsTable = ObjectsTable
	DynamicObjectsList.Counts = Counts

	function DynamicObjectsList.AddObject(ObjectInstance: any, EntityId: number?): number
		local DynamicId = 0 :: number
		const FreeCount = (#FreeIds) :: number

		if FreeCount > 0 then
			DynamicId = FreeIds[FreeCount]
			FreeIds[FreeCount] = nil
		else
			const CandidateId = Counts.NextId + 1 :: number
			if CandidateId > MAX_DYNAMIC_ID then
				return 0
			end
			Counts.NextId = CandidateId
			DynamicId = CandidateId
		end

		ObjectsTable[DynamicId] = ObjectInstance
		Counts.ActiveCount += 1

		if EntityId and EntityId > 0 then
			buffer.writeu32(EntityIdByDynamicId, DynamicId * 4, EntityId)
			ECSMain.SetEntityDynamicId(PropertiesBuffer, EntityId, DynamicId)
		end

		return DynamicId
	end

	function DynamicObjectsList.SetObjectAtId(DynamicId: number, ObjectInstance: any, EntityId: number?): boolean
		if DynamicId <= 0 or DynamicId > MAX_DYNAMIC_ID or ObjectInstance == nil then
			return false
		end

		const FreeIndex = table.find(FreeIds, DynamicId)
		if FreeIndex then
			table.remove(FreeIds, FreeIndex)
		end

		if ObjectsTable[DynamicId] == nil then
			Counts.ActiveCount += 1
		end
		if DynamicId > Counts.NextId then
			Counts.NextId = DynamicId
		end

		ObjectsTable[DynamicId] = ObjectInstance

		if EntityId and EntityId > 0 then
			buffer.writeu32(EntityIdByDynamicId, DynamicId * 4, EntityId)
			ECSMain.SetEntityDynamicId(PropertiesBuffer, EntityId, DynamicId)
		end

		return true
	end

	function DynamicObjectsList.GetObject(DynamicId: number): any
		if DynamicId <= 0 or DynamicId > MAX_DYNAMIC_ID then
			return nil
		end

		return ObjectsTable[DynamicId]
	end

	function DynamicObjectsList.GetObjectFromRegister(Register: number): any
		const DynamicId = ECSMain.GetEntityDynamicId(Register) :: number
		if DynamicId <= 0 then
			return nil
		end

		return ObjectsTable[DynamicId]
	end

	function DynamicObjectsList.GetObjectByEntityId(EntityId: number): any
		if EntityId < 1 then
			return nil
		end

		const Register = buffer.readu32(PropertiesBuffer, (EntityId - 1) * PROPERTIES_STRIDE) :: number
		const DynamicId = ECSMain.GetEntityDynamicId(Register) :: number
		if DynamicId <= 0 then
			return nil
		end

		return ObjectsTable[DynamicId]
	end

	function DynamicObjectsList.BindEntity(DynamicId: number, EntityId: number)
		if DynamicId <= 0 or DynamicId > MAX_DYNAMIC_ID or EntityId < 1 then
			return
		end

		buffer.writeu32(EntityIdByDynamicId, DynamicId * 4, EntityId)
		ECSMain.SetEntityDynamicId(PropertiesBuffer, EntityId, DynamicId)
	end

	function DynamicObjectsList.GetBoundEntityId(DynamicId: number): number
		if DynamicId <= 0 or DynamicId > MAX_DYNAMIC_ID then
			return 0
		end

		return buffer.readu32(EntityIdByDynamicId, DynamicId * 4)
	end

	function DynamicObjectsList.RemoveObject(DynamicId: number)
		if DynamicId <= 0 or DynamicId > MAX_DYNAMIC_ID then
			return
		end

		if ObjectsTable[DynamicId] == nil then
			return
		end

		const BoundEntityId = buffer.readu32(EntityIdByDynamicId, DynamicId * 4) :: number
		if BoundEntityId > 0 then
			buffer.writeu32(EntityIdByDynamicId, DynamicId * 4, 0)
			const BoundOffset = (BoundEntityId - 1) * PROPERTIES_STRIDE :: number
			if BoundOffset + PROPERTIES_STRIDE <= buffer.len(PropertiesBuffer) then
				const BoundRegister = buffer.readu32(PropertiesBuffer, BoundOffset) :: number
				if ECSMain.GetEntityDynamicId(BoundRegister) == DynamicId then
					ECSMain.SetEntityDynamicId(PropertiesBuffer, BoundEntityId, 0)
				end
			end
		end

		ObjectsTable[DynamicId] = nil
		Counts.ActiveCount = math.max(0, Counts.ActiveCount - 1)
		table.insert(FreeIds, DynamicId)
	end

	function DynamicObjectsList.GetData(): { [number]: any }
		return ObjectsTable
	end

	return DynamicObjectsList
end

--[=[
	Constructs a complete, unified ECS storage container with all component buffers.
	@param IncludeStaticBuffer boolean? -- Whether to allocate a static geometry marker buffer.
	@return ECSStorage -- Fully initialized ECS storage structure.
]=]
function ECSMain.CreateStorage(IncludeStaticBuffer: boolean?): ECSStorage
	const PositionData = ECSMain.CreateVector3Component()
	const VisualData = ECSMain.CreateVisualComponent()
	const SizeData = ECSMain.CreateVector3Component()
	const DirectionsData = ECSMain.CreateDirectionsComponent()
	const PropertiesData = ECSMain.CreatePropertiesComponent() :: PropertiesComponent

	const PositionBuffer = PositionData.GetData() :: buffer
	const VisualBuffer = VisualData.GetData() :: buffer
	const SizeBuffer = SizeData.GetData() :: buffer
	const DirectionsBuffer = DirectionsData.GetData() :: buffer
	const PropertiesBuffer = PropertiesData.GetData() :: buffer
	const StaticBuffer = if IncludeStaticBuffer then buffer.create(MAX_ENTITIES) else nil :: buffer?
	const DirtyFlags = buffer.create(MAX_ENTITIES) :: buffer
	const VersionBuffer = buffer.create(MAX_ENTITIES * 4) :: buffer
	const SwapPopCallbacks = {} :: { (DeletedEntityId: number, MovedFromEntityId: number) -> () }

	-- Legacy shim: alias OrientationData onto DirectionsBuffer (LookVector bytes 0..11) at 0 extra memory cost
	const OrientationData: Vector3Component = {
		CreateLayout = function(MemoryOffset: number, X: number, Y: number, Z: number): number
			const EntityIdx = MemoryOffset // COMPONENT_STRIDE :: number
			const DirOffset = EntityIdx * DIRECTION_STRIDE :: number
			buffer.writef32(DirectionsBuffer, DirOffset, X)
			buffer.writef32(DirectionsBuffer, DirOffset + 4, Y)
			buffer.writef32(DirectionsBuffer, DirOffset + 8, Z)
			return MemoryOffset + COMPONENT_STRIDE
		end,
		GetData = function(): buffer
			return DirectionsBuffer
		end,
	}

	const ECSDataTable: ECSTable = {
		OrientationECSCount = 0,
		PositionECSCount = 0,
		VisualECSCount = 0,
		SizeECSCount = 0,
		DirectionsECSCount = 0,
		PropertiesECSCount = 0,
		EntityECSCount = 0,
	}

	const DynamicObjectsList = ECSMain.CreateDynamicObjectsComponent(PropertiesBuffer)

	local ECSData = {}
	ECSData.ECSDataTable = ECSDataTable

	function ECSData.GetCounts(): ECSTable
		return ECSDataTable
	end

	function ECSData.GetStaticData(): buffer
		return StaticBuffer :: buffer
	end

	function ECSData.GetDirtyFlags(): buffer
		return DirtyFlags
	end

	function ECSData.GetVersionBuffer(): buffer
		return VersionBuffer
	end

	function ECSData.MarkDirty(EntityId: number)
		if EntityId < 1 or EntityId > MAX_ENTITIES then
			return
		end
		buffer.writeu8(DirtyFlags, EntityId - 1, 1)
		const VersionOffset = (EntityId - 1) * 4 :: number
		buffer.writeu32(VersionBuffer, VersionOffset, buffer.readu32(VersionBuffer, VersionOffset) + 1)
	end

	function ECSData.ClearDirty(EntityId: number)
		if EntityId < 1 or EntityId > MAX_ENTITIES then
			return
		end
		buffer.writeu8(DirtyFlags, EntityId - 1, 0)
	end

	function ECSData.SetSwapPopCallback(Callback: ((DeletedEntityId: number, MovedFromEntityId: number) -> ())?)
		if not Callback then
			table.clear(SwapPopCallbacks)
			return
		end
		if not table.find(SwapPopCallbacks, Callback) then
			table.insert(SwapPopCallbacks, Callback)
		end
	end

	function ECSData.RegisterEntity(IsStatic: boolean?): number
		const NewId = ECSMain.RegisterEntity(ECSDataTable, StaticBuffer, IsStatic) :: number
		if NewId > 0 then
			ECSData.MarkDirty(NewId)
		end
		return NewId
	end

	function ECSData.SetEntityCount(EntityCount: number)
		ECSMain.SetEntityCount(ECSDataTable, EntityCount)
	end

	function ECSData.DeleteEntity(EntityId: number)
		const LastEntityId = ECSDataTable.EntityECSCount :: number
		if EntityId < 1 or EntityId > LastEntityId then
			return
		end

		const DeletedProp = buffer.readu32(PropertiesBuffer, (EntityId - 1) * PROPERTIES_STRIDE) :: number
		const DeletedDynId = ECSMain.GetEntityDynamicId(DeletedProp) :: number
		if DeletedDynId > 0 then
			DynamicObjectsList.RemoveObject(DeletedDynId)
		end

		ECSMain.DeleteEntity(
			EntityId,
			ECSDataTable,
			PositionBuffer,
			nil,
			VisualBuffer,
			SizeBuffer,
			DirectionsBuffer,
			StaticBuffer,
			PropertiesBuffer
		)

		if EntityId ~= LastEntityId then
			const MovedProp = buffer.readu32(PropertiesBuffer, (EntityId - 1) * PROPERTIES_STRIDE) :: number
			const MovedDynId = ECSMain.GetEntityDynamicId(MovedProp) :: number
			if MovedDynId > 0 then
				DynamicObjectsList.BindEntity(MovedDynId, EntityId)
			end
			ECSData.MarkDirty(EntityId)
		end

		buffer.writeu8(DirtyFlags, LastEntityId - 1, 0)
		buffer.writeu32(VersionBuffer, (LastEntityId - 1) * 4, 0)

		for _, Callback in SwapPopCallbacks do
			Callback(EntityId, LastEntityId)
		end
	end

	return {
		PositionData = PositionData,
		OrientationData = OrientationData,
		VisualData = VisualData,
		SizeData = SizeData,
		DirectionsData = DirectionsData,
		PropertiesData = PropertiesData,
		ECSData = ECSData,
		DynamicObjectsList = DynamicObjectsList,
	}
end

return ECSMain
