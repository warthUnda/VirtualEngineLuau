--!strict
--!native
--!optimize 2

--[=[
	===========================================================================
	VerticeFile (Shape Registry & Unit Mesh Lookup)
	===========================================================================
	Maps 3-bit ECS ShapeIds to shape names and prebuilt unit meshes from
	VerticeHelper.
	===========================================================================
]=]

-- Modules --
const VerticeHelper = require(script.Parent.VerticeHelper)

export type ShapeFace = VerticeHelper.ShapeFace
export type ShapeMesh = VerticeHelper.ShapeMesh

const VerticeFile = {}

-- ============================================================================
-- 1. SHAPE ID <-> SHAPE NAME HASHMAP (3-BIT ECS PROPERTIES FIELD: 0-7)
-- ============================================================================

-- Hashmap translating 3-bit ECS ShapeId (bits 13-15) to shape name
VerticeFile.IdToShape = {
	[0] = "Cube",
	[1] = "Sphere",
	[2] = "Cylinder",
	[3] = "Triangle",
	[4] = "Plane",
} :: { [number]: string }

-- Reverse hashmap translating shape name to 3-bit ECS ShapeId
VerticeFile.ShapeToId = {
	Cube = 0,
	Sphere = 1,
	Cylinder = 2,
	Triangle = 3,
	Plane = 4,
} :: { [string]: number }

-- ============================================================================
-- 2. PREBUILT UNIT MESH HASHMAP
-- ============================================================================

-- Hashmap translating 3-bit ECS ShapeId directly to its prebuilt ShapeMesh vertex/face data
VerticeFile.ShapeData = {
	[0] = VerticeHelper.BuildCubeMesh(),
	[1] = VerticeHelper.BuildSphereMesh(),
	[2] = VerticeHelper.BuildCylinderMesh(),
	[3] = VerticeHelper.BuildTriangleMesh(),
	[4] = VerticeHelper.BuildPlaneMesh(),
} :: { [number]: ShapeMesh }

-- Maximum vertex count across all registered shapes (used to size scratch buffers)
VerticeFile.MaxShapeVertices = 64 :: number

--[=[
	Translates a 3-bit ECS ShapeId into its shape name.
	@param ShapeId number -- 3-bit shape ID (0 = Cube, 1 = Sphere, 2 = Cylinder, 3 = Triangle, 4 = Plane).
	@return string -- Shape name (defaults to "Cube" if unknown).
]=]
function VerticeFile.GetShapeName(ShapeId: number): string
	return VerticeFile.IdToShape[ShapeId] or "Cube"
end

--[=[
	Translates a shape name into its 3-bit ECS ShapeId.
	@param ShapeName string -- Shape name ("Cube", "Sphere", "Cylinder", "Triangle", "Plane").
	@return number -- 3-bit shape ID (defaults to 0 / Cube if unknown).
]=]
function VerticeFile.GetShapeId(ShapeName: string): number
	return VerticeFile.ShapeToId[ShapeName] or 0
end

--[=[
	Retrieves the prebuilt local vertex and face mesh data for a 3-bit ECS ShapeId from the ShapeData hashmap.
	@param ShapeId number -- 3-bit shape ID (0-4).
	@return ShapeMesh -- Prebuilt shape vertex/face definition (falls back to Cube if unknown).
]=]
function VerticeFile.GetShapeData(ShapeId: number): ShapeMesh
	return VerticeFile.ShapeData[ShapeId] or VerticeFile.ShapeData[0]
end

return VerticeFile
