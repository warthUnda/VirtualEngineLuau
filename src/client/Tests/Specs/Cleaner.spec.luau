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
	const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

	-- Static References --
	const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
	const RenderRoot = SharedFolder:WaitForChild("Utilities"):WaitForChild("Render")
	const SceneFolder = RenderRoot:WaitForChild("Scene")

	-- Libraries --
	const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
	const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
	const ViewCulling = require(RenderRoot:WaitForChild("Core"):WaitForChild("ViewCulling"))
	const CleanerHelper = require(SceneFolder:WaitForChild("CleanerHelper"))
	const CleanerSortHelper = require(SceneFolder:WaitForChild("CleanerSortHelper"))

	-- Configs --
	const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
	const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number

	-- Local Functions --
	local function SpawnTestPart(
		Storage: ECSMain.ECSStorage,
		Position: Vector3,
		Size: Vector3,
		IsVisible: boolean,
		ColorR: number
	): number
		const EntityId = Storage.ECSData.RegisterEntity() :: number
		const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
		const DirOffset = (EntityId - 1) * 36 :: number
		const VisOffset = (EntityId - 1) * 4 :: number
		const PropOffset = (EntityId - 1) * PROPERTIES_STRIDE :: number

		Storage.PositionData.CreateLayout(CompOffset, Position.X, Position.Y, Position.Z)
		Storage.DirectionsData.CreateLayout(DirOffset, 0, 0, -1, 0, 1, 0, 1, 0, 0)
		Storage.SizeData.CreateLayout(CompOffset, Size.X, Size.Y, Size.Z)
		Storage.VisualData.CreateLayout(VisOffset, ColorR, 100, 150)
		Storage.PropertiesData.CreateLayout(PropOffset, true, IsVisible, true, 0)
		return EntityId
	end

	describe("1. Client Scene Cleaner & Free-List Slot Recycling", function()
		it("should free render slots in place without moving other slots and recycle freed slots", function()
			const RenderStorage = ECSMain.CreateStorage(false)
			const RenderECSData = RenderStorage.ECSData
			const RenderCounts = RenderECSData.ECSDataTable

			const Slot1 = RenderECSData.RegisterEntity()
			const Slot2 = RenderECSData.RegisterEntity()
			const Slot3 = RenderECSData.RegisterEntity()

			expect(RenderCounts.ActiveEntityCount).to.equal(3)

			const RenderSlotByObjectId = buffer.create((10 + 1) * 4)
			const ObjectIdByRenderSlot = buffer.create((10 + 1) * 4)

			buffer.writeu32(RenderSlotByObjectId, 1 * 4, Slot1)
			buffer.writeu32(ObjectIdByRenderSlot, Slot1 * 4, 1)

			buffer.writeu32(RenderSlotByObjectId, 2 * 4, Slot2)
			buffer.writeu32(ObjectIdByRenderSlot, Slot2 * 4, 2)

			buffer.writeu32(RenderSlotByObjectId, 3 * 4, Slot3)
			buffer.writeu32(ObjectIdByRenderSlot, Slot3 * 4, 3)

			CleanerHelper.RemoveRenderEntity(
				RenderECSData,
				RenderCounts,
				RenderSlotByObjectId,
				ObjectIdByRenderSlot,
				1,
				Slot1
			)

			expect(RenderCounts.ActiveEntityCount).to.equal(2)
			expect(RenderECSData.IsEntityActive(Slot1)).to.equal(false)
			expect(RenderECSData.IsEntityActive(Slot3)).to.equal(true)

			-- Slot 3 remains mapped to entity 3 without moving
			expect(buffer.readu32(ObjectIdByRenderSlot, Slot3 * 4)).to.equal(3)
			expect(buffer.readu32(RenderSlotByObjectId, 3 * 4)).to.equal(Slot3)
			expect(buffer.readu32(RenderSlotByObjectId, 1 * 4)).to.equal(0)
			expect(buffer.readu32(ObjectIdByRenderSlot, Slot1 * 4)).to.equal(0)

			-- Next registration recycles Slot 1
			const RecycledSlot = RenderECSData.RegisterEntity()
			expect(RecycledSlot).to.equal(Slot1)
		end)

		it("should filter invisible entities via IsEntityVisible and reset dirty flags after sync", function()
			const SourceStorage = ECSMain.CreateStorage(false)
			const VisibleId = SourceStorage.ECSData.RegisterEntity(true)
			const InvisibleId = SourceStorage.ECSData.RegisterEntity(true)

			const PropsBuf = SourceStorage.PropertiesData.GetData()
			SourceStorage.PropertiesData.CreateLayout(0, true, true, true, 0)
			SourceStorage.PropertiesData.CreateLayout(4, true, false, true, 0)

			expect(ECSMain.IsEntityVisible(buffer.readu32(PropsBuf, 0))).to.equal(true)
			expect(ECSMain.IsEntityVisible(buffer.readu32(PropsBuf, 4))).to.equal(false)

			const DirtyFlags = SourceStorage.ECSData.GetDirtyFlags()
			expect(buffer.readu8(DirtyFlags, VisibleId - 1) > 0).to.equal(true)
			expect(buffer.readu8(DirtyFlags, InvisibleId - 1) > 0).to.equal(true)

			SourceStorage.ECSData.ClearDirty(VisibleId)
			expect(buffer.readu8(DirtyFlags, VisibleId - 1)).to.equal(0)
		end)
	end)

	describe("2. Descending Size Sorting & Culling ECS Ordering", function()
		it("should place the biggest visible part at slot 1, second biggest at slot 2, and so on", function()
			const ObjectStorage = ECSMain.CreateStorage(false)
			const RenderStorage = ECSMain.CreateStorage(false)

			const SmallId = SpawnTestPart(ObjectStorage, Vector3.new(0, 0, -35), Vector3.new(2, 2, 2), true, 10)
			const BiggestId = SpawnTestPart(ObjectStorage, Vector3.new(0, -15, -40), Vector3.new(100, 2, 100), true, 20)
			const ThirdId = SpawnTestPart(ObjectStorage, Vector3.new(-12, 4, -35), Vector3.new(10, 10, 10), true, 30)
			const SecondId = SpawnTestPart(ObjectStorage, Vector3.new(18, 6, -45), Vector3.new(30, 30, 30), true, 40)
			const InvisibleHugeId = SpawnTestPart(ObjectStorage, Vector3.new(0, 0, -30), Vector3.new(200, 200, 200), false, 50)
			const CulledBehindId = SpawnTestPart(ObjectStorage, Vector3.new(0, 0, 500), Vector3.new(60, 60, 60), true, 60)

			ViewCulling.UpdateObserverFromVectors(0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 70)
			const State = CleanerHelper.CreateCleanerState(ObjectStorage, RenderStorage)
			const VisibleCount = CleanerHelper.SyncRenderStorage(State)

			expect(VisibleCount).to.equal(4)
			expect(RenderStorage.ECSData.GetCounts().EntityECSCount).to.equal(4)
			expect(RenderStorage.ECSData.GetCounts().ActiveEntityCount).to.equal(4)

			expect(buffer.readu32(State.ObjectIdByRenderSlot, 1 * 4)).to.equal(BiggestId)
			expect(buffer.readu32(State.ObjectIdByRenderSlot, 2 * 4)).to.equal(SecondId)
			expect(buffer.readu32(State.ObjectIdByRenderSlot, 3 * 4)).to.equal(ThirdId)
			expect(buffer.readu32(State.ObjectIdByRenderSlot, 4 * 4)).to.equal(SmallId)

			expect(buffer.readu32(State.RenderSlotByObjectId, BiggestId * 4)).to.equal(1)
			expect(buffer.readu32(State.RenderSlotByObjectId, SecondId * 4)).to.equal(2)
			expect(buffer.readu32(State.RenderSlotByObjectId, ThirdId * 4)).to.equal(3)
			expect(buffer.readu32(State.RenderSlotByObjectId, SmallId * 4)).to.equal(4)
			expect(buffer.readu32(State.RenderSlotByObjectId, InvisibleHugeId * 4)).to.equal(0)
			expect(buffer.readu32(State.RenderSlotByObjectId, CulledBehindId * 4)).to.equal(0)

			const RenderSizes = RenderStorage.SizeData.GetData()
			const RenderVisuals = RenderStorage.VisualData.GetData()
			expect(buffer.readf32(RenderSizes, 0)).to.be.near(100, 1e-4)
			expect(buffer.readf32(RenderSizes, COMPONENT_STRIDE)).to.be.near(30, 1e-4)
			expect(buffer.readf32(RenderSizes, COMPONENT_STRIDE * 2)).to.be.near(10, 1e-4)
			expect(buffer.readf32(RenderSizes, COMPONENT_STRIDE * 3)).to.be.near(2, 1e-4)
			expect(buffer.readu8(RenderVisuals, 0)).to.equal(20)
			expect(buffer.readu8(RenderVisuals, 4)).to.equal(40)
			expect(buffer.readu8(RenderVisuals, 8)).to.equal(30)
			expect(buffer.readu8(RenderVisuals, 12)).to.equal(10)

			ObjectStorage.SizeData.CreateLayout((SmallId - 1) * COMPONENT_STRIDE, 150, 150, 150)
			ObjectStorage.ECSData.MarkDirty(SmallId)
			const ResortedCount = CleanerHelper.SyncRenderStorage(State)

			expect(ResortedCount).to.equal(4)
			expect(buffer.readu32(State.ObjectIdByRenderSlot, 1 * 4)).to.equal(SmallId)
			expect(buffer.readu32(State.ObjectIdByRenderSlot, 2 * 4)).to.equal(BiggestId)
			expect(buffer.readu32(State.ObjectIdByRenderSlot, 3 * 4)).to.equal(SecondId)
			expect(buffer.readu32(State.ObjectIdByRenderSlot, 4 * 4)).to.equal(ThirdId)
			expect(buffer.readf32(RenderSizes, 0)).to.be.near(150, 1e-4)
			expect(buffer.readu32(State.RenderSlotByObjectId, SmallId * 4)).to.equal(1)
			expect(buffer.readu32(State.RenderSlotByObjectId, ThirdId * 4)).to.equal(4)

			ObjectStorage.ECSData.DeleteEntity(SmallId)
			const ShrunkCount = CleanerHelper.SyncRenderStorage(State)
			expect(ShrunkCount).to.equal(3)
			expect(RenderStorage.ECSData.GetCounts().EntityECSCount).to.equal(3)
			expect(buffer.readu32(State.RenderSlotByObjectId, SmallId * 4)).to.equal(0)
			expect(buffer.readu32(State.ObjectIdByRenderSlot, 1 * 4)).to.equal(BiggestId)
			expect(buffer.readu32(State.ObjectIdByRenderSlot, 4 * 4)).to.equal(0)

			ViewCulling.UpdateObserverFromVectors(0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 70)
		end)

		it("should sort large mixed and equal-size batches deterministically including 2D planes", function()
			const Count = 128 :: number
			const SizesBuffer = buffer.create(Count * 4)
			const IdsBuffer = buffer.create(Count * 4)
			const StackBuffer = buffer.create(64 * 8)

			for idx = 0, Count - 1 do
				const FakeSizes = buffer.create(12)
				const Group = idx % 8 :: number
				if Group == 0 then
					buffer.writef32(FakeSizes, 0, 80)
					buffer.writef32(FakeSizes, 4, 0)
					buffer.writef32(FakeSizes, 8, 80)
				else
					const Side = ((idx * 37) % 25) + 1 :: number
					buffer.writef32(FakeSizes, 0, Side)
					buffer.writef32(FakeSizes, 4, Side)
					buffer.writef32(FakeSizes, 8, Side)
				end
				buffer.writef32(SizesBuffer, idx * 4, CleanerSortHelper.ComputeEntitySizeScore(FakeSizes, 0))
				buffer.writeu32(IdsBuffer, idx * 4, idx + 1)
			end

			CleanerSortHelper.SortDescendingBySize(SizesBuffer, IdsBuffer, Count, StackBuffer)

			for idx = 0, Count - 2 do
				const SizeA = buffer.readf32(SizesBuffer, idx * 4) :: number
				const IdA = buffer.readu32(IdsBuffer, idx * 4) :: number
				const SizeB = buffer.readf32(SizesBuffer, (idx + 1) * 4) :: number
				const IdB = buffer.readu32(IdsBuffer, (idx + 1) * 4) :: number
				const IsOrdered = (SizeA > SizeB or (SizeA == SizeB and IdA < IdB)) :: boolean
				expect(IsOrdered).to.equal(true)
			end
			expect(buffer.readf32(SizesBuffer, 0)).to.be.near(6400, 1e-2)
			expect(buffer.readu32(IdsBuffer, 0)).to.equal(1)
		end)
	end)
end
