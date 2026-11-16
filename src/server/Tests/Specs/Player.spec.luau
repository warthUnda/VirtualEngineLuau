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
	const UtilitiesFolder = SharedFolder:WaitForChild("Utilities")
	const PlayerFolder = UtilitiesFolder:WaitForChild("Player")

	-- Libraries --
	const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
	const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
	const BVH = require(UtilitiesFolder:WaitForChild("BVH"))
	const PlayerService = require(PlayerFolder:WaitForChild("Core"):WaitForChild("PlayerService"))
	const PlayerController = require(PlayerFolder:WaitForChild("Controller"):WaitForChild("PlayerController"))
	const PlayerControllerHelper =
		require(PlayerFolder:WaitForChild("Controller"):WaitForChild("PlayerControllerHelper"))
	const PlayerLibrary = require(PlayerFolder:WaitForChild("PlayerLibrary"))

	-- Configs --
	const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
	const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
	const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number

	describe("1. PlayerService OOP Linker & Renderable ECS Binding", function()
		it("should construct a PlayerRecord, populate renderable ECS buffers, and link via DynamicObjectsList", function()
			const TestStorage = ECSMain.CreateStorage(true)
			const MockPlayer = ({
				UserId = 1001,
				Name = "AlphaTester",
				Character = nil,
			} :: any) :: Player

			const Record = PlayerService.New(MockPlayer)
			expect(Record.UserId).to.equal(1001)
			expect(Record.Name).to.equal("AlphaTester")

			const EntityId, DynamicId = Record:BindToStorage(TestStorage)
			expect(EntityId).to.equal(1)
			expect(DynamicId > 0).to.equal(true)
			expect(Record.EntityId).to.equal(EntityId)
			expect(Record.DynamicId).to.equal(DynamicId)

			-- DynamicObjectsList OOP linker must resolve the PlayerRecord both by DynamicId and EntityId
			expect(TestStorage.DynamicObjectsList.GetObject(DynamicId)).to.equal(Record)
			expect(TestStorage.DynamicObjectsList.GetObjectByEntityId(EntityId)).to.equal(Record)
			expect(TestStorage.DynamicObjectsList.GetBoundEntityId(DynamicId)).to.equal(EntityId)

			-- Properties register must mark entity visible, collidable, anchored, and stamped with DynamicId
			const PropReg = buffer.readu32(TestStorage.PropertiesData.GetData(), (EntityId - 1) * PROPERTIES_STRIDE)
			expect(ECSMain.IsEntityVisible(PropReg)).to.equal(true)
			expect(ECSMain.CanEntityCollide(PropReg)).to.equal(true)
			expect(ECSMain.IsEntityAnchored(PropReg)).to.equal(true)
			expect(ECSMain.GetEntityDynamicId(PropReg)).to.equal(DynamicId)

			-- BVH raycast against the rendered player OBB must return the linked OOP PlayerRecord
			Record:UpdateTransform(TestStorage, 0, 10, -20, 0, -1)
			const HitId, HitObj, HitDist = BVH.Raycast(
				TestStorage,
				Vector3.new(0, 10, 0),
				Vector3.new(0, 0, -1),
				50,
				nil
			)
			expect(HitId).to.equal(EntityId)
			expect(HitObj).to.equal(Record)
			expect(HitDist < 20).to.equal(true)

			Record:UnbindFromStorage(TestStorage)
			expect(TestStorage.ECSData.GetCounts().EntityECSCount).to.equal(0)
			expect(TestStorage.DynamicObjectsList.GetObject(DynamicId)).to.equal(nil)
		end)
	end)

	describe("2. Live Player Transform Sync, Binary State Payloads & PlayerLibrary API", function()
		it("should update horizontal orthonormal basis, mark dirty flags, and decode 20-byte state packets", function()
			const TestStorage = ECSMain.CreateStorage(true)
			const MockPlayer = ({
				UserId = 2002,
				Name = "BravoTester",
				Character = nil,
			} :: any) :: Player

			const Record = PlayerLibrary.RegisterPlayer(MockPlayer, TestStorage)
			expect(Record ~= nil).to.equal(true)
			if not Record then
				return
			end

			const EntityId = Record.EntityId
			TestStorage.ECSData.ClearDirty(EntityId)

			const Payload = buffer.create(20)
			const PackedOk = PlayerControllerHelper.PackStatePayload(Payload, 25, 14, -40, 1, 0)
			expect(PackedOk).to.equal(true)

			const AppliedOk = PlayerController.ApplyStatePayload(MockPlayer, Payload, TestStorage)
			expect(AppliedOk).to.equal(true)

			-- Dirty flag must be raised so Replicator & RendererCleaner pick up the moved player
			expect(buffer.readu8(TestStorage.ECSData.GetDirtyFlags(), EntityId - 1)).to.equal(1)

			const CompOffset = (EntityId - 1) * COMPONENT_STRIDE
			const DirOffset = (EntityId - 1) * DIRECTION_STRIDE
			const PosBuf = TestStorage.PositionData.GetData()
			const DirBuf = TestStorage.DirectionsData.GetData()

			expect(buffer.readf32(PosBuf, CompOffset)).to.be.near(25, 1e-4)
			expect(buffer.readf32(PosBuf, CompOffset + 4)).to.be.near(14, 1e-4)
			expect(buffer.readf32(PosBuf, CompOffset + 8)).to.be.near(-40, 1e-4)

			-- Look = (1, 0, 0), Up = (0, 1, 0) -> Right = Look x Up = (0, 0, 1)
			expect(buffer.readf32(DirBuf, DirOffset)).to.be.near(1, 1e-4)
			expect(buffer.readf32(DirBuf, DirOffset + 16)).to.be.near(1, 1e-4)
			expect(buffer.readf32(DirBuf, DirOffset + 32)).to.be.near(1, 1e-4)

			-- Malformed NaN payload must be rejected without corrupting coordinates
			const BadPayload = buffer.create(20)
			buffer.writef32(BadPayload, 0, 0 / 0)
			expect(PlayerController.ApplyStatePayload(MockPlayer, BadPayload, TestStorage)).to.equal(false)
			expect(Record:GetPosition().X).to.be.near(25, 1e-4)

			expect(PlayerLibrary.GetPlayerRecord(MockPlayer)).to.equal(Record)
			expect(PlayerLibrary.GetPlayerRecordByUserId(2002)).to.equal(Record)
			expect(PlayerLibrary.GetPlayerRecordByEntityId(EntityId, TestStorage)).to.equal(Record)
			expect(PlayerLibrary.SetPlayerColor(MockPlayer, Color3.fromRGB(255, 64, 32), TestStorage)).to.equal(true)

			PlayerLibrary.RemovePlayer(MockPlayer, TestStorage)
			PlayerController.ResetRegistryForTest(TestStorage)
		end)
	end)

	describe("3. O(1) Swap-and-Pop Compaction Across Multiple Connected Players", function()
		it("should preserve moved tail player's DynamicObjectsList OOP binding when an earlier player disconnects", function()
			const TestStorage = ECSMain.CreateStorage(true)
			PlayerController.Initialize(TestStorage)

			const PlayerA = ({ UserId = 3001, Name = "PlayerA", Character = nil } :: any) :: Player
			const PlayerB = ({ UserId = 3002, Name = "PlayerB", Character = nil } :: any) :: Player

			const RecordA = PlayerController.RegisterPlayer(PlayerA, TestStorage)
			const RecordB = PlayerController.RegisterPlayer(PlayerB, TestStorage)
			expect(RecordA ~= nil and RecordB ~= nil).to.equal(true)
			if not RecordA or not RecordB then
				return
			end

			PlayerLibrary.UpdatePlayerTransform(PlayerA, Vector3.new(-20, 10, -20), Vector3.new(0, 0, -1), TestStorage)
			PlayerLibrary.UpdatePlayerTransform(PlayerB, Vector3.new(30, 10, -20), Vector3.new(0, 0, -1), TestStorage)

			expect(RecordA.EntityId).to.equal(1)
			expect(RecordB.EntityId).to.equal(2)

			-- Disconnect PlayerA (slot 1); PlayerB (slot 2) must swap-pop into slot 1 with intact OOP link
			PlayerController.RemovePlayer(PlayerA, TestStorage)

			expect(TestStorage.ECSData.GetCounts().EntityECSCount).to.equal(1)
			expect(RecordB.EntityId).to.equal(1)
			expect(TestStorage.DynamicObjectsList.GetBoundEntityId(RecordB.DynamicId)).to.equal(1)
			expect(TestStorage.DynamicObjectsList.GetObjectByEntityId(1)).to.equal(RecordB)

			const HitId, HitObj = BVH.Raycast(
				TestStorage,
				Vector3.new(30, 10, 0),
				Vector3.new(0, 0, -1),
				50,
				nil
			)
			expect(HitId).to.equal(1)
			expect(HitObj).to.equal(RecordB)

			PlayerController.RemovePlayer(PlayerB, TestStorage)
			PlayerController.ResetRegistryForTest(TestStorage)
		end)
	end)
end
