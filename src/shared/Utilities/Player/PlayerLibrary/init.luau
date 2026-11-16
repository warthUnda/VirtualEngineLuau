--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const PlayerFolder = SharedFolder:WaitForChild("Utilities"):WaitForChild("Player")

-- Modules --
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
const PlayerService = require(PlayerFolder:WaitForChild("Core"):WaitForChild("PlayerService"))
const PlayerController = require(PlayerFolder:WaitForChild("Controller"):WaitForChild("PlayerController"))
const PlayerControllerHelper = require(PlayerFolder:WaitForChild("Controller"):WaitForChild("PlayerControllerHelper"))

-- Tables --
local PlayerLibrary = {}

-- ============================================================================
-- 1. PUBLIC PLAYER LIFECYCLE, OOP LINKER & RENDERING TRANSFORM API
-- ============================================================================

--[=[
	Registers a Player into the ECS renderer and links its OOP PlayerService instance into DynamicObjectsList.
	@param PlayerInstance Player -- Target player instance.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional isolated ECSStorage override.
	@return PlayerService.PlayerRecord? -- Linked OOP PlayerRecord (or nil).
]=]
function PlayerLibrary.RegisterPlayer(
	PlayerInstance: Player,
	ProvidedStorage: ECSMain.ECSStorage?
): PlayerService.PlayerRecord?
	return PlayerController.RegisterPlayer(PlayerInstance, ProvidedStorage)
end

--[=[
	Unregisters a Player, deleting its rendered ECS entity and unbinding its DynamicObjectsList OOP slot.
	@param PlayerInstance Player -- Target player instance.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional isolated ECSStorage override.
]=]
function PlayerLibrary.RemovePlayer(PlayerInstance: Player, ProvidedStorage: ECSMain.ECSStorage?)
	PlayerController.RemovePlayer(PlayerInstance, ProvidedStorage)
end

--[=[
	Returns the OOP PlayerService record bound to a Player instance.
	@param PlayerInstance Player -- Target player instance.
	@return PlayerService.PlayerRecord? -- Bound OOP PlayerRecord (or nil).
]=]
function PlayerLibrary.GetPlayerRecord(PlayerInstance: Player): PlayerService.PlayerRecord?
	return PlayerController.GetPlayerRecord(PlayerInstance)
end

--[=[
	Returns the OOP PlayerService record matching a Roblox UserId.
	@param UserId number -- Target player UserId.
	@return PlayerService.PlayerRecord? -- Bound OOP PlayerRecord (or nil).
]=]
function PlayerLibrary.GetPlayerRecordByUserId(UserId: number): PlayerService.PlayerRecord?
	return PlayerController.GetPlayerRecordByUserId(UserId)
end

--[=[
	Resolves the OOP PlayerService record linked to a rendered ECS entity slot via DynamicObjectsList.
	@param EntityId number -- Target 1-based ECS entity ID.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional isolated ECSStorage override.
	@return PlayerService.PlayerRecord? -- Bound OOP PlayerRecord (or nil if entity is not a player).
]=]
function PlayerLibrary.GetPlayerRecordByEntityId(
	EntityId: number,
	ProvidedStorage: ECSMain.ECSStorage?
): PlayerService.PlayerRecord?
	return PlayerController.GetPlayerRecordByEntityId(EntityId, ProvidedStorage)
end

--[=[
	Updates a registered player's rendered ECS world position and horizontal facing direction.
	@param PlayerInstance Player -- Target player instance.
	@param Position Vector3 -- New world center position.
	@param LookDirection Vector3 -- Desired forward direction vector (projected onto XZ plane).
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional isolated ECSStorage override.
	@return boolean -- True if the player's ECS entity was updated.
]=]
function PlayerLibrary.UpdatePlayerTransform(
	PlayerInstance: Player,
	Position: Vector3,
	LookDirection: Vector3,
	ProvidedStorage: ECSMain.ECSStorage?
): boolean
	const Record = PlayerController.GetPlayerRecord(PlayerInstance)
	const Storage = PlayerControllerHelper.ResolveStorage(ProvidedStorage)
	if not Record or not Storage then
		return false
	end

	Record:UpdateTransform(Storage, Position.X, Position.Y, Position.Z, LookDirection.X, LookDirection.Z)
	return true
end

--[=[
	Updates a registered player's rendered RGB color in the ECS VisualData buffer.
	@param PlayerInstance Player -- Target player instance.
	@param Color Color3 -- Target display color.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional isolated ECSStorage override.
	@return boolean -- True if updated successfully.
]=]
function PlayerLibrary.SetPlayerColor(
	PlayerInstance: Player,
	Color: Color3,
	ProvidedStorage: ECSMain.ECSStorage?
): boolean
	const Record = PlayerController.GetPlayerRecord(PlayerInstance)
	const Storage = PlayerControllerHelper.ResolveStorage(ProvidedStorage)
	if not Record or not Storage then
		return false
	end

	Record:SetColor(Storage, Color)
	return true
end

return PlayerLibrary
