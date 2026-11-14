--!strict
--!native
--!optimize 2

local BVHConfig = {}

BVHConfig.BVHStackCapacity = 64 :: number
-- Maximum depth of the iterative BVH traversal stack for raycasting and spatial queries.

BVHConfig.BVHMaxLeafEntities = 1 :: number
-- Maximum number of entities grouped into a single BVH leaf node during tree construction.

BVHConfig.BVHMutationScanBudget = 256 :: number
-- Number of static entities scanned per query to detect silent buffer mutations without full-array scans.

return BVHConfig
