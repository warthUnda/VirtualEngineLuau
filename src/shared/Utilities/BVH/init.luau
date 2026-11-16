--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))
const BVHState = require(script.BVHState)
const BVHRaycast = require(script.BVHRaycast)
const BVHQuery = require(script.BVHQuery)

-- Tables --
local BVH = {
	Rebuild = BVHState.Rebuild,
	Raycast = BVHRaycast.Raycast,
	QueryAABB = BVHQuery.QueryAABB,
	QueryAABBScalar = BVHQuery.QueryAABBScalar,
}

-- Functions --

-- ============================================================================
-- 1. UNIFIED BVH SPATIAL ACCELERATION FACADE
-- ============================================================================

--[=[
	Ensures the BVH is up-to-date for the current frame/substep so batched queries can pass SkipNeedsRebuild = true.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional ECSStorage override.
]=]
function BVH.EnsureFresh(ProvidedStorage: ECSMain.ECSStorage?)
	BVHState.EnsureFreshAndResolve(ProvidedStorage, false)
end

setmetatable(BVH, {
	__call = function(_, ...: any)
		return BVHRaycast.Raycast(...)
	end,
})

return BVH
