--!strict
--!native
--!optimize 2

return function()
	const SpecEnv = getfenv() :: {
		describe: (string, () -> ()) -> (),
		it: (string, () -> ()) -> (),
		expect: (any) -> any,
	}
	const describe = SpecEnv.describe
	const it = SpecEnv.it
	const expect = SpecEnv.expect

	-- Services --
	const ReplicatedStorage = game:GetService("ReplicatedStorage")

	-- Static References --
	const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
	const ReplicationFolder = script.Parent.Parent.Parent
		:WaitForChild("Objects")
		:WaitForChild("Replication")

	-- Libraries --
	const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
	const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
	const ReplicationReceiverHelper = require(ReplicationFolder:WaitForChild("ReplicationReceiverHelper"))

	-- Configs --
	const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
	const VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
	const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
	const HEADER_BYTES = 8 :: number

	describe("1. Client Replication Delta Ingestion", function()
		it("should unpack single binary delta payloads, reconstruct Right vector, and compact despawns", function()
			const ClientStorage = ECSMain.CreateStorage(false)
			const ECSData = ClientStorage.ECSData
			const LocalPositionBuffer = ClientStorage.PositionData.GetData()
			const LocalDirectionsBuffer = ClientStorage.DirectionsData.GetData()
			const LocalVisualBuffer = ClientStorage.VisualData.GetData()
			const LocalPropertiesBuffer = ClientStorage.PropertiesData.GetData()

			const ReceiverState = ReplicationReceiverHelper.CreateReceiverState(ClientStorage, 501)

			-- Pre-register a local player OOP record at DynamicId = 1 to verify OOP EntityId linking & self-collision suppression
			const LinkedPlayerRecord = {
				ClassName = "PlayerService",
				UserId = 501,
				EntityId = 0,
			}
			ClientStorage.DynamicObjectsList.SetObjectAtId(1, LinkedPlayerRecord, nil)

			--[=[
				Builds a binary replication packet matching server PlayerCuller format for testing delta ingestion.
				@param UpdatedCount number -- Count of updated entity entries in packet.
				@param WorldEntityCount number -- Total active server ECS entities.
				@param Entries any -- Array of entity delta descriptors.
				@return buffer -- Serialized binary payload buffer.
			]=]
			local function BuildBinaryPacket(
				UpdatedCount: number,
				WorldEntityCount: number,
				Entries: {
					{
						ServerId: number,
						Mask: number,
						Pos: Vector3?,
						VisualRGBA: number?,
						Look: Vector3?,
						Up: Vector3?,
						PropReg: number?,
					}
				}
			): buffer
				const Payload = buffer.create(HEADER_BYTES + UpdatedCount * 64)
				buffer.writeu16(Payload, 0, UpdatedCount)
				buffer.writeu16(Payload, 2, WorldEntityCount)
				buffer.writeu32(Payload, 4, 1)

				local WriteOffset = HEADER_BYTES
				for _, Entry in Entries do
					buffer.writeu16(Payload, WriteOffset, Entry.ServerId)
					buffer.writeu8(Payload, WriteOffset + 2, Entry.Mask)
					WriteOffset += 3

					if bit32.band(Entry.Mask, 1) ~= 0 and Entry.Pos then
						buffer.writef32(Payload, WriteOffset, Entry.Pos.X)
						buffer.writef32(Payload, WriteOffset + 4, Entry.Pos.Y)
						buffer.writef32(Payload, WriteOffset + 8, Entry.Pos.Z)
						WriteOffset += COMPONENT_STRIDE
					end

					if bit32.band(Entry.Mask, 4) ~= 0 and Entry.Look and Entry.Up then
						buffer.writef32(Payload, WriteOffset, Entry.Look.X)
						buffer.writef32(Payload, WriteOffset + 4, Entry.Look.Y)
						buffer.writef32(Payload, WriteOffset + 8, Entry.Look.Z)
						buffer.writef32(Payload, WriteOffset + 12, Entry.Up.X)
						buffer.writef32(Payload, WriteOffset + 16, Entry.Up.Y)
						buffer.writef32(Payload, WriteOffset + 20, Entry.Up.Z)
						WriteOffset += 24
					end

					if bit32.band(Entry.Mask, 8) ~= 0 and Entry.VisualRGBA then
						buffer.writeu32(Payload, WriteOffset, Entry.VisualRGBA)
						WriteOffset += VISUAL_STRIDE
					end

					if bit32.band(Entry.Mask, 16) ~= 0 and Entry.PropReg then
						buffer.writeu32(Payload, WriteOffset, Entry.PropReg)
						WriteOffset += PROPERTIES_STRIDE
					end
				end

				return Payload
			end

			-- Packet 1: Spawn ServerId = 1 (with orientation Look/Up + visual + DynamicId=1) and ServerId = 2
			const Packet1 = BuildBinaryPacket(2, 2, {
				{
					ServerId = 1,
					Mask = 1 + 4 + 8 + 16,
					Pos = Vector3.new(15, 25, 35),
					Look = Vector3.new(0, 0, -1),
					Up = Vector3.new(0, 1, 0),
					VisualRGBA = 0xFF00AAFF,
					PropReg = ECSMain.PackProperties(true, true, true, 1, 0, 1),
				},
				{
					ServerId = 2,
					Mask = 1,
					Pos = Vector3.new(50, 60, 70),
				},
			})
			ReplicationReceiverHelper.IngestPayload(ReceiverState, Packet1)

			expect(ECSData.GetCounts().EntityECSCount).to.equal(2)
			expect(buffer.readu32(ReceiverState.ClientSlotByServerId, 1 * 4)).to.equal(1)
			expect(buffer.readu32(ReceiverState.ClientSlotByServerId, 2 * 4)).to.equal(2)
			expect(LinkedPlayerRecord.EntityId).to.equal(1)
			expect(ECSMain.CanEntityCollide(buffer.readu32(LocalPropertiesBuffer, 0))).to.equal(false)
			expect(buffer.readf32(LocalPositionBuffer, 0)).to.equal(15)
			expect(buffer.readf32(LocalPositionBuffer, COMPONENT_STRIDE)).to.equal(50)
			-- Verify RightVector = Look(0,0,-1) x Up(0,1,0) = (1, 0, 0)
			expect(buffer.readf32(LocalDirectionsBuffer, 24)).to.be.near(1, 1e-4)
			expect(buffer.readu32(LocalVisualBuffer, 0)).to.equal(0xFF00AAFF)

			-- Packet 2: Delta update only ServerId = 1 position + despawn tail ServerId = 2 (WorldEntityCount: 2 -> 1)
			const Packet2 = BuildBinaryPacket(1, 1, {
				{
					ServerId = 1,
					Mask = 1,
					Pos = Vector3.new(99, 99, 99),
				},
			})
			ReplicationReceiverHelper.IngestPayload(ReceiverState, Packet2)

			expect(ECSData.GetCounts().EntityECSCount).to.equal(1)
			expect(buffer.readu32(ReceiverState.ClientSlotByServerId, 2 * 4)).to.equal(0)
			expect(buffer.readf32(LocalPositionBuffer, 0)).to.equal(99)
		end)
	end)
end
