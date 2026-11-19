--!strict
--!native
--!optimize 2

--[=[
	@class PlayerRecordAccessors
	Getters and setters for PlayerService OOP records (position, look vector,
	color, and local visibility/collision ECS bitfield updates).
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))

-- Configs --
const VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const FLAG_CAN_COLLIDE = bit32.lshift(1, 1) :: number
const FLAG_IS_VISIBLE = bit32.lshift(1, 2) :: number
const VISIBILITY_COLLISION_MASK = bit32.bor(FLAG_CAN_COLLIDE, FLAG_IS_VISIBLE) :: number

-- Tables --
local PlayerRecordAccessors = {}

-- Functions --
-- ============================================================================
-- 1. PLAYER RECORD GETTERS & SETTERS
-- ============================================================================

--[=[
	Updates IsVisible and CanCollide flags in-place on the bound ECS entity without altering other bitfields.
	@param Storage ECSMain.ECSStorage -- Target ECS storage.
	@param IsVisible boolean -- Desired visibility flag.
	@param CanCollide boolean -- Desired collision flag.
]=]
function PlayerRecordAccessors.SetLocalVisibilityAndCollision(
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
	@param Storage ECSMain.ECSStorage -- Target ECS storage.
	@param Color Color3 -- New RGB color.
]=]
function PlayerRecordAccessors.SetColor(self: any, Storage: ECSMain.ECSStorage, Color: Color3)
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

--[=[
	Returns the player's cached world-space position as a Vector3.
	@return Vector3 -- Cached position.
]=]
function PlayerRecordAccessors.GetPosition(self: any): Vector3
	return Vector3.new(self.PositionX, self.PositionY, self.PositionZ)
end

--[=[
	Returns the player's cached look direction as a Vector3.
	@return Vector3 -- Cached look vector.
]=]
function PlayerRecordAccessors.GetLookVector(self: any): Vector3
	return Vector3.new(self.LookX, self.LookY, self.LookZ)
end

return PlayerRecordAccessors
