local RenderConfigs = {}

local PART_TRIANGLES = {
	{ 1, 3, 2 },
	{ 1, 4, 3 }, -- Back
	{ 5, 6, 7 },
	{ 5, 7, 8 }, -- Front
	{ 1, 2, 6 },
	{ 1, 6, 5 }, -- Bottom
	{ 3, 4, 8 },
	{ 3, 8, 7 }, -- Top
	{ 1, 5, 8 },
	{ 1, 8, 4 }, -- Left
	{ 2, 3, 7 },
	{ 2, 7, 6 }, -- Right
}

function RenderConfigs.GetPartTriangles()
	return PART_TRIANGLES
end

return RenderConfigs
