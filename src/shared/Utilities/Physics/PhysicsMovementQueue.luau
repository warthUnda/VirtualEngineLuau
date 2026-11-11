--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const MAX_PLAYER_COMMANDS = SystemsConfigs.PlayerQueueMaxCommands :: number
const MAX_OBJECT_COMMANDS = SystemsConfigs.ObjectQueueMaxCommands :: number

const PLAYER_COMMAND_STRIDE = 20 :: number -- DirX, DirY, DirZ, Scale (4 x f32) + Flags (u8 + 3 pad)
const OBJECT_COMMAND_STRIDE = 24 :: number -- EntityId (u32) + DirX, DirY, DirZ, Magnitude (4 x f32) + Flags (u8 + 3 pad)

export type PlayerMovementEntry = {
	DirX: number,
	DirY: number,
	DirZ: number,
	Scale: number?,
	Jump: boolean?,
	IsImpulse: boolean?,
}

-- Tables --
local PlayerCommandCount = 0 :: number
local ObjectCommandCount = 0 :: number

local Queue = {}

Queue.PlayerQueue = {} :: { PlayerMovementEntry }
Queue.PlayerCommandStride = PLAYER_COMMAND_STRIDE :: number
Queue.ObjectCommandStride = OBJECT_COMMAND_STRIDE :: number

-- Buffers
Queue.PlayerBuffer = buffer.create(MAX_PLAYER_COMMANDS * PLAYER_COMMAND_STRIDE) :: buffer
Queue.ObjectQueue = buffer.create(MAX_OBJECT_COMMANDS * OBJECT_COMMAND_STRIDE) :: buffer

-- ============================================================================
-- 1. QUEUE OPERATIONS - ENQUEUE & FLUSH MOVEMENT INTENTS
-- ============================================================================

function Queue.AddMovement(
	DirX: number,
	DirY: number,
	DirZ: number,
	Scale: number?,
	Jump: boolean?,
	IsImpulse: boolean?
)
	if PlayerCommandCount >= MAX_PLAYER_COMMANDS then
		return
	end

	const Offset = PlayerCommandCount * PLAYER_COMMAND_STRIDE :: number
	const ResolvedScale = if Scale ~= nil then Scale else 1.0 :: number
	local Flags = if Jump then 1 else 0 :: number
	if IsImpulse then
		Flags += 2
	end

	buffer.writef32(Queue.PlayerBuffer, Offset, DirX)
	buffer.writef32(Queue.PlayerBuffer, Offset + 4, DirY)
	buffer.writef32(Queue.PlayerBuffer, Offset + 8, DirZ)
	buffer.writef32(Queue.PlayerBuffer, Offset + 12, ResolvedScale)
	buffer.writeu8(Queue.PlayerBuffer, Offset + 16, Flags)

	PlayerCommandCount += 1
end

function Queue.AddObjectMovement(
	EntityId: number,
	DirX: number,
	DirY: number,
	DirZ: number,
	Magnitude: number,
	IsImpulse: boolean?
)
	if EntityId < 1 or ObjectCommandCount >= MAX_OBJECT_COMMANDS then
		return
	end

	const Offset = ObjectCommandCount * OBJECT_COMMAND_STRIDE :: number
	const Flags = if IsImpulse then 1 else 0 :: number

	buffer.writeu32(Queue.ObjectQueue, Offset, EntityId)
	buffer.writef32(Queue.ObjectQueue, Offset + 4, DirX)
	buffer.writef32(Queue.ObjectQueue, Offset + 8, DirY)
	buffer.writef32(Queue.ObjectQueue, Offset + 12, DirZ)
	buffer.writef32(Queue.ObjectQueue, Offset + 16, Magnitude)
	buffer.writeu8(Queue.ObjectQueue, Offset + 20, Flags)

	ObjectCommandCount += 1
end

function Queue.GetPlayerCommandCount(): number
	return PlayerCommandCount
end

function Queue.GetObjectCommandCount(): number
	return ObjectCommandCount
end

function Queue.Clear()
	PlayerCommandCount = 0
	ObjectCommandCount = 0
	table.clear(Queue.PlayerQueue)
end

return Queue
