--!strict
--!native
--!optimize 2

-- Tables --
local CleanerHelper = {}

-- Functions --
-- ============================================================================
-- 1. RENDER ENTITY FREE-LIST SLOT REMOVAL HELPER
-- ============================================================================

--[=[
	Frees a despawned or culled entity's render slot in place without moving any other render slots.
	@param RenderECSData any -- Render ECS data component interface.
	@param _RenderCounts any -- Render entity count table (unused under stable free-list slots).
	@param RenderSlotByObjectId buffer -- Mapping buffer from ObjectId to RenderSlot.
	@param ObjectIdByRenderSlot buffer -- Mapping buffer from RenderSlot to ObjectId.
	@param ObjectId number -- Client ObjectStorage entity ID being evicted from render storage.
	@param RenderSlot number -- Active client render slot being vacated.
]=]
function CleanerHelper.RemoveRenderEntity(
	RenderECSData: any,
	_RenderCounts: any,
	RenderSlotByObjectId: buffer,
	ObjectIdByRenderSlot: buffer,
	ObjectId: number,
	RenderSlot: number
)
	buffer.writeu32(RenderSlotByObjectId, ObjectId * 4, 0)
	buffer.writeu32(ObjectIdByRenderSlot, RenderSlot * 4, 0)
	RenderECSData.DeleteEntity(RenderSlot)
end

return CleanerHelper
