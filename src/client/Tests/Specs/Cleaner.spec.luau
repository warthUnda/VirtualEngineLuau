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

	-- Libraries --
	const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
	const CleanerHelper = require(
		SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Scene"):WaitForChild("CleanerHelper")
	)

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
end
