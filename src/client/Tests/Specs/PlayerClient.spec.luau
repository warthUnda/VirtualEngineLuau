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

	-- Modules --
	const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
	const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
	const BVH = require(UtilitiesFolder:WaitForChild("BVH"))
	const PlayerController = require(PlayerFolder:WaitForChild("Controller"):WaitForChild("PlayerController"))
	const TestHelper = require(script.Parent.Parent.TestHelper)

	-- Configs --
	const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number

	describe("1. Client Replicated Player OOP Linking & Local Self-Collision Suppression", function()
		it("should link remote players as solid visible OOP entities while keeping the local player non-collidable", function()
			const TestStorage = TestHelper.CreateTestStorage()

			-- Simulate two replicated player entities arriving from the server
			const LocalSlot = TestHelper.PopulateEntity(
				TestStorage,
				Vector3.new(0, 10, 0),
				Vector3.new(0, 0, -1),
				Vector3.new(0, 1, 0),
				Vector3.new(1, 0, 0),
				Vector3.new(2, 5, 2),
				Color3.fromRGB(90, 170, 255)
			)
			TestStorage.PropertiesData.CreateLayout((LocalSlot - 1) * PROPERTIES_STRIDE, true, true, true, 1, 0, 1)

			const RemoteSlot = TestHelper.PopulateEntity(
				TestStorage,
				Vector3.new(0, 10, -25),
				Vector3.new(0, 0, -1),
				Vector3.new(0, 1, 0),
				Vector3.new(1, 0, 0),
				Vector3.new(2, 5, 2),
				Color3.fromRGB(255, 120, 80)
			)
			TestStorage.PropertiesData.CreateLayout((RemoteSlot - 1) * PROPERTIES_STRIDE, true, true, true, 2, 0, 1)

			PlayerController.ApplyRegistryEntries({
				{ UserId = 501, DynamicId = 1, Name = "LocalHero", ColorR = 90, ColorG = 170, ColorB = 255 },
				{ UserId = 502, DynamicId = 2, Name = "RemoteRival", ColorR = 255, ColorG = 120, ColorB = 80 },
			}, TestStorage, 501)

			const LocalRecord = PlayerController.GetPlayerRecordByUserId(501)
			const RemoteRecord = PlayerController.GetPlayerRecordByUserId(502)
			expect(LocalRecord ~= nil).to.equal(true)
			expect(RemoteRecord ~= nil).to.equal(true)

			-- Both slots must resolve their OOP PlayerRecord through DynamicObjectsList
			expect(TestStorage.DynamicObjectsList.GetObjectByEntityId(LocalSlot)).to.equal(LocalRecord)
			expect(TestStorage.DynamicObjectsList.GetObjectByEntityId(RemoteSlot)).to.equal(RemoteRecord)

			-- First-person sync: local player must be non-collidable and hidden; remote player stays solid & visible
			PlayerController.SyncLocalPlayerEntity(false, 0, 10, 0, 0, -1, TestStorage, 501)

			const PropsBuf = TestStorage.PropertiesData.GetData()
			const LocalPropReg = buffer.readu32(PropsBuf, (LocalSlot - 1) * PROPERTIES_STRIDE)
			const RemotePropReg = buffer.readu32(PropsBuf, (RemoteSlot - 1) * PROPERTIES_STRIDE)

			expect(ECSMain.CanEntityCollide(LocalPropReg)).to.equal(false)
			expect(ECSMain.IsEntityVisible(LocalPropReg)).to.equal(false)
			expect(ECSMain.CanEntityCollide(RemotePropReg)).to.equal(true)
			expect(ECSMain.IsEntityVisible(RemotePropReg)).to.equal(true)

			-- Raycasting from inside the local player's position forward (-Z) must skip the local player and hit RemoteRival
			const HitId, HitObj = BVH.Raycast(
				TestStorage,
				Vector3.new(0, 10, 0),
				Vector3.new(0, 0, -1),
				50,
				nil
			)
			expect(HitId).to.equal(RemoteSlot)
			expect(HitObj).to.equal(RemoteRecord)

			-- Third-person sync: local player becomes visible for rendering while staying non-collidable
			PlayerController.SyncLocalPlayerEntity(true, 4, 12, -6, 0, -1, TestStorage, 501)
			const ThirdPersonPropReg = buffer.readu32(PropsBuf, (LocalSlot - 1) * PROPERTIES_STRIDE)
			expect(ECSMain.CanEntityCollide(ThirdPersonPropReg)).to.equal(false)
			expect(ECSMain.IsEntityVisible(ThirdPersonPropReg)).to.equal(true)

			PlayerController.ResetRegistryForTest(TestStorage)
		end)
	end)
end
