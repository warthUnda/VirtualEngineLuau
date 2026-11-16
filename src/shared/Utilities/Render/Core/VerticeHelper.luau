--!strict
--!native
--!optimize 2

-- Libraries --
const VerticeCurvedHelper = require(script.Parent.VerticeCurvedHelper)

-- Configs --
export type ShapeFace = VerticeCurvedHelper.ShapeFace
export type ShapeMesh = VerticeCurvedHelper.ShapeMesh

-- Tables --
local VerticeHelper = {}

-- Functions --
-- ============================================================================
-- 1. FACE WINDING & PLANAR UNIT MESH BUILDERS (FACADE)
-- ============================================================================

--[=[
	Creates a face entry with winding verified against the outward local normal so screen-space area is positive.
	@param LocalVertices { vector } -- Shape local vertex array.
	@param Index0 number -- 1-based vertex index 0.
	@param Index1 number -- 1-based vertex index 1.
	@param Index2 number -- 1-based vertex index 2.
	@param Index3 number? -- Optional 1-based vertex index 3 for quads (nil for triangles).
	@param ExplicitNormal vector? -- Optional explicit outward unit normal.
	@return ShapeFace -- Constructed face record with precomputed 12-byte vertex buffer offsets.
]=]
function VerticeHelper.CreateFace(
	LocalVertices: { vector },
	Index0: number,
	Index1: number,
	Index2: number,
	Index3: number?,
	ExplicitNormal: vector?
): ShapeFace
	const V0 = LocalVertices[Index0]
	const V1 = LocalVertices[Index1]
	const V2 = LocalVertices[Index2]

	const WindingCross = vector.cross(V2 - V0, V1 - V0)
	const OutwardNormal = if ExplicitNormal
		then vector.normalize(ExplicitNormal)
		else (if vector.magnitude(WindingCross) > 1e-6 then vector.normalize(WindingCross) else vector.create(0, 1, 0))

	const AbsNormalX = math.abs(OutwardNormal.x) :: number
	const AbsNormalY = math.abs(OutwardNormal.y) :: number
	const AbsNormalZ = math.abs(OutwardNormal.z) :: number
	local UAxisIndex = 1 :: number
	local VAxisIndex = 2 :: number
	if AbsNormalY >= AbsNormalX and AbsNormalY >= AbsNormalZ then
		UAxisIndex = 1
		VAxisIndex = 3
	elseif AbsNormalX >= AbsNormalY and AbsNormalX >= AbsNormalZ then
		UAxisIndex = 3
		VAxisIndex = 2
	end

	if vector.dot(WindingCross, OutwardNormal) < 0 then
		if Index3 then
			return {
				V0ByteOffset = (Index0 - 1) * 12,
				V1ByteOffset = (Index3 - 1) * 12,
				V2ByteOffset = (Index2 - 1) * 12,
				V3ByteOffset = (Index1 - 1) * 12,
				Normal = OutwardNormal,
				PointOnFace = V0,
				UAxisIndex = UAxisIndex,
				VAxisIndex = VAxisIndex,
			}
		end
		return {
			V0ByteOffset = (Index0 - 1) * 12,
			V1ByteOffset = (Index2 - 1) * 12,
			V2ByteOffset = (Index1 - 1) * 12,
			V3ByteOffset = -1,
			Normal = OutwardNormal,
			PointOnFace = V0,
			UAxisIndex = UAxisIndex,
			VAxisIndex = VAxisIndex,
		}
	end

	return {
		V0ByteOffset = (Index0 - 1) * 12,
		V1ByteOffset = (Index1 - 1) * 12,
		V2ByteOffset = (Index2 - 1) * 12,
		V3ByteOffset = if Index3 then (Index3 - 1) * 12 else -1,
		Normal = OutwardNormal,
		PointOnFace = V0,
		UAxisIndex = UAxisIndex,
		VAxisIndex = VAxisIndex,
	}
end

