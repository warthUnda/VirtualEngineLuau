--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

-- Modules --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
const PlayerServiceHelper = require(script.PlayerServiceHelper)

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
const DEFAULT_SPAWN = SystemsConfigs.PlayerDefaultSpawnPosition :: Vector3

const FLAG_CAN_COLLIDE = bit32.lshift(1, 1) :: number
const FLAG_IS_VISIBLE = bit32.lshift(1, 2) :: number
const VISIBILITY_COLLISION_MASK = bit32.bor(FLAG_CAN_COLLIDE, FLAG_IS_VISIBLE) :: number

export type PlayerRecord = {
	ClassName: string,
	Player: Player?,
	UserId: number,
	Name: string,
	EntityId: number,
	DynamicId: number,
	PositionX: number,
	PositionY: number,
	PositionZ: number,
	LookX: number,
	LookY: number,
	LookZ: number,
	ColorR: number,
	ColorG: number,
	ColorB: number,
	Active: boolean,
	BindToStorage: (
		self: PlayerRecord,
		Storage: ECSMain.ECSStorage,
		CanCollideOverride: boolean?,
		IsVisibleOverride: boolean?
	) -> (number, number),
	BindClientDynamicId: (
		self: PlayerRecord,
		Storage: ECSMain.ECSStorage,
		DynamicId: number,
		EntityId: number?
	) -> boolean,
	UpdateTransform: (
		self: PlayerRecord,
		Storage: ECSMain.ECSStorage,
		PosX: number,
		PosY: number,
		PosZ: number,
		LookX: number,
		LookZ: number
	) -> (),
	SetLocalVisibilityAndCollision: (
		self: PlayerRecord,
		Storage: ECSMain.ECSStorage,
		IsVisible: boolean,
		CanCollide: boolean
	) -> (),
	SetColor: (self: PlayerRecord, Storage: ECSMain.ECSStorage, Color: Color3) -> (),
	GetPosition: (self: PlayerRecord) -> Vector3,
	GetLookVector: (self: PlayerRecord) -> Vector3,
	UnbindFromStorage: (self: PlayerRecord, Storage: ECSMain.ECSStorage) -> (),
}

-- Tables --
local PlayerService = {}
PlayerService.__index = PlayerService

-- ============================================================================
-- 1. PLAYER OOP CONSTRUCTORS
-- ============================================================================

--[=[
	Creates a new PlayerService OOP wrapper for the specified Player instance.
	@param PlayerInstance Player -- Target player instance.
	@return PlayerRecord -- Initialized OOP player record ready for ECS & DynamicObjectsList binding.
]=]
function PlayerService.New(PlayerInstance: Player): PlayerRecord
	const UserId, PlayerName, PosX, PosY, PosZ, LookX, LookZ, ColorR, ColorG, ColorB =
		PlayerServiceHelper.ExtractInitialSeed(PlayerInstance)

	const RawRecord = {
		ClassName = "PlayerService",
		Player = PlayerInstance,
		UserId = UserId,
		Name = PlayerName,
		EntityId = 0,
		DynamicId = 0,
		PositionX = PosX,
		PositionY = PosY,
		PositionZ = PosZ,
		LookX = LookX,
		LookY = 0,
		LookZ = LookZ,
		ColorR = ColorR,
		ColorG = ColorG,
		ColorB = ColorB,
		Active = true,
	}

	return (setmetatable(RawRecord, PlayerService) :: any) :: PlayerRecord
end

--[=[
	Creates a lightweight client-side PlayerService OOP wrapper from replicated registry metadata.
	@param UserId number -- Replicated Roblox UserId.
	@param PlayerName string -- Replicated player display/account name.
	@param ColorR number -- Visual red channel (0-255).
	@param ColorG number -- Visual green channel (0-255).
	@param ColorB number -- Visual blue channel (0-255).
	@param PlayerInstance Player? -- Optional resolved client Player reference.
	@return PlayerRecord -- Initialized OOP player record.
]=]
function PlayerService.FromRegistryEntry(
	UserId: number,
	PlayerName: string,
	ColorR: number,
	ColorG: number,
	ColorB: number,
	PlayerInstance: Player?
): PlayerRecord
	const RawRecord = {
		ClassName = "PlayerService",
		Player = PlayerInstance,
		UserId = UserId,
		Name = PlayerName,
		EntityId = 0,
		DynamicId = 0,
		PositionX = DEFAULT_SPAWN.X,
		PositionY = DEFAULT_SPAWN.Y,
		PositionZ = DEFAULT_SPAWN.Z,
		LookX = 0,
		LookY = 0,
		LookZ = -1,
		ColorR = math.clamp(math.floor(ColorR), 0, 255),
		ColorG = math.clamp(math.floor(ColorG), 0, 255),
		ColorB = math.clamp(math.floor(ColorB), 0, 255),
		Active = true,
	}

	return (setmetatable(RawRecord, PlayerService) :: any) :: PlayerRecord
end

-- ============================================================================
-- 2. ECS BUFFER POPULATION & DYNAMIC OBJECTS OOP LINKER METHODS
-- ============================================================================

