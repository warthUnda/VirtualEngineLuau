--!native
--!optimize 2

-- Configs --
const WIDTH = 600 :: number
const HEIGHT = 600 :: number
const ACTOR_COUNT = 3 :: number

-- Tables --
const PART_TRIANGLES = { -- 12 times 3 = 36 bytes
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
} :: { { number } }

-- Buffers
const PartTrianglesBuffer = buffer.create(12 * 3) :: buffer

local MemoryOffset = 0 :: number

for i = 1, 12 do
	const Tri = PART_TRIANGLES[i] :: { number }
	buffer.writeu8(PartTrianglesBuffer, MemoryOffset, Tri[1])
	MemoryOffset += 1
	buffer.writeu8(PartTrianglesBuffer, MemoryOffset, Tri[2])
	MemoryOffset += 1
	buffer.writeu8(PartTrianglesBuffer, MemoryOffset, Tri[3])
	MemoryOffset += 1
end

local RenderConfigs = {}

function RenderConfigs.GetActorCount(): number
	return ACTOR_COUNT
end

function RenderConfigs.GetPartTriangles(): buffer
	return PartTrianglesBuffer
end

function RenderConfigs.GetDimensions2D(): (number, number)
	return WIDTH, HEIGHT
end

return RenderConfigs