--[=[
	Builds the unit Cube mesh (ShapeId = 0) with 8 corners and 6 quad faces.
	@return ShapeMesh -- Unit cube mesh data.
]=]
function VerticeHelper.BuildCubeMesh(): ShapeMesh
	const LocalVertices = {
		vector.create(-1, -1, 1),
		vector.create(1, -1, 1),
		vector.create(1, 1, 1),
		vector.create(-1, 1, 1),
		vector.create(-1, -1, -1),
		vector.create(1, -1, -1),
		vector.create(1, 1, -1),
		vector.create(-1, 1, -1),
	}

	const Faces = {
		VerticeHelper.CreateFace(LocalVertices, 1, 4, 3, 2, vector.create(0, 0, 1)),
		VerticeHelper.CreateFace(LocalVertices, 5, 6, 7, 8, vector.create(0, 0, -1)),
		VerticeHelper.CreateFace(LocalVertices, 1, 2, 6, 5, vector.create(0, -1, 0)),
		VerticeHelper.CreateFace(LocalVertices, 3, 4, 8, 7, vector.create(0, 1, 0)),
		VerticeHelper.CreateFace(LocalVertices, 1, 5, 8, 4, vector.create(-1, 0, 0)),
		VerticeHelper.CreateFace(LocalVertices, 2, 3, 7, 6, vector.create(1, 0, 0)),
	}

	return {
		ShapeId = 0,
		Name = "Cube",
		IsAxisAligned = true,
		VertexCount = #LocalVertices,
		LocalVertices = LocalVertices,
		Faces = Faces,
	}
end

--[=[
	Builds the unit Sphere mesh (ShapeId = 1) using latitude/longitude rings.
	@return ShapeMesh -- Unit sphere mesh data.
]=]
function VerticeHelper.BuildSphereMesh(): ShapeMesh
	return VerticeCurvedHelper.BuildSphereMesh(VerticeHelper.CreateFace)
end

--[=[
	Builds the unit Cylinder mesh (ShapeId = 2) with 12 radial segments.
	@return ShapeMesh -- Unit cylinder mesh data.
]=]
function VerticeHelper.BuildCylinderMesh(): ShapeMesh
	return VerticeCurvedHelper.BuildCylinderMesh(VerticeHelper.CreateFace)
end

--[=[
	Builds the unit 3D Triangle / Wedge prism mesh (ShapeId = 3) with 6 vertices and 5 faces.
	@return ShapeMesh -- Unit 3D triangle/wedge mesh data.
]=]
function VerticeHelper.BuildTriangleMesh(): ShapeMesh
	const LocalVertices = {
		vector.create(-1, -1, 1),
		vector.create(1, -1, 1),
		vector.create(1, 1, 1),
		vector.create(-1, 1, 1),
		vector.create(-1, -1, -1),
		vector.create(1, -1, -1),
	}

	const SlopeNormal = vector.normalize(vector.create(0, 1, -1))
	const Faces = {
		VerticeHelper.CreateFace(LocalVertices, 1, 4, 3, 2, vector.create(0, 0, 1)),
		VerticeHelper.CreateFace(LocalVertices, 1, 2, 6, 5, vector.create(0, -1, 0)),
		VerticeHelper.CreateFace(LocalVertices, 5, 6, 3, 4, SlopeNormal),
		VerticeHelper.CreateFace(LocalVertices, 1, 5, 4, nil, vector.create(-1, 0, 0)),
		VerticeHelper.CreateFace(LocalVertices, 2, 3, 6, nil, vector.create(1, 0, 0)),
	}

	return {
		ShapeId = 3,
		Name = "Triangle",
		IsAxisAligned = false,
		VertexCount = #LocalVertices,
		LocalVertices = LocalVertices,
		Faces = Faces,
	}
end

--[=[
	Builds the unit Plane mesh (ShapeId = 4) with 4 corners and double-sided top/bottom quad faces.
	@return ShapeMesh -- Unit plane mesh data.
]=]
function VerticeHelper.BuildPlaneMesh(): ShapeMesh
	const LocalVertices = {
		vector.create(-1, 0, 1),
		vector.create(1, 0, 1),
		vector.create(1, 0, -1),
		vector.create(-1, 0, -1),
	}

	const Faces = {
		VerticeHelper.CreateFace(LocalVertices, 2, 1, 4, 3, vector.create(0, 1, 0)),
		VerticeHelper.CreateFace(LocalVertices, 1, 2, 3, 4, vector.create(0, -1, 0)),
	}

	return {
		ShapeId = 4,
		Name = "Plane",
		IsAxisAligned = true,
		VertexCount = #LocalVertices,
		LocalVertices = LocalVertices,
		Faces = Faces,
	}
end

return VerticeHelper
