--!strict
--!native
--!optimize 2

local CleanerHelper = {}

-- ============================================================================
-- 1. RENDER ENTITY SLOT REMOVAL HELPER
-- ============================================================================

--[=[
	Deletes a despawned entity from the active render ECS storage and updates the bidirectional slot mapping.
	@param RenderECSData any -- Render ECS data component interface.
	@param RenderCounts any -- Active render entity count table.
	@param RenderSlotByObjectId buffer -- Mapping buffer from ObjectId to RenderSlot.
	@param ObjectIdByRenderSlot buffer -- Mapping buffer from RenderSlot to ObjectId.
	@param ObjectId number -- Server object ID being removed.
	@param RenderSlot number -- Active client render slot being vacated.
]=]
function CleanerHelper.RemoveRenderEntity(
	RenderECSData: any,
	RenderCounts: any,
	RenderSlotByObjectId: buffer,
	ObjectIdByRenderSlot: buffer,
	ObjectId: number,
	RenderSlot: number
)
	const LastRenderSlot = RenderCounts.EntityECSCount :: number
	const LastObjectId = buffer.readu32(ObjectIdByRenderSlot, LastRenderSlot * 4) :: number

	RenderECSData.DeleteEntity(RenderSlot)

	if RenderSlot ~= LastRenderSlot and LastObjectId > 0 then
		buffer.writeu32(RenderSlotByObjectId, LastObjectId * 4, RenderSlot)
		buffer.writeu32(ObjectIdByRenderSlot, RenderSlot * 4, LastObjectId)
	end

	buffer.writeu32(RenderSlotByObjectId, ObjectId * 4, 0)
	buffer.writeu32(ObjectIdByRenderSlot, LastRenderSlot * 4, 0)
end

return CleanerHelper
