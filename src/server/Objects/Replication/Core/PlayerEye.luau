local PlayerEye = {}

local RENDER_DISTANCE = 200 :: number
local POSITION_STRIDE = 12 :: number -- 3 x f32 per entity

local PositionData = require(game.ServerScriptService.Server.Objects.ObjectsECS.Storage.PositionData)
local ECSData = require(game.ServerScriptService.Server.Objects.ObjectsECS.Storage.ECSData)

-- Returns a buffer holding the positions of every entity within RENDER_DISTANCE of
-- the player, along with the number of bytes written. Entities further away are culled.
function PlayerEye.CullObjects(PlayerObject: Player): (buffer?, number)
	local Character = PlayerObject.Character
	if not Character then
		return nil, 0
	end

	local Head = Character:FindFirstChild("Head")
	if not Head or not Head:IsA("BasePart") then
		return nil, 0
	end

	local HeadPosition = Head.Position :: Vector3
	local EntityCount = ECSData.GetCounts().EntityECSCount :: number
	local PositionBuffer = PositionData.GetData() :: buffer

	local DeltaBuffer = buffer.create(EntityCount * POSITION_STRIDE) :: buffer
	local WriteOffset = 0 :: number

	for i = 1, EntityCount do
		local ReadOffset = (i - 1) * POSITION_STRIDE

		local X = buffer.readf32(PositionBuffer, ReadOffset) :: number
		local Y = buffer.readf32(PositionBuffer, ReadOffset + 4) :: number
		local Z = buffer.readf32(PositionBuffer, ReadOffset + 8) :: number

		if (Vector3.new(X, Y, Z) - HeadPosition).Magnitude >= RENDER_DISTANCE then
			continue
		end

		buffer.writef32(DeltaBuffer, WriteOffset, X)
		buffer.writef32(DeltaBuffer, WriteOffset + 4, Y)
		buffer.writef32(DeltaBuffer, WriteOffset + 8, Z)
		WriteOffset += POSITION_STRIDE
	end

	return DeltaBuffer, WriteOffset
end

return PlayerEye
