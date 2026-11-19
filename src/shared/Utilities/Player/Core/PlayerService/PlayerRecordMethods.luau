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
	if
		PosX ~= PosX
		or PosY ~= PosY
		or PosZ ~= PosZ
		or math.abs(PosX) > 1e6
		or math.abs(PosY) > 1e6
		or math.abs(PosZ) > 1e6
	then
		return
	end

	const UnitLookX, UnitLookZ = PlayerServiceHelper.NormalizeHorizontalLook(LookX, LookZ, self.LookX, self.LookZ)
	self.PositionX = PosX
	self.PositionY = PosY
	self.PositionZ = PosZ
	self.LookX = UnitLookX
	self.LookY = 0
	self.LookZ = UnitLookZ

	local EntityId = self.EntityId :: number
	if self.DynamicId > 0 then
		const BoundId = Storage.DynamicObjectsList.GetBoundEntityId(self.DynamicId) :: number
		if BoundId > 0 then
			EntityId = BoundId
			self.EntityId = BoundId
		end
	end
	if not self.Active or EntityId < 1 or not Storage.ECSData.IsEntityActive(EntityId) then
		return
	end

	const PropBuffer = Storage.PropertiesData.GetData() :: buffer
	const PropOffset = (EntityId - 1) * PROPERTIES_STRIDE :: number
	if PropOffset + PROPERTIES_STRIDE > buffer.len(PropBuffer) then
		return
	end
	if self.DynamicId > 0 and ECSMain.GetEntityDynamicId(buffer.readu32(PropBuffer, PropOffset)) ~= self.DynamicId then
		return
	end

	const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
	const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
	const PositionBuffer = Storage.PositionData.GetData() :: buffer
	const DirectionsBuffer = Storage.DirectionsData.GetData() :: buffer
	if CompOffset + COMPONENT_STRIDE > buffer.len(PositionBuffer) or DirOffset + DIRECTION_STRIDE > buffer.len(DirectionsBuffer) then
		return
	end

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
