-- Services --
local ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
-- The render controller runs inside an Actor, and every Actor owns an isolated Luau VM with its
-- own copy of each required ModuleScript. The receiver therefore has to live in that same Actor,
-- otherwise it fills the PlayerScripts copy of the ECS that nothing ever reads and the controller
-- keeps seeing an entity count of 0. It is cloned into the controller Actor by RenderBootstrap.
local SelfActor = script:GetActor()
if not SelfActor then
	return
end

local CoreEvents = ReplicatedStorage:WaitForChild("CoreEvents") :: Folder
local ReplicateEvent = CoreEvents:WaitForChild("ReplicateEvent") :: RemoteEvent

-- Modules --
local ObjectStorage = SelfActor:WaitForChild("ObjectStorage") :: Folder

local ECSData = require(ObjectStorage:WaitForChild("ECSData"))
local PositionData = require(ObjectStorage:WaitForChild("PositionData"))
local OrientationData = require(ObjectStorage:WaitForChild("OrientationData"))
local VisualData = require(ObjectStorage:WaitForChild("VisualData"))
local SizeData = require(ObjectStorage:WaitForChild("SizeData"))
local DirectionsData = require(ObjectStorage:WaitForChild("DirectionsData"))

-- Configs --
local COMPONENT_STRIDE = 12 :: number -- position, orientation, visual and size store 3 x f32 per entity
local DIRECTION_STRIDE = 36 :: number -- look + up + right, 3 x f32 each

-- The local ECS buffers have a fixed size, so a snapshot holding more entities than they can store
-- is clamped instead of erroring out on an out of bounds write and dropping every later packet.
local MaxComponentEntities: number = math.min(
	buffer.len(PositionData.GetData()),
	buffer.len(OrientationData.GetData()),
	buffer.len(VisualData.GetData()),
	buffer.len(SizeData.GetData())
) // COMPONENT_STRIDE

local MaxDirectionEntities: number = buffer.len(DirectionsData.GetData()) // DIRECTION_STRIDE

local MAX_ENTITIES: number = math.min(MaxComponentEntities, MaxDirectionEntities)

export type ECSTable = {
	OrientationECSCount: number,
	PositionECSCount: number,
	VisualECSCount: number,
	SizeECSCount: number,
	DirectionsECSCount: number,
	EntityECSCount: number,
}

-- ============================================================================
-- 1. LISTENER - WRITES THE REPLICATED SNAPSHOT INTO THE LOCAL ECS
-- ============================================================================

ReplicateEvent.OnClientEvent:Connect(
	function(
		PositionBuffer: buffer,
		OrientationBuffer: buffer,
		VisualBuffer: buffer,
		SizeBuffer: buffer,
		DirectionsBuffer: buffer,
		ECSDataTable: ECSTable
	)
		local EntityCount = math.min(ECSDataTable.EntityECSCount, MAX_ENTITIES) :: number

		-- The packet is a full snapshot of what this client can see, so the local ECS mirrors it.
		ECSData.SetEntityCount(EntityCount)

		for i = 1, EntityCount do
			local ComponentOffset = (i - 1) * COMPONENT_STRIDE :: number -- same stride in the packet and the local ECS
			local DirectionOffset = (i - 1) * DIRECTION_STRIDE :: number

			local PositionX = buffer.readf32(PositionBuffer, ComponentOffset) :: number
			local PositionY = buffer.readf32(PositionBuffer, ComponentOffset + 4) :: number
			local PositionZ = buffer.readf32(PositionBuffer, ComponentOffset + 8) :: number

			local OrientationX = buffer.readf32(OrientationBuffer, ComponentOffset) :: number
			local OrientationY = buffer.readf32(OrientationBuffer, ComponentOffset + 4) :: number
			local OrientationZ = buffer.readf32(OrientationBuffer, ComponentOffset + 8) :: number

			local VisualR = buffer.readu8(VisualBuffer, ComponentOffset) :: number
			local VisualG = buffer.readu8(VisualBuffer, ComponentOffset + 1) :: number
			local VisualB = buffer.readu8(VisualBuffer, ComponentOffset + 2) :: number

			local SizeX = buffer.readf32(SizeBuffer, ComponentOffset) :: number
			local SizeY = buffer.readf32(SizeBuffer, ComponentOffset + 4) :: number
			local SizeZ = buffer.readf32(SizeBuffer, ComponentOffset + 8) :: number

			local LookX = buffer.readf32(DirectionsBuffer, DirectionOffset) :: number
			local LookY = buffer.readf32(DirectionsBuffer, DirectionOffset + 4) :: number
			local LookZ = buffer.readf32(DirectionsBuffer, DirectionOffset + 8) :: number

			local UpX = buffer.readf32(DirectionsBuffer, DirectionOffset + 12) :: number
			local UpY = buffer.readf32(DirectionsBuffer, DirectionOffset + 16) :: number
			local UpZ = buffer.readf32(DirectionsBuffer, DirectionOffset + 20) :: number

			local RightX = buffer.readf32(DirectionsBuffer, DirectionOffset + 24) :: number
			local RightY = buffer.readf32(DirectionsBuffer, DirectionOffset + 28) :: number
			local RightZ = buffer.readf32(DirectionsBuffer, DirectionOffset + 32) :: number

			PositionData.CreateLayout(ComponentOffset, PositionX, PositionY, PositionZ)
			OrientationData.CreateLayout(ComponentOffset, OrientationX, OrientationY, OrientationZ)
			VisualData.CreateLayout(ComponentOffset, VisualR, VisualG, VisualB)
			SizeData.CreateLayout(ComponentOffset, SizeX, SizeY, SizeZ)
			DirectionsData.CreateLayout(DirectionOffset, LookX, LookY, LookZ, UpX, UpY, UpZ, RightX, RightY, RightZ)
		end
	end
)
