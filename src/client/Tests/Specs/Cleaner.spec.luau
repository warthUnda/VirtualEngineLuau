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

	describe("2. BVH Frustum Culling & Front-to-Back Ascending Depth Ordering", function()
		it("should cull via BVH including non-collidable visible parts and sort strictly front-to-back", function()
			const ObjectStorage = ECSMain.CreateStorage(false)
			const RenderStorage = ECSMain.CreateStorage(false)

			const FarId = SpawnTestPart(ObjectStorage, Vector3.new(0, 0, -90), Vector3.new(20, 20, 20), true, 10)
			const NearId = SpawnTestPart(ObjectStorage, Vector3.new(0, 0, -15), Vector3.new(4, 4, 4), true, 20)
			const MidId = SpawnTestPart(ObjectStorage, Vector3.new(-10, 4, -40), Vector3.new(10, 10, 10), true, 30)
			const NonCollidableId = SpawnTestPart(ObjectStorage, Vector3.new(12, 2, -60), Vector3.new(6, 6, 6), true, 40)
			ObjectStorage.PropertiesData.CreateLayout((NonCollidableId - 1) * PROPERTIES_STRIDE, false, true, true, 0)
			const InvisibleNearId = SpawnTestPart(ObjectStorage, Vector3.new(0, 0, -10), Vector3.new(200, 200, 200), false, 50)
			const CulledBehindId = SpawnTestPart(ObjectStorage, Vector3.new(0, 0, 500), Vector3.new(60, 60, 60), true, 60)

			ViewCulling.UpdateObserverFromVectors(0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 70)
			const State = CleanerHelper.CreateCleanerState(ObjectStorage, RenderStorage)
			const VisibleCount = CleanerHelper.SyncRenderStorage(State)

			expect(VisibleCount).to.equal(4)
			expect(RenderStorage.ECSData.GetCounts().EntityECSCount).to.equal(4)
			expect(RenderStorage.ECSData.GetCounts().ActiveEntityCount).to.equal(4)

			expect(buffer.readu32(State.ObjectIdByRenderSlot, 1 * 4)).to.equal(NearId)
			expect(buffer.readu32(State.ObjectIdByRenderSlot, 2 * 4)).to.equal(MidId)
			expect(buffer.readu32(State.ObjectIdByRenderSlot, 3 * 4)).to.equal(NonCollidableId)
			expect(buffer.readu32(State.ObjectIdByRenderSlot, 4 * 4)).to.equal(FarId)

			expect(buffer.readu32(State.RenderSlotByObjectId, NearId * 4)).to.equal(1)
			expect(buffer.readu32(State.RenderSlotByObjectId, MidId * 4)).to.equal(2)
			expect(buffer.readu32(State.RenderSlotByObjectId, NonCollidableId * 4)).to.equal(3)
			expect(buffer.readu32(State.RenderSlotByObjectId, FarId * 4)).to.equal(4)
			expect(buffer.readu32(State.RenderSlotByObjectId, InvisibleNearId * 4)).to.equal(0)
			expect(buffer.readu32(State.RenderSlotByObjectId, CulledBehindId * 4)).to.equal(0)

			const RenderVisuals = RenderStorage.VisualData.GetData()
			expect(buffer.readu8(RenderVisuals, 0)).to.equal(20)
			expect(buffer.readu8(RenderVisuals, 4)).to.equal(30)
			expect(buffer.readu8(RenderVisuals, 8)).to.equal(40)
			expect(buffer.readu8(RenderVisuals, 12)).to.equal(10)

			-- Move FarId closer to camera (off-axis so it does not occlude NearId behind it) and verify front-to-back resort
			ObjectStorage.PositionData.CreateLayout((FarId - 1) * COMPONENT_STRIDE, -8, 0, -14)
			ObjectStorage.SizeData.CreateLayout((FarId - 1) * COMPONENT_STRIDE, 4, 4, 4)
			ObjectStorage.ECSData.MarkDirty(FarId)
			const ResortedCount = CleanerHelper.SyncRenderStorage(State)

			expect(ResortedCount).to.equal(4)
			expect(buffer.readu32(State.ObjectIdByRenderSlot, 1 * 4)).to.equal(FarId)
			expect(buffer.readu32(State.ObjectIdByRenderSlot, 2 * 4)).to.equal(NearId)
			expect(buffer.readu32(State.RenderSlotByObjectId, FarId * 4)).to.equal(1)

			ObjectStorage.ECSData.DeleteEntity(FarId)
			const ShrunkCount = CleanerHelper.SyncRenderStorage(State)
			expect(ShrunkCount).to.equal(3)
			expect(RenderStorage.ECSData.GetCounts().EntityECSCount).to.equal(3)
			expect(buffer.readu32(State.RenderSlotByObjectId, FarId * 4)).to.equal(0)
			expect(buffer.readu32(State.ObjectIdByRenderSlot, 1 * 4)).to.equal(NearId)
			expect(buffer.readu32(State.ObjectIdByRenderSlot, 4 * 4)).to.equal(0)

			ViewCulling.UpdateObserverFromVectors(0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 70)
		end)

		it("should sort large mixed and equal-depth batches deterministically ascending front-to-back", function()
			const Count = 128 :: number
			const DepthsBuffer = buffer.create(Count * 4)
			const IdsBuffer = buffer.create(Count * 4)
			const StackBuffer = buffer.create(64 * 8)

			for idx = 0, Count - 1 do
				const DepthVal = ((idx * 37) % 25) - 5.5 :: number
				buffer.writef32(DepthsBuffer, idx * 4, DepthVal)
				buffer.writeu32(IdsBuffer, idx * 4, idx + 1)
			end

			CleanerSortHelper.SortAscendingByDepth(DepthsBuffer, IdsBuffer, Count, StackBuffer)

			for idx = 0, Count - 2 do
				const DepthA = buffer.readf32(DepthsBuffer, idx * 4) :: number
				const IdA = buffer.readu32(IdsBuffer, idx * 4) :: number
				const DepthB = buffer.readf32(DepthsBuffer, (idx + 1) * 4) :: number
				const IdB = buffer.readu32(IdsBuffer, (idx + 1) * 4) :: number
				const IsOrdered = (DepthA < DepthB or (DepthA == DepthB and IdA < IdB)) :: boolean
				expect(IsOrdered).to.equal(true)
			end
			expect(buffer.readf32(DepthsBuffer, 0)).to.be.near(-5.5, 1e-3)
			expect(buffer.readu32(IdsBuffer, 0)).to.equal(1)
		end)
	end)
end
