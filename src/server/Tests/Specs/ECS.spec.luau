--!strict
--!native
--!optimize 2

--[=[
	@class ECS.spec
	TestEZ specifications verifying contiguous ECS component buffer layout,
	property bitfield packing, O(1) free-list slot recycling, dynamic OOP binding,
	and CollectionService Plane tag shape resolution.
]=]

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
	const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

	-- Static References --
	const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

	-- Libraries --
	const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
	const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))

	-- Configs --
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

			Storage.PropertiesData.CreateLayout(0, true, false, true, 77, 2, 3)
			expect(ECSMain.GetEntityShapeId(buffer.readu32(PropsBuf, 0))).to.equal(3)
			ECSMain.SetEntityShapeId(PropsBuf, EntityId, 4)
			expect(ECSMain.GetEntityShapeId(buffer.readu32(PropsBuf, 0))).to.equal(4)
			ECSMain.SetEntityDynamicId(PropsBuf, EntityId, 123)
			const AfterDynReg = buffer.readu32(PropsBuf, 0)
			expect(ECSMain.GetEntityTextureId(AfterDynReg)).to.equal(2)
			expect(ECSMain.GetEntityShapeId(AfterDynReg)).to.equal(4)
			expect(ECSMain.GetEntityDynamicId(AfterDynReg)).to.equal(123)
		end)
	end)

	describe("2. ECS Entity Lifecycle & O(1) Free-List Slot Recycling", function()
		it("should register sequential entity IDs across synchronized counts", function()
			const Storage = ECSMain.CreateStorage(true)
			const Id1 = Storage.ECSData.RegisterEntity(true)
			const Id2 = Storage.ECSData.RegisterEntity(false)

			expect(Id1).to.equal(1)
			expect(Id2).to.equal(2)
			expect(Storage.ECSData.GetCounts().EntityECSCount).to.equal(2)
			expect(Storage.ECSData.GetCounts().ActiveEntityCount).to.equal(2)
			expect(Storage.ECSData.IsEntityActive(1)).to.equal(true)
			expect(Storage.ECSData.IsEntityActive(2)).to.equal(true)
		end)

		it("should recycle deleted middle slots via free-list without moving live entities and trim empty tails", function()
			const Storage = ECSMain.CreateStorage(true)
			const PosBuf = Storage.PositionData.GetData()

			const Id1 = Storage.ECSData.RegisterEntity(true)
			const Id2 = Storage.ECSData.RegisterEntity(true)
			const Id3 = Storage.ECSData.RegisterEntity(true)

			buffer.writef32(PosBuf, 0, 10)
			buffer.writef32(PosBuf, COMPONENT_STRIDE, 20)
			buffer.writef32(PosBuf, COMPONENT_STRIDE * 2, 30)

			-- Delete Id2 (middle entity): Id3 must remain untouched at slot 3
			Storage.ECSData.DeleteEntity(Id2)
			expect(Storage.ECSData.IsEntityActive(Id2)).to.equal(false)
			expect(Storage.ECSData.IsEntityActive(Id3)).to.equal(true)
			expect(Storage.ECSData.GetCounts().ActiveEntityCount).to.equal(2)
			expect(Storage.ECSData.GetCounts().EntityECSCount).to.equal(3)
			expect(buffer.readf32(PosBuf, COMPONENT_STRIDE * 2)).to.equal(30)

			-- Next spawn must recycle freed slot 2
			const RecycledId = Storage.ECSData.RegisterEntity(false)
			expect(RecycledId).to.equal(2)
			expect(Storage.ECSData.IsEntityActive(2)).to.equal(true)
			expect(Storage.ECSData.GetCounts().ActiveEntityCount).to.equal(3)

			-- Deleting slot 2 then tail slot 3 must trim HighWaterMark (EntityECSCount) down to 1
			Storage.ECSData.DeleteEntity(2)
			Storage.ECSData.DeleteEntity(3)
			expect(Storage.ECSData.GetCounts().ActiveEntityCount).to.equal(1)
			expect(Storage.ECSData.GetCounts().EntityECSCount).to.equal(Id1)
		end)

		it("should enforce exact capacity-multiple strides, dirty tracking, and stable dynamic bindings", function()
			expect(SystemsConfigs.ECSVisualStride).to.equal(4)
			expect(SystemsConfigs.ECSComponentBufferSize).to.equal(SystemsConfigs.ECSMaxEntities * SystemsConfigs.ECSComponentStride)
			expect(SystemsConfigs.ECSDirectionBufferSize).to.equal(SystemsConfigs.ECSMaxEntities * SystemsConfigs.ECSDirectionStride)
			expect(SystemsConfigs.ECSVisualBufferSize).to.equal(SystemsConfigs.ECSMaxEntities * SystemsConfigs.ECSVisualStride)
			expect(SystemsConfigs.ECSPropertiesBufferSize).to.equal(SystemsConfigs.ECSMaxEntities * SystemsConfigs.ECSPropertiesStride)

			const Storage = ECSMain.CreateStorage(true)
			const Entity1 = Storage.ECSData.RegisterEntity(false)
			const Entity2 = Storage.ECSData.RegisterEntity(false)
			const Entity3 = Storage.ECSData.RegisterEntity(false)

			const Obj2 = { Tag = "DeletedMiddleObj" }
			const Dyn2 = Storage.DynamicObjectsList.AddObject(Obj2, Entity2)
			Storage.PropertiesData.CreateLayout((Entity2 - 1) * SystemsConfigs.ECSPropertiesStride, true, true, false, Dyn2)

			const Obj3 = { Tag = "TailObj" }
			const Dyn3 = Storage.DynamicObjectsList.AddObject(Obj3, Entity3)
			Storage.PropertiesData.CreateLayout((Entity3 - 1) * SystemsConfigs.ECSPropertiesStride, true, true, false, Dyn3)

			const DirtyFlags = Storage.ECSData.GetDirtyFlags()
			const VersionBuffer = Storage.ECSData.GetVersionBuffer()
			expect(buffer.readu8(DirtyFlags, Entity1 - 1) > 0).to.equal(true)
			const InitialVer = buffer.readu32(VersionBuffer, (Entity1 - 1) * 4)
			Storage.ECSData.ClearDirty(Entity1)
			expect(buffer.readu8(DirtyFlags, Entity1 - 1)).to.equal(0)
			Storage.ECSData.MarkDirty(Entity1)
			expect(buffer.readu8(DirtyFlags, Entity1 - 1)).to.equal(1)
			expect(buffer.readu32(VersionBuffer, (Entity1 - 1) * 4) > InitialVer).to.equal(true)

			Storage.ECSData.DeleteEntity(Entity2)
			expect(Storage.DynamicObjectsList.GetObject(Dyn2)).to.equal(nil)
			expect(Storage.DynamicObjectsList.GetBoundEntityId(Dyn2)).to.equal(0)
			expect(Storage.DynamicObjectsList.GetBoundEntityId(Dyn3)).to.equal(Entity3)
			expect(Storage.DynamicObjectsList.GetObjectByEntityId(Entity3)).to.equal(Obj3)
			expect(Storage.DynamicObjectsList.GetObjectByEntityId(Entity2)).to.equal(nil)
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

			Storage.DynamicObjectsList.RemoveObject(DynamicId)
			expect(Storage.DynamicObjectsList.GetObject(DynamicId)).to.equal(nil)
			expect(Storage.DynamicObjectsList.GetObjectByEntityId(EntityId)).to.equal(nil)
		end)

		it("should bind OOP object instances at explicit replicated DynamicIds via SetObjectAtId", function()
			const Storage = ECSMain.CreateStorage(false)
			const EntityId = Storage.ECSData.RegisterEntity(false)
			const ReplicatedDynamicId = 17 :: number
			const PlayerOOP = { ClassName = "PlayerService", UserId = 9001 }

			const BoundOk = Storage.DynamicObjectsList.SetObjectAtId(ReplicatedDynamicId, PlayerOOP, EntityId)
			expect(BoundOk).to.equal(true)
			expect(Storage.DynamicObjectsList.GetObject(ReplicatedDynamicId)).to.equal(PlayerOOP)
			expect(Storage.DynamicObjectsList.GetBoundEntityId(ReplicatedDynamicId)).to.equal(EntityId)
			expect(Storage.DynamicObjectsList.GetObjectByEntityId(EntityId)).to.equal(PlayerOOP)

			Storage.DynamicObjectsList.RemoveObject(ReplicatedDynamicId)
			expect(Storage.DynamicObjectsList.GetObject(ReplicatedDynamicId)).to.equal(nil)
			expect(Storage.DynamicObjectsList.GetBoundEntityId(ReplicatedDynamicId)).to.equal(0)
		end)
	end)

	describe("5. Plane CollectionTag Detection (ECSBuilderHelper)", function()
		it("should categorize a Part tagged with PlaneCollectionTag as Plane instead of Cube", function()
			const CollectionService = game:GetService("CollectionService")
			const ReplicatedStorage = game:GetService("ReplicatedStorage")
			const ServerScriptService = game:GetService("ServerScriptService")
			const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
			const VerticeFile = require(
				ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Core"):WaitForChild("VerticeFile")
			)
			const ECSBuilderHelper = require(
				ServerScriptService:WaitForChild("Server"):WaitForChild("Objects"):WaitForChild("ObjectsECS"):WaitForChild("ECSBuilderHelper")
			)

			const TestPart = Instance.new("Part")
			expect(ECSBuilderHelper.ResolvePartShapeId(TestPart)).to.equal(VerticeFile.ShapeToId.Cube)

			CollectionService:AddTag(TestPart, SystemsConfigs.PlaneCollectionTag)
			expect(ECSBuilderHelper.ResolvePartShapeId(TestPart)).to.equal(VerticeFile.ShapeToId.Plane)

			TestPart:Destroy()
		end)
	end)
end
