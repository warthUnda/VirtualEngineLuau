local HeightmapImporterService = game:GetService("HeightmapImporterService")
local RenderConfigs = {}

local WIDTH = 65 :: number
local HEIGHT = 65 :: number

local ActorNumbers = 3 :: number

local PART_TRIANGLES = { --12 times 3 = 36 bytes
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

local PART_TRIANGLES_BUFFER = buffer.create(12 * 3 * 4) :: buffer
local MemoryOffset = 0

for i = 1, 12 do
	local Tri = PART_TRIANGLES[i]
	local V0 = Tri[1]
	local V1 = Tri[2]
	local V2 = Tri[3]

	buffer.writeu8(PART_TRIANGLES_BUFFER, MemoryOffset, V0)
	MemoryOffset += 1
	buffer.writeu8(PART_TRIANGLES_BUFFER, MemoryOffset, V1)
	MemoryOffset += 1
	buffer.writeu8(PART_TRIANGLES_BUFFER, MemoryOffset, V2)
	MemoryOffset += 1
end

local SphereVertices = {
	Vector3.new(0.0000, 0.0000, 1.0000),
	Vector3.new(0.0000, 0.0000, -1.0000),
	Vector3.new(0.7071, 0.0000, 0.7071),
	Vector3.new(-0.7071, 0.0000, 0.7071),
	Vector3.new(0.0000, 0.7071, 0.7071),
	Vector3.new(0.0000, -0.7071, 0.7071),
	Vector3.new(0.7071, 0.0000, -0.7071),
	Vector3.new(-0.7071, 0.0000, -0.7071),
	Vector3.new(0.0000, 0.7071, -0.7071),
	Vector3.new(0.0000, -0.7071, -0.7071),
	Vector3.new(0.7071, 0.7071, 0.0000),
	Vector3.new(-0.7071, 0.7071, 0.0000),
	Vector3.new(0.7071, -0.7071, 0.0000),
	Vector3.new(-0.7071, -0.7071, 0.0000),
	Vector3.new(0.3827, 0.0000, 0.9239),
	Vector3.new(-0.3827, 0.0000, 0.9239),
	Vector3.new(0.0000, 0.3827, 0.9239),
	Vector3.new(0.0000, -0.3827, 0.9239),
	Vector3.new(0.9239, 0.0000, 0.3827),
	Vector3.new(-0.9239, 0.0000, 0.3827),
	Vector3.new(0.0000, 0.9239, 0.3827),
	Vector3.new(0.0000, -0.9239, 0.3827),
	Vector3.new(0.3827, 0.0000, -0.9239),
	Vector3.new(-0.3827, 0.0000, -0.9239),
	Vector3.new(0.0000, 0.3827, -0.9239),
	Vector3.new(0.0000, -0.3827, -0.9239),
	Vector3.new(0.9239, 0.0000, -0.3827),
	Vector3.new(-0.9239, 0.0000, -0.3827),
	Vector3.new(0.0000, 0.9239, -0.3827),
	Vector3.new(0.0000, -0.9239, -0.3827),
	Vector3.new(0.5000, 0.5000, 0.7071),
	Vector3.new(-0.5000, 0.5000, 0.7071),
	Vector3.new(0.5000, -0.5000, 0.7071),
	Vector3.new(-0.5000, -0.5000, 0.7071),
	Vector3.new(0.5000, 0.5000, -0.7071),
	Vector3.new(-0.5000, 0.5000, -0.7071),
	Vector3.new(0.5000, -0.5000, -0.7071),
	Vector3.new(-0.5000, -0.5000, -0.7071),
	Vector3.new(0.7071, 0.5000, 0.5000),
	Vector3.new(-0.7071, 0.5000, 0.5000),
	Vector3.new(0.7071, -0.5000, 0.5000),
	Vector3.new(-0.7071, -0.5000, 0.5000),
	Vector3.new(0.7071, 0.5000, -0.5000),
	Vector3.new(-0.7071, 0.5000, -0.5000),
	Vector3.new(0.7071, -0.5000, -0.5000),
	Vector3.new(-0.7071, -0.5000, -0.5000),
	Vector3.new(0.5000, 0.7071, 0.5000),
	Vector3.new(-0.5000, 0.7071, 0.5000),
	Vector3.new(0.5000, -0.7071, 0.5000),
	Vector3.new(-0.5000, -0.7071, 0.5000),
	Vector3.new(0.5000, 0.7071, -0.5000),
	Vector3.new(-0.5000, 0.7071, -0.5000),
	Vector3.new(0.5000, -0.7071, -0.5000),
	Vector3.new(-0.5000, -0.7071, -0.5000),
	Vector3.new(0.3090, 0.3090, 0.8944),
	Vector3.new(-0.3090, 0.3090, 0.8944),
	Vector3.new(0.3090, -0.3090, 0.8944),
	Vector3.new(-0.3090, -0.3090, 0.8944),
	Vector3.new(0.8944, 0.3090, 0.3090),
	Vector3.new(-0.8944, 0.3090, 0.3090),
	Vector3.new(0.8944, -0.3090, 0.3090),
	Vector3.new(-0.8944, -0.3090, 0.3090),
	Vector3.new(0.3090, 0.8944, 0.3090),
	Vector3.new(-0.3090, 0.8944, 0.3090),
	Vector3.new(0.3090, -0.8944, 0.3090),
	Vector3.new(-0.3090, -0.8944, 0.3090),
	Vector3.new(0.3090, 0.3090, -0.8944),
	Vector3.new(-0.3090, 0.3090, -0.8944),
	Vector3.new(0.3090, -0.3090, -0.8944),
	Vector3.new(-0.3090, -0.3090, -0.8944),
	Vector3.new(0.8944, 0.3090, -0.3090),
	Vector3.new(-0.8944, 0.3090, -0.3090),
	Vector3.new(0.8944, -0.3090, -0.3090),
	Vector3.new(-0.8944, -0.3090, -0.3090),
	Vector3.new(0.3090, 0.8944, -0.3090),
	Vector3.new(-0.3090, 0.8944, -0.3090),
	Vector3.new(0.3090, -0.8944, -0.3090),
	Vector3.new(-0.3090, -0.8944, -0.3090),
	Vector3.new(0.5878, 0.5878, 0.5590),
	Vector3.new(-0.5878, 0.5878, 0.5590),
	Vector3.new(0.5878, -0.5878, 0.5590),
	Vector3.new(-0.5878, -0.5878, 0.5590),
	Vector3.new(0.5878, 0.5878, -0.5590),
	Vector3.new(-0.5878, 0.5878, -0.5590),
	Vector3.new(0.5878, -0.5878, -0.5590),
	Vector3.new(-0.5878, -0.5878, -0.5590),
	Vector3.new(0.8090, 0.5878, 0.0000),
	Vector3.new(-0.8090, 0.5878, 0.0000),
	Vector3.new(0.8090, -0.5878, 0.0000),
	Vector3.new(-0.8090, -0.5878, 0.0000),
	Vector3.new(0.5878, 0.8090, 0.0000),
	Vector3.new(-0.5878, 0.8090, 0.0000),
	Vector3.new(0.5878, -0.8090, 0.0000),
	Vector3.new(-0.5878, -0.8090, 0.0000),
	Vector3.new(0.0000, 0.5878, 0.8090),
	Vector3.new(0.0000, -0.5878, 0.8090),
	Vector3.new(0.0000, 0.5878, -0.8090),
	Vector3.new(0.0000, -0.5878, -0.8090),
	Vector3.new(0.0000, 0.8090, 0.5878),
	Vector3.new(0.0000, -0.8090, 0.5878),
}

function RenderConfigs.GetActorCount()
	return ActorNumbers
end

function RenderConfigs.GetPartTriangles()
	return PART_TRIANGLES_BUFFER
end

function RenderConfigs.GetSphereVertices()
	return SphereVertices
end

function RenderConfigs.ReturnDimensions2D()
	return WIDTH, HEIGHT
end

return RenderConfigs
