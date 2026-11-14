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

	const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
	const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))

	const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number

	describe("1. ECS Property Packing & Bit Extraction", function()
		it("should pack and extract boolean flags and dynamic IDs accurately", function()
			const Register = ECSMain.PackProperties(true, false, true, 42)

			expect(ECSMain.CanEntityCollide(Register)).to.equal(true)
			expect(ECSMain.IsEntityVisible(Register)).to.equal(false)
			expect(ECSMain.IsEntityAnchored(Register)).to.equal(true)
			expect(ECSMain.HasEntityDynamicId(Register)).to.equal(true)
			expect(ECSMain.GetEntityDynamicId(Register)).to.equal(42)
		end)

		it("should clamp dynamic IDs exceeding capacity and handle zero correctly", function()
			const RegZero = ECSMain.PackProperties(false, false, false, 0)
			expect(ECSMain.HasEntityDynamicId(RegZero)).to.equal(false)
			expect(ECSMain.GetEntityDynamicId(RegZero)).to.equal(0)
		end)

		it("should pack, extract, and update TextureId without clobbering flags or DynamicId", function()
			const Register = ECSMain.PackProperties(true, true, false, 42, 2)
			expect(ECSMain.CanEntityCollide(Register)).to.equal(true)
			expect(ECSMain.IsEntityVisible(Register)).to.equal(true)
			expect(ECSMain.IsEntityAnchored(Register)).to.equal(false)
			expect(ECSMain.GetEntityDynamicId(Register)).to.equal(42)
			expect(ECSMain.GetEntityTextureId(Register)).to.equal(2)

			const Storage = ECSMain.CreateStorage(true)
			const EntityId = Storage.ECSData.RegisterEntity(true)
			const PropsBuf = Storage.PropertiesData.GetData()
			Storage.PropertiesData.CreateLayout(0, true, false, true, 77, 1)

			ECSMain.SetEntityTextureId(PropsBuf, EntityId, 2)
			const UpdatedReg = buffer.readu32(PropsBuf, 0)
			expect(ECSMain.GetEntityTextureId(UpdatedReg)).to.equal(2)
			expect(ECSMain.GetEntityDynamicId(UpdatedReg)).to.equal(77)
			expect(ECSMain.CanEntityCollide(UpdatedReg)).to.equal(true)
			expect(ECSMain.IsEntityVisible(UpdatedReg)).to.equal(false)
			expect(ECSMain.IsEntityAnchored(UpdatedReg)).to.equal(true)

			-- Updating DynamicId must also preserve TextureId
			ECSMain.SetEntityDynamicId(PropsBuf, EntityId, 123)
			const AfterDynReg = buffer.readu32(PropsBuf, 0)
			expect(ECSMain.GetEntityTextureId(AfterDynReg)).to.equal(2)
			expect(ECSMain.GetEntityDynamicId(AfterDynReg)).to.equal(123)
		end)
	end)

	describe("2. ECS Entity Lifecycle & O(1) Swap-Pop Deletion", function()
		it("should register sequential entity IDs across synchronized counts", function()
			const Storage = ECSMain.CreateStorage(true)
			const Id1 = Storage.ECSData.RegisterEntity(true)
			const Id2 = Storage.ECSData.RegisterEntity(false)

			expect(Id1).to.equal(1)
			expect(Id2).to.equal(2)
			expect(Storage.ECSData.GetCounts().EntityECSCount).to.equal(2)
		end)

		it("should swap-and-pop the last entity into the deleted slot", function()
			const Storage = ECSMain.CreateStorage(true)
			const PosBuf = Storage.PositionData.GetData()

			const _Id1 = Storage.ECSData.RegisterEntity(true)
			const Id2 = Storage.ECSData.RegisterEntity(true)
			const _Id3 = Storage.ECSData.RegisterEntity(true)

			-- Write distinct X positions for each entity
			buffer.writef32(PosBuf, 0, 10)
			buffer.writef32(PosBuf, COMPONENT_STRIDE, 20)
			buffer.writef32(PosBuf, COMPONENT_STRIDE * 2, 30)

			-- Delete Id2 (middle entity)
			Storage.ECSData.DeleteEntity(Id2)

			-- Count should be 2
			expect(Storage.ECSData.GetCounts().EntityECSCount).to.equal(2)
			-- Slot 2 should now have the data of former slot 3 (X = 30)
			expect(buffer.readf32(PosBuf, COMPONENT_STRIDE)).to.equal(30)
		end)
	end)

	describe("3. Dynamic OOP Objects Registry", function()
		it("should store, retrieve, and bind OOP object instances to entities", function()
			const Storage = ECSMain.CreateStorage(true)
			const TestData = { Name = "HoverVehicle", Speed = 100 }

			const EntityId = Storage.ECSData.RegisterEntity(false)
			const DynamicId = Storage.DynamicObjectsList.AddObject(TestData, EntityId)

			expect(DynamicId > 0).to.equal(true)
			expect(Storage.DynamicObjectsList.GetObject(DynamicId)).to.equal(TestData)
			expect(Storage.DynamicObjectsList.GetObjectByEntityId(EntityId)).to.equal(TestData)
			expect(Storage.DynamicObjectsList.GetBoundEntityId(DynamicId)).to.equal(EntityId)

			-- Remove object
			Storage.DynamicObjectsList.RemoveObject(DynamicId)
			expect(Storage.DynamicObjectsList.GetObject(DynamicId)).to.equal(nil)
			expect(Storage.DynamicObjectsList.GetObjectByEntityId(EntityId)).to.equal(nil)
		end)
	end)
end
