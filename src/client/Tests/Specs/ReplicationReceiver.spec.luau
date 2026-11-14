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

	const ReplicatedStorage = game:GetService("ReplicatedStorage")
	const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

	const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
	const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))

	const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
	const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
	const VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
	const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
	const HEADER_BYTES = 8 :: number

	describe("1. Client Replication Delta Ingestion", function()
		it("should unpack single binary delta payloads, reconstruct Right vector, and compact despawns", function()
			const ClientStorage = ECSMain.CreateStorage(false)
			const ECSData = ClientStorage.ECSData
			const LocalPositionBuffer = ClientStorage.PositionData.GetData()
			const LocalSizeBuffer = ClientStorage.SizeData.GetData()
			const LocalDirectionsBuffer = ClientStorage.DirectionsData.GetData()
			const LocalVisualBuffer = ClientStorage.VisualData.GetData()
			const LocalPropertiesBuffer = ClientStorage.PropertiesData.GetData()

			const ClientSlotByServerId = buffer.create((100 + 1) * 4)
			const ServerIdByClientSlot = buffer.create((100 + 1) * 4)
			ECSData.SetSwapPopCallback(function(DeletedSlot: number, MovedFromSlot: number)
				if DeletedSlot ~= MovedFromSlot then
					const MovedServerId = buffer.readu32(ServerIdByClientSlot, MovedFromSlot * 4)
					buffer.writeu32(ServerIdByClientSlot, DeletedSlot * 4, MovedServerId)
					if MovedServerId > 0 then
						buffer.writeu32(ClientSlotByServerId, MovedServerId * 4, DeletedSlot)
					end
				end
				buffer.writeu32(ServerIdByClientSlot, MovedFromSlot * 4, 0)
			end)

			-- Helper matching PlayerCuller -> ReplicationReceiver binary packet format
			local function BuildBinaryPacket(
				UpdatedCount: number,
				WorldEntityCount: number,
				Entries: { { ServerId: number, Mask: number, Pos: Vector3?, VisualRGBA: number?, Look: Vector3?, Up: Vector3? } }
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
				end

				return Payload
			end

			local LastWorldEntityCount = 0
			local function IngestPacket(Payload: buffer)
				const UpdatedCount = buffer.readu16(Payload, 0)
				const WorldEntityCount = buffer.readu16(Payload, 2)
				if WorldEntityCount < LastWorldEntityCount then
					for ServerId = WorldEntityCount + 1, LastWorldEntityCount do
						const StaleSlot = buffer.readu32(ClientSlotByServerId, ServerId * 4)
						if StaleSlot > 0 then
							buffer.writeu32(ClientSlotByServerId, ServerId * 4, 0)
							ECSData.DeleteEntity(StaleSlot)
						end
					end
				end
				LastWorldEntityCount = WorldEntityCount

				local ReadOffset = HEADER_BYTES
				for _ = 1, UpdatedCount do
					const ServerId = buffer.readu16(Payload, ReadOffset)
					const Mask = buffer.readu8(Payload, ReadOffset + 2)
					ReadOffset += 3

					local TargetSlot = buffer.readu32(ClientSlotByServerId, ServerId * 4)
					if TargetSlot == 0 then
						TargetSlot = ECSData.RegisterEntity()
						buffer.writeu32(ClientSlotByServerId, ServerId * 4, TargetSlot)
						buffer.writeu32(ServerIdByClientSlot, TargetSlot * 4, ServerId)
					end

					const WriteOffset = (TargetSlot - 1) * COMPONENT_STRIDE
					const DirOffset = (TargetSlot - 1) * DIRECTION_STRIDE
					const VisOffset = (TargetSlot - 1) * VISUAL_STRIDE
					const PropOffset = (TargetSlot - 1) * PROPERTIES_STRIDE

					if bit32.band(Mask, 1) ~= 0 then
						buffer.copy(LocalPositionBuffer, WriteOffset, Payload, ReadOffset, COMPONENT_STRIDE)
						ReadOffset += COMPONENT_STRIDE
					end
					if bit32.band(Mask, 2) ~= 0 then
						buffer.copy(LocalSizeBuffer, WriteOffset, Payload, ReadOffset, COMPONENT_STRIDE)
						ReadOffset += COMPONENT_STRIDE
					end
					if bit32.band(Mask, 4) ~= 0 then
						const LookX = buffer.readf32(Payload, ReadOffset)
						const LookY = buffer.readf32(Payload, ReadOffset + 4)
						const LookZ = buffer.readf32(Payload, ReadOffset + 8)
						const UpX = buffer.readf32(Payload, ReadOffset + 12)
						const UpY = buffer.readf32(Payload, ReadOffset + 16)
						const UpZ = buffer.readf32(Payload, ReadOffset + 20)
						ReadOffset += 24
						buffer.writef32(LocalDirectionsBuffer, DirOffset, LookX)
						buffer.writef32(LocalDirectionsBuffer, DirOffset + 4, LookY)
						buffer.writef32(LocalDirectionsBuffer, DirOffset + 8, LookZ)
						buffer.writef32(LocalDirectionsBuffer, DirOffset + 12, UpX)
						buffer.writef32(LocalDirectionsBuffer, DirOffset + 16, UpY)
						buffer.writef32(LocalDirectionsBuffer, DirOffset + 20, UpZ)
						buffer.writef32(LocalDirectionsBuffer, DirOffset + 24, LookY * UpZ - LookZ * UpY)
						buffer.writef32(LocalDirectionsBuffer, DirOffset + 28, LookZ * UpX - LookX * UpZ)
						buffer.writef32(LocalDirectionsBuffer, DirOffset + 32, LookX * UpY - LookY * UpX)
					end
					if bit32.band(Mask, 8) ~= 0 then
						buffer.copy(LocalVisualBuffer, VisOffset, Payload, ReadOffset, VISUAL_STRIDE)
						ReadOffset += VISUAL_STRIDE
					end
					if bit32.band(Mask, 16) ~= 0 then
						buffer.copy(LocalPropertiesBuffer, PropOffset, Payload, ReadOffset, PROPERTIES_STRIDE)
						ReadOffset += PROPERTIES_STRIDE
					end
					ECSData.MarkDirty(TargetSlot)
				end
			end

			-- Packet 1: Spawn ServerId = 1 (with orientation Look/Up + visual) and ServerId = 2
			const Packet1 = BuildBinaryPacket(2, 2, {
				{
					ServerId = 1,
					Mask = 1 + 4 + 8,
					Pos = Vector3.new(15, 25, 35),
					Look = Vector3.new(0, 0, -1),
					Up = Vector3.new(0, 1, 0),
					VisualRGBA = 0xFF00AAFF,
				},
				{
					ServerId = 2,
					Mask = 1,
					Pos = Vector3.new(50, 60, 70),
				},
			})
			IngestPacket(Packet1)

			expect(ECSData.GetCounts().EntityECSCount).to.equal(2)
			expect(buffer.readu32(ClientSlotByServerId, 1 * 4)).to.equal(1)
			expect(buffer.readu32(ClientSlotByServerId, 2 * 4)).to.equal(2)
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
			IngestPacket(Packet2)

			expect(ECSData.GetCounts().EntityECSCount).to.equal(1)
			expect(buffer.readu32(ClientSlotByServerId, 2 * 4)).to.equal(0)
			expect(buffer.readf32(LocalPositionBuffer, 0)).to.equal(99)
		end)
	end)
end
