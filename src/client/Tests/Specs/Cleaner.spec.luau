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
	const CleanerHelper = require(
		SharedFolder:WaitForChild("Utilities")
			:WaitForChild("Render")
			:WaitForChild("Scene")
			:WaitForChild("CleanerHelper")
	)

	describe("1. Client Scene Cleaner & Slot Compaction", function()
		it("should remove entities from render storage and update bidirectional slot maps", function()
			const RenderStorage = ECSMain.CreateStorage(false)
			const RenderECSData = RenderStorage.ECSData
			const RenderCounts = RenderECSData.ECSDataTable

			-- Register 3 render slots
			const Slot1 = RenderECSData.RegisterEntity()
			const Slot2 = RenderECSData.RegisterEntity()
			const Slot3 = RenderECSData.RegisterEntity()

			expect(RenderCounts.EntityECSCount).to.equal(3)

			-- Set up bidirectional lookup buffers for 10 entities
			const RenderSlotByObjectId = buffer.create((10 + 1) * 4)
			const ObjectIdByRenderSlot = buffer.create((10 + 1) * 4)

			-- Map Server ObjectId 101 -> Slot 1, 102 -> Slot 2, 103 -> Slot 3
			buffer.writeu32(RenderSlotByObjectId, 1 * 4, Slot1)
			buffer.writeu32(ObjectIdByRenderSlot, Slot1 * 4, 1)

			buffer.writeu32(RenderSlotByObjectId, 2 * 4, Slot2)
			buffer.writeu32(ObjectIdByRenderSlot, Slot2 * 4, 2)

			buffer.writeu32(RenderSlotByObjectId, 3 * 4, Slot3)
			buffer.writeu32(ObjectIdByRenderSlot, Slot3 * 4, 3)

			-- Despawn entity 1 (currently in Slot 1)
			CleanerHelper.RemoveRenderEntity(
				RenderECSData,
				RenderCounts,
				RenderSlotByObjectId,
				ObjectIdByRenderSlot,
				1,
				Slot1
			)

			-- Total render count must now be 2
			expect(RenderCounts.EntityECSCount).to.equal(2)

			-- Slot 1 should now be occupied by former entity 3
			expect(buffer.readu32(ObjectIdByRenderSlot, Slot1 * 4)).to.equal(3)
			expect(buffer.readu32(RenderSlotByObjectId, 3 * 4)).to.equal(Slot1)

			-- Despawned entity 1 and vacated slot 3 must be zeroed
			expect(buffer.readu32(RenderSlotByObjectId, 1 * 4)).to.equal(0)
			expect(buffer.readu32(ObjectIdByRenderSlot, Slot3 * 4)).to.equal(0)
		end)
	end)
end