--[=[
	Registers a renderable dynamic ECS entity for this player and links this OOP instance into DynamicObjectsList.
	@param Storage ECSMain.ECSStorage -- Target ECS storage container.
	@param CanCollideOverride boolean? -- Optional collision flag override (defaults to PlayerCanCollide).
	@param IsVisibleOverride boolean? -- Optional visibility flag override (defaults to true).
	@return (number, number) -- Allocated (EntityId, DynamicId), or (0, 0) if capacity is full.
]=]
function PlayerService.BindToStorage(
	self: PlayerRecord,
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
	-- Orthonormal horizontal basis: Look = (LookX, 0, LookZ), Up = (0, 1, 0), Right = Look x Up = (-LookZ, 0, LookX)
	const RightX = -LookZ :: number
	const RightZ = LookX :: number

	const CanCollide = if CanCollideOverride ~= nil then CanCollideOverride else DEFAULT_CAN_COLLIDE
	const IsVisible = if IsVisibleOverride ~= nil then IsVisibleOverride else true
	const ShapeId = PlayerServiceHelper.ResolvePlayerShapeId()

	Storage.PositionData.CreateLayout(CompOffset, self.PositionX, self.PositionY, self.PositionZ)
	Storage.SizeData.CreateLayout(CompOffset, PLAYER_SIZE_X, PLAYER_SIZE_Y, PLAYER_SIZE_Z)
	Storage.DirectionsData.CreateLayout(DirOffset, LookX, 0, LookZ, 0, 1, 0, RightX, 0, RightZ)
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
	@param Storage ECSMain.ECSStorage -- Client ECS storage container.
	@param DynamicId number -- Server-replicated DynamicObjectsList ID.
	@param EntityId number? -- Optional resolved client ECS slot ID.
	@return boolean -- True if linked successfully.
]=]
function PlayerService.BindClientDynamicId(
	self: PlayerRecord,
	Storage: ECSMain.ECSStorage,
	DynamicId: number,
	EntityId: number?
): boolean
	const BoundOk = Storage.DynamicObjectsList.SetObjectAtId(DynamicId, self, EntityId)
	if not BoundOk then
		return false
	end

	self.DynamicId = DynamicId
	self.EntityId = if EntityId and EntityId > 0 then EntityId else 0
	self.Active = true
	return true
end

--[=[
	Updates the player's world position and horizontal facing basis in-place inside ECS buffers with zero allocations.
	@param Storage ECSMain.ECSStorage -- Target ECS storage container.
	@param PosX number -- World center X.
	@param PosY number -- World center Y.
	@param PosZ number -- World center Z.
	@param LookX number -- Horizontal forward X component.
	@param LookZ number -- Horizontal forward Z component.
]=]
function PlayerService.UpdateTransform(
	self: PlayerRecord,
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
	const MaxCount = Storage.ECSData.GetCounts().EntityECSCount :: number
	if EntityId < 1 or EntityId > MaxCount then
		return
	end

	const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
	const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
	const PositionBuffer = Storage.PositionData.GetData() :: buffer
	const DirectionsBuffer = Storage.DirectionsData.GetData() :: buffer

	buffer.writef32(PositionBuffer, CompOffset, PosX)
	buffer.writef32(PositionBuffer, CompOffset + 4, PosY)
	buffer.writef32(PositionBuffer, CompOffset + 8, PosZ)

	-- Look (0..11), Up (12..23), Right = Look x Up (24..35)
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
	Updates IsVisible and CanCollide flags in-place on the bound ECS entity without altering DynamicId, TextureId, or ShapeId.
	@param Storage ECSMain.ECSStorage -- Target ECS storage container.
	@param IsVisible boolean -- Whether the renderer should draw this player entity.
	@param CanCollide boolean -- Whether BVH and physics queries should collide with this player entity.
]=]
function PlayerService.SetLocalVisibilityAndCollision(
	self: PlayerRecord,
	Storage: ECSMain.ECSStorage,
	IsVisible: boolean,
	CanCollide: boolean
)
	const EntityId = self.EntityId :: number
	const MaxCount = Storage.ECSData.GetCounts().EntityECSCount :: number
	if EntityId < 1 or EntityId > MaxCount then
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
	@param Storage ECSMain.ECSStorage -- Target ECS storage container.
	@param Color Color3 -- New display Color3.
]=]
function PlayerService.SetColor(self: PlayerRecord, Storage: ECSMain.ECSStorage, Color: Color3)
	const R = math.clamp(math.floor(Color.R * 255 + 0.5), 0, 255) :: number
	const G = math.clamp(math.floor(Color.G * 255 + 0.5), 0, 255) :: number
	const B = math.clamp(math.floor(Color.B * 255 + 0.5), 0, 255) :: number
	self.ColorR = R
	self.ColorG = G
	self.ColorB = B

	const EntityId = self.EntityId :: number
	const MaxCount = Storage.ECSData.GetCounts().EntityECSCount :: number
	if EntityId < 1 or EntityId > MaxCount then
		return
	end

	Storage.VisualData.CreateLayout((EntityId - 1) * VISUAL_STRIDE, R, G, B)
	Storage.ECSData.MarkDirty(EntityId)
end

--[=[
	Returns the player's current world position vector.
	@return Vector3 -- Current player center position.
]=]
function PlayerService.GetPosition(self: PlayerRecord): Vector3
	return Vector3.new(self.PositionX, self.PositionY, self.PositionZ)
end

--[=[
	Returns the player's current horizontal unit forward vector.
	@return Vector3 -- Current unit LookVector.
]=]
function PlayerService.GetLookVector(self: PlayerRecord): Vector3
	return Vector3.new(self.LookX, self.LookY, self.LookZ)
end

--[=[
	Unbinds this player from DynamicObjectsList and deletes its ECS entity slot via O(1) swap-and-pop.
	@param Storage ECSMain.ECSStorage -- Target ECS storage container.
]=]
function PlayerService.UnbindFromStorage(self: PlayerRecord, Storage: ECSMain.ECSStorage)
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

return PlayerService
