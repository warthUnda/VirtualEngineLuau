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

-- Tables --
local ECSBitfield = {}

-- Functions --
-- ============================================================================
-- 1. BUFFER LAYOUT WRITERS & 32-BIT PROPERTY BITFIELD CODEC
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
function ECSBitfield.CreateVector3Layout(TargetBuffer: buffer, MemoryOffset: number, X: number, Y: number, Z: number): number
	buffer.writef32(TargetBuffer, MemoryOffset, X)
	buffer.writef32(TargetBuffer, MemoryOffset + 4, Y)
	buffer.writef32(TargetBuffer, MemoryOffset + 8, Z)
	return MemoryOffset + COMPONENT_STRIDE
end

--[=[
	Writes 8-bit RGBA color channels into a visual component buffer.
	@param TargetBuffer buffer -- Target visual component buffer.
	@param MemoryOffset number -- Byte offset in buffer.
	@param R number -- Red color channel (0-255).
	@param G number -- Green color channel (0-255).
	@param B number -- Blue color channel (0-255).
	@param A number? -- Optional alpha channel (defaults to 255).
	@return number -- Next component byte offset.
]=]
function ECSBitfield.CreateVisualLayout(TargetBuffer: buffer, MemoryOffset: number, R: number, G: number, B: number, A: number?): number
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
function ECSBitfield.CreateDirectionsLayout(
	TargetBuffer: buffer, MemoryOffset: number,
	LookX: number, LookY: number, LookZ: number,
	UpX: number, UpY: number, UpZ: number,
	RightX: number, RightY: number, RightZ: number
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
	Packs boolean flags, texture ID, shape ID, and dynamic object ID into a 32-bit property register.
	@param CanCollide boolean? -- Collision enabled flag.
	@param IsVisible boolean? -- Visibility flag.
	@param Anchored boolean? -- Anchored physics state flag.
	@param DynamicId number? -- Bound dynamic OOP object ID (bits 22-31, 0-1023).
	@param TextureId number? -- TextureTable ID (bits 5-12, 0-255).
	@param ShapeId number? -- VerticeFile shape ID (bits 13-15, 0-7).
	@return number -- Packed 32-bit register.
]=]
function ECSBitfield.PackProperties(
	CanCollide: boolean?, IsVisible: boolean?, Anchored: boolean?,
	DynamicId: number?, TextureId: number?, ShapeId: number?
): number
	const CollideBit = if CanCollide ~= false then 1 else 0 :: number
	const VisibleBit = if IsVisible ~= false then 1 else 0 :: number
	const AnchoredBit = if Anchored ~= false then 1 else 0 :: number
	const ClampedDynamicId = if DynamicId and DynamicId > 0 then math.min(DynamicId, MAX_DYNAMIC_ID) else 0 :: number
	const HasDynamicBit = if ClampedDynamicId > 0 then 1 else 0 :: number
	const ClampedTextureId = if TextureId and TextureId > 0 then math.clamp(math.floor(TextureId), 0, MAX_TEXTURE_ID) else 0 :: number
	const ClampedShapeId = if ShapeId and ShapeId > 0 then math.clamp(math.floor(ShapeId), 0, MAX_SHAPE_ID) else 0 :: number

	return bit32.bor(
		bit32.lshift(CollideBit, 1),
		bit32.lshift(VisibleBit, 2),
		bit32.lshift(AnchoredBit, 3),
		bit32.lshift(HasDynamicBit, 4),
		bit32.lshift(ClampedTextureId, TEXTURE_ID_SHIFT),
		bit32.lshift(ClampedShapeId, SHAPE_ID_SHIFT),
		bit32.lshift(ClampedDynamicId, DYNAMIC_ID_SHIFT)
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
function ECSBitfield.CreatePropertiesLayout(
	TargetBuffer: buffer, MemoryOffset: number,
	CanCollide: boolean?, IsVisible: boolean?, Anchored: boolean?,
	DynamicId: number?, TextureId: number?, ShapeId: number?
): number
	buffer.writeu32(TargetBuffer, MemoryOffset, ECSBitfield.PackProperties(CanCollide, IsVisible, Anchored, DynamicId, TextureId, ShapeId))
	return MemoryOffset + PROPERTIES_STRIDE
end

function ECSBitfield.CanEntityCollide(Register: number): boolean
	return bit32.btest(Register, FLAG_CAN_COLLIDE)
end

function ECSBitfield.IsEntityVisible(Register: number): boolean
	return bit32.btest(Register, FLAG_IS_VISIBLE)
end

function ECSBitfield.IsEntityAnchored(Register: number): boolean
	return bit32.btest(Register, FLAG_ANCHORED)
end

function ECSBitfield.HasEntityDynamicId(Register: number): boolean
	return bit32.btest(Register, FLAG_HAS_DYNAMIC_ID)
end

function ECSBitfield.GetEntityShapeId(Register: number): number
	return bit32.band(bit32.rshift(Register, SHAPE_ID_SHIFT), MAX_SHAPE_ID)
end

function ECSBitfield.SetEntityShapeId(PropertiesBuffer: buffer, EntityId: number, ShapeId: number)
	if EntityId ~= EntityId or EntityId < 1 or EntityId % 1 ~= 0 then
		return
	end
	const Offset = (EntityId - 1) * PROPERTIES_STRIDE :: number
	if Offset + PROPERTIES_STRIDE > buffer.len(PropertiesBuffer) then
		return
	end
	const BaseFlags = bit32.band(buffer.readu32(PropertiesBuffer, Offset), bit32.bnot(SHAPE_ID_MASK)) :: number
	const SafeShape = if ShapeId == ShapeId then math.clamp(math.floor(ShapeId), 0, MAX_SHAPE_ID) else 0 :: number
	buffer.writeu32(PropertiesBuffer, Offset, bit32.bor(BaseFlags, bit32.lshift(SafeShape, SHAPE_ID_SHIFT)))
end

function ECSBitfield.GetEntityDynamicId(Register: number): number
	if not bit32.btest(Register, FLAG_HAS_DYNAMIC_ID) then
		return 0
	end
	return bit32.rshift(Register, DYNAMIC_ID_SHIFT)
end

function ECSBitfield.SetEntityDynamicId(PropertiesBuffer: buffer, EntityId: number, DynamicId: number)
	if EntityId ~= EntityId or EntityId < 1 or EntityId % 1 ~= 0 then
		return
	end
	const Offset = (EntityId - 1) * PROPERTIES_STRIDE :: number
	if Offset + PROPERTIES_STRIDE > buffer.len(PropertiesBuffer) then
		return
	end
	const BaseFlags = bit32.band(buffer.readu32(PropertiesBuffer, Offset), LOWER_FLAGS_MASK) :: number
	if DynamicId ~= DynamicId or DynamicId <= 0 then
		buffer.writeu32(PropertiesBuffer, Offset, bit32.band(BaseFlags, bit32.bnot(FLAG_HAS_DYNAMIC_ID)))
		return
	end
	const ClampedId = math.clamp(math.floor(DynamicId), 1, MAX_DYNAMIC_ID) :: number
	buffer.writeu32(PropertiesBuffer, Offset, bit32.bor(BaseFlags, FLAG_HAS_DYNAMIC_ID, bit32.lshift(ClampedId, DYNAMIC_ID_SHIFT)))
end

function ECSBitfield.GetEntityTextureId(Register: number): number
	return bit32.band(bit32.rshift(Register, TEXTURE_ID_SHIFT), MAX_TEXTURE_ID)
end

function ECSBitfield.SetEntityTextureId(PropertiesBuffer: buffer, EntityId: number, TextureId: number)
	if EntityId ~= EntityId or EntityId < 1 or EntityId % 1 ~= 0 then
		return
	end
	const Offset = (EntityId - 1) * PROPERTIES_STRIDE :: number
	if Offset + PROPERTIES_STRIDE > buffer.len(PropertiesBuffer) then
		return
	end
	const ClearedRegister = bit32.band(buffer.readu32(PropertiesBuffer, Offset), bit32.bnot(TEXTURE_ID_MASK)) :: number
	const SafeTex = if TextureId == TextureId then math.clamp(math.floor(TextureId), 0, MAX_TEXTURE_ID) else 0 :: number
	buffer.writeu32(PropertiesBuffer, Offset, bit32.bor(ClearedRegister, bit32.lshift(SafeTex, TEXTURE_ID_SHIFT)))
end

return ECSBitfield
