--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
const PlayerServiceHelper = require(script.Parent.PlayerServiceHelper)

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const PLAYER_RENDER_SIZE = SystemsConfigs.PlayerRenderSize :: Vector3
const PLAYER_SIZE_X = PLAYER_RENDER_SIZE.X :: number
const PLAYER_SIZE_Y = PLAYER_RENDER_SIZE.Y :: number
const PLAYER_SIZE_Z = PLAYER_RENDER_SIZE.Z :: number
const DEFAULT_CAN_COLLIDE = SystemsConfigs.PlayerCanCollide :: boolean
const FLAG_CAN_COLLIDE = bit32.lshift(1, 1) :: number
const FLAG_IS_VISIBLE = bit32.lshift(1, 2) :: number
const VISIBILITY_COLLISION_MASK = bit32.bor(FLAG_CAN_COLLIDE, FLAG_IS_VISIBLE) :: number

-- Tables --
local PlayerRecordMethods = {}

-- Functions --
-- ============================================================================
-- 1. ECS BUFFER POPULATION & DYNAMIC OBJECTS OOP LINKER METHODS
-- ============================================================================

--[=[
	Registers a renderable dynamic ECS entity for this player and links this OOP instance into DynamicObjectsList.
]=]
function PlayerRecordMethods.BindToStorage(
	self: any,
	Storage: ECSMain.ECSStorage,
	CanCollideOverride: boolean?,
	IsVisibleOverride: boolean?
): (number, number)
	if self.EntityId > 0 and self.DynamicId > 0 then
		return self.EntityId, self.DynamicId
	end

	const EntityId = Storage.ECSData.RegisterEntity(false) :: number
	if EntityId <= 0 then
		return 0, 0
	end

	const DynamicId = Storage.DynamicObjectsList.AddObject(self, EntityId) :: number
	if DynamicId <= 0 then
		Storage.ECSData.DeleteEntity(EntityId)
		return 0, 0
	end

	const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
	const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
	const VisOffset = (EntityId - 1) * VISUAL_STRIDE :: number
	const PropOffset = (EntityId - 1) * PROPERTIES_STRIDE :: number

	const LookX, LookZ = PlayerServiceHelper.NormalizeHorizontalLook(self.LookX, self.LookZ, 0, -1)
	const CanCollide = if CanCollideOverride ~= nil then CanCollideOverride else DEFAULT_CAN_COLLIDE
	const IsVisible = if IsVisibleOverride ~= nil then IsVisibleOverride else true
	const ShapeId = PlayerServiceHelper.ResolvePlayerShapeId()

	Storage.PositionData.CreateLayout(CompOffset, self.PositionX, self.PositionY, self.PositionZ)
	Storage.SizeData.CreateLayout(CompOffset, PLAYER_SIZE_X, PLAYER_SIZE_Y, PLAYER_SIZE_Z)
	Storage.DirectionsData.CreateLayout(DirOffset, LookX, 0, LookZ, 0, 1, 0, -LookZ, 0, LookX)
	Storage.VisualData.CreateLayout(VisOffset, self.ColorR, self.ColorG, self.ColorB)
	Storage.PropertiesData.CreateLayout(PropOffset, CanCollide, IsVisible, true, DynamicId, 0, ShapeId)

	self.LookX = LookX
	self.LookY = 0
	self.LookZ = LookZ
	self.EntityId = EntityId
	self.DynamicId = DynamicId
	self.Active = true

	Storage.ECSData.MarkDirty(EntityId)
	return EntityId, DynamicId
end

--[=[
	Binds this client OOP record into DynamicObjectsList at an explicit server-assigned DynamicId.
]=]
function PlayerRecordMethods.BindClientDynamicId(
	self: any,
	Storage: ECSMain.ECSStorage,
	DynamicId: number,
	EntityId: number?
): boolean
	if not Storage.DynamicObjectsList.SetObjectAtId(DynamicId, self, EntityId) then
		return false
	end
	self.DynamicId = DynamicId
	self.EntityId = if EntityId and EntityId > 0 then EntityId else 0
	self.Active = true
	return true
end

--[=[
	Updates the player's world position and horizontal facing basis in-place inside ECS buffers with zero allocations.
]=]
function PlayerRecordMethods.UpdateTransform(
	self: any,
	Storage: ECSMain.ECSStorage,
	PosX: number,
	PosY: number,
	PosZ: number,
	LookX: number,
	LookZ: number
)
	const UnitLookX, UnitLookZ = PlayerServiceHelper.NormalizeHorizontalLook(LookX, LookZ, self.LookX, self.LookZ)
	self.PositionX = PosX
	self.PositionY = PosY
	self.PositionZ = PosZ
	self.LookX = UnitLookX
	self.LookY = 0
	self.LookZ = UnitLookZ

	const EntityId = self.EntityId :: number
	if EntityId < 1 or EntityId > Storage.ECSData.GetCounts().EntityECSCount then
		return
	end

	const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
	const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
	const PositionBuffer = Storage.PositionData.GetData() :: buffer
	const DirectionsBuffer = Storage.DirectionsData.GetData() :: buffer

	buffer.writef32(PositionBuffer, CompOffset, PosX)
	buffer.writef32(PositionBuffer, CompOffset + 4, PosY)
	buffer.writef32(PositionBuffer, CompOffset + 8, PosZ)

	buffer.writef32(DirectionsBuffer, DirOffset, UnitLookX)
	buffer.writef32(DirectionsBuffer, DirOffset + 4, 0)
	buffer.writef32(DirectionsBuffer, DirOffset + 8, UnitLookZ)
	buffer.writef32(DirectionsBuffer, DirOffset + 12, 0)
	buffer.writef32(DirectionsBuffer, DirOffset + 16, 1)
	buffer.writef32(DirectionsBuffer, DirOffset + 20, 0)
	buffer.writef32(DirectionsBuffer, DirOffset + 24, -UnitLookZ)
	buffer.writef32(DirectionsBuffer, DirOffset + 28, 0)
	buffer.writef32(DirectionsBuffer, DirOffset + 32, UnitLookX)

	Storage.ECSData.MarkDirty(EntityId)
end

--[=[
	Updates IsVisible and CanCollide flags in-place on the bound ECS entity without altering other bitfields.
]=]
function PlayerRecordMethods.SetLocalVisibilityAndCollision(
	self: any,
	Storage: ECSMain.ECSStorage,
	IsVisible: boolean,
	CanCollide: boolean
)
	const EntityId = self.EntityId :: number
	if EntityId < 1 or EntityId > Storage.ECSData.GetCounts().EntityECSCount then
		return
	end

	const PropOffset = (EntityId - 1) * PROPERTIES_STRIDE :: number
	const PropertiesBuffer = Storage.PropertiesData.GetData() :: buffer
	const CurrentReg = buffer.readu32(PropertiesBuffer, PropOffset) :: number
	local NextReg = bit32.band(CurrentReg, bit32.bnot(VISIBILITY_COLLISION_MASK)) :: number
	if CanCollide then
		NextReg = bit32.bor(NextReg, FLAG_CAN_COLLIDE)
	end
	if IsVisible then
		NextReg = bit32.bor(NextReg, FLAG_IS_VISIBLE)
	end
	if NextReg ~= CurrentReg then
		buffer.writeu32(PropertiesBuffer, PropOffset, NextReg)
		Storage.ECSData.MarkDirty(EntityId)
	end
end

--[=[
	Updates the player's rendered RGB color in VisualData and marks the entity dirty.
]=]
function PlayerRecordMethods.SetColor(self: any, Storage: ECSMain.ECSStorage, Color: Color3)
	const R = math.clamp(math.floor(Color.R * 255 + 0.5), 0, 255) :: number
	const G = math.clamp(math.floor(Color.G * 255 + 0.5), 0, 255) :: number
	const B = math.clamp(math.floor(Color.B * 255 + 0.5), 0, 255) :: number
	self.ColorR = R
	self.ColorG = G
	self.ColorB = B

	const EntityId = self.EntityId :: number
	if EntityId < 1 or EntityId > Storage.ECSData.GetCounts().EntityECSCount then
		return
	end
	Storage.VisualData.CreateLayout((EntityId - 1) * VISUAL_STRIDE, R, G, B)
	Storage.ECSData.MarkDirty(EntityId)
end

function PlayerRecordMethods.GetPosition(self: any): Vector3
	return Vector3.new(self.PositionX, self.PositionY, self.PositionZ)
end

function PlayerRecordMethods.GetLookVector(self: any): Vector3
	return Vector3.new(self.LookX, self.LookY, self.LookZ)
end

--[=[
	Unbinds this player from DynamicObjectsList and deletes its ECS entity slot via O(1) swap-and-pop.
]=]
function PlayerRecordMethods.UnbindFromStorage(self: any, Storage: ECSMain.ECSStorage)
	self.Active = false
	const CurrentEntityId = self.EntityId :: number
	const CurrentDynamicId = self.DynamicId :: number
	self.EntityId = 0
	self.DynamicId = 0

	if CurrentEntityId > 0 and CurrentEntityId <= Storage.ECSData.GetCounts().EntityECSCount then
		Storage.ECSData.DeleteEntity(CurrentEntityId)
	elseif CurrentDynamicId > 0 then
		Storage.DynamicObjectsList.RemoveObject(CurrentDynamicId)
	end
end

return PlayerRecordMethods
