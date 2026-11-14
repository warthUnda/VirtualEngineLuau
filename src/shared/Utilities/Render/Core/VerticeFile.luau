--!strict
--!native
--!optimize 2

export type ShapeFace = {
	V0ByteOffset: number,
	V1ByteOffset: number,
	V2ByteOffset: number,
	V3ByteOffset: number,
	Normal: vector,
	PointOnFace: vector,
}

export type ShapeMesh = {
	ShapeId: number,
	Name: string,
	IsAxisAligned: boolean,
	VertexCount: number,
	LocalVertices: { vector },
	Faces: { ShapeFace },
}

local VerticeFile = {}

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
-- 2. PROCEDURAL UNIT MESH BUILDERS IN LOCAL (RIGHT, UP, LOOK) [-1, 1] SPACE
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
local function CreateFace(
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
	local OutwardNormal: vector
	if ExplicitNormal then
		OutwardNormal = vector.normalize(ExplicitNormal)
	else
		const CrossMag = vector.magnitude(WindingCross) :: number
		OutwardNormal = if CrossMag > 1e-6 then WindingCross / CrossMag else vector.create(0, 1, 0)
	end

	-- In local (Right, Up, Look) space, (V2 - V0) x (V1 - V0) must align with OutwardNormal for positive screen area
	if vector.dot(WindingCross, OutwardNormal) < 0 then
		if Index3 then
			return {
				V0ByteOffset = (Index0 - 1) * 12,
				V1ByteOffset = (Index3 - 1) * 12,
				V2ByteOffset = (Index2 - 1) * 12,
				V3ByteOffset = (Index1 - 1) * 12,
				Normal = OutwardNormal,
				PointOnFace = V0,
			}
		else
			return {
				V0ByteOffset = (Index0 - 1) * 12,
				V1ByteOffset = (Index2 - 1) * 12,
				V2ByteOffset = (Index1 - 1) * 12,
				V3ByteOffset = -1,
				Normal = OutwardNormal,
				PointOnFace = V0,
			}
		end
	end

	return {
		V0ByteOffset = (Index0 - 1) * 12,
		V1ByteOffset = (Index1 - 1) * 12,
		V2ByteOffset = (Index2 - 1) * 12,
		V3ByteOffset = if Index3 then (Index3 - 1) * 12 else -1,
		Normal = OutwardNormal,
		PointOnFace = V0,
	}
end

--[=[
	Builds the unit Cube mesh (ShapeId = 0) with 8 corners and 6 quad faces.
	@return ShapeMesh -- Unit cube mesh data.
]=]
local function BuildCubeMesh(): ShapeMesh
	const LocalVertices = {
		vector.create(-1, -1, 1), -- 1 (offset 0)
		vector.create(1, -1, 1), -- 2 (offset 12)
		vector.create(1, 1, 1), -- 3 (offset 24)
		vector.create(-1, 1, 1), -- 4 (offset 36)
		vector.create(-1, -1, -1), -- 5 (offset 48)
		vector.create(1, -1, -1), -- 6 (offset 60)
		vector.create(1, 1, -1), -- 7 (offset 72)
		vector.create(-1, 1, -1), -- 8 (offset 84)
	}

	const Faces = {
		CreateFace(LocalVertices, 1, 4, 3, 2, vector.create(0, 0, 1)), -- Back (+Look)
		CreateFace(LocalVertices, 5, 6, 7, 8, vector.create(0, 0, -1)), -- Front (-Look)
		CreateFace(LocalVertices, 1, 2, 6, 5, vector.create(0, -1, 0)), -- Bottom (-Up)
		CreateFace(LocalVertices, 3, 4, 8, 7, vector.create(0, 1, 0)), -- Top (+Up)
		CreateFace(LocalVertices, 1, 5, 8, 4, vector.create(-1, 0, 0)), -- Left (-Right)
		CreateFace(LocalVertices, 2, 3, 7, 6, vector.create(1, 0, 0)), -- Right (+Right)
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
local function BuildSphereMesh(): ShapeMesh
	const LatRings = 6 :: number
	const LonSegments = 10 :: number
	const LocalVertices = {} :: { vector }
	const Faces = {} :: { ShapeFace }

	-- Top pole (index 1) and bottom pole (index 2)
	table.insert(LocalVertices, vector.create(0, 1, 0))
	table.insert(LocalVertices, vector.create(0, -1, 0))

	-- Intermediate rings (1 .. LatRings - 1)
	for Ring = 1, LatRings - 1 do
		const Phi = (Ring / LatRings) * math.pi :: number
		const SinPhi = math.sin(Phi) :: number
		const CosPhi = math.cos(Phi) :: number

		for Seg = 0, LonSegments - 1 do
			const Theta = (Seg / LonSegments) * (math.pi * 2) :: number
			const X = SinPhi * math.cos(Theta) :: number
			const Z = SinPhi * math.sin(Theta) :: number
			table.insert(LocalVertices, vector.create(X, CosPhi, Z))
		end
	end

	-- Top cap triangles (connecting top pole 1 to first ring)
	const FirstRingBase = 3 :: number
	for Seg = 0, LonSegments - 1 do
		const NextSeg = (Seg + 1) % LonSegments :: number
		const V1 = FirstRingBase + Seg :: number
		const V2 = FirstRingBase + NextSeg :: number
		const AvgNormal = vector.normalize(LocalVertices[1] + LocalVertices[V1] + LocalVertices[V2])
		table.insert(Faces, CreateFace(LocalVertices, 1, V1, V2, nil, AvgNormal))
	end

	-- Middle quad bands between rings
	for Ring = 1, LatRings - 2 do
		const UpperRingBase = 3 + (Ring - 1) * LonSegments :: number
		const LowerRingBase = UpperRingBase + LonSegments :: number

		for Seg = 0, LonSegments - 1 do
			const NextSeg = (Seg + 1) % LonSegments :: number
			const U0 = UpperRingBase + Seg :: number
			const U1 = UpperRingBase + NextSeg :: number
			const L0 = LowerRingBase + Seg :: number
			const L1 = LowerRingBase + NextSeg :: number
			const AvgNormal = vector.normalize(
				LocalVertices[U0] + LocalVertices[U1] + LocalVertices[L1] + LocalVertices[L0]
			)
			table.insert(Faces, CreateFace(LocalVertices, L0, U0, U1, L1, AvgNormal))
		end
	end

	-- Bottom cap triangles (connecting last ring to bottom pole 2)
	const LastRingBase = 3 + (LatRings - 2) * LonSegments :: number
	for Seg = 0, LonSegments - 1 do
		const NextSeg = (Seg + 1) % LonSegments :: number
		const V1 = LastRingBase + Seg :: number
		const V2 = LastRingBase + NextSeg :: number
		const AvgNormal = vector.normalize(LocalVertices[2] + LocalVertices[V1] + LocalVertices[V2])
		table.insert(Faces, CreateFace(LocalVertices, 2, V2, V1, nil, AvgNormal))
	end

	return {
		ShapeId = 1,
		Name = "Sphere",
		IsAxisAligned = false,
		VertexCount = #LocalVertices,
		LocalVertices = LocalVertices,
		Faces = Faces,
	}
end

--[=[
	Builds the unit Cylinder mesh (ShapeId = 2) with 12 radial segments.
	@return ShapeMesh -- Unit cylinder mesh data.
]=]
local function BuildCylinderMesh(): ShapeMesh
	const Segments = 12 :: number
	const LocalVertices = {} :: { vector }
	const Faces = {} :: { ShapeFace }

	-- Top ring (indices 1..Segments) and Bottom ring (indices Segments+1..2*Segments)
	for Seg = 0, Segments - 1 do
		const Theta = (Seg / Segments) * (math.pi * 2) :: number
		const X = math.cos(Theta) :: number
		const Z = math.sin(Theta) :: number
		table.insert(LocalVertices, vector.create(X, 1, Z))
	end
	for Seg = 0, Segments - 1 do
		const Theta = (Seg / Segments) * (math.pi * 2) :: number
		const X = math.cos(Theta) :: number
		const Z = math.sin(Theta) :: number
		table.insert(LocalVertices, vector.create(X, -1, Z))
	end

	-- Side quad faces
	for Seg = 0, Segments - 1 do
		const NextSeg = (Seg + 1) % Segments :: number
		const Top0 = 1 + Seg :: number
		const Top1 = 1 + NextSeg :: number
		const Bot0 = Segments + 1 + Seg :: number
		const Bot1 = Segments + 1 + NextSeg :: number
		const MidNormal = vector.normalize(
			vector.create(
				LocalVertices[Top0].x + LocalVertices[Top1].x,
				0,
				LocalVertices[Top0].z + LocalVertices[Top1].z
			)
		)
		table.insert(Faces, CreateFace(LocalVertices, Bot0, Top0, Top1, Bot1, MidNormal))
	end

	-- Top cap triangle fan (+Up) and Bottom cap triangle fan (-Up)
	const TopNormal = vector.create(0, 1, 0)
	const BottomNormal = vector.create(0, -1, 0)
	for Seg = 2, Segments - 1 do
		table.insert(Faces, CreateFace(LocalVertices, 1, Seg, Seg + 1, nil, TopNormal))
		table.insert(
			Faces,
			CreateFace(LocalVertices, Segments + 1, Segments + Seg + 1, Segments + Seg, nil, BottomNormal)
		)
	end

	return {
		ShapeId = 2,
		Name = "Cylinder",
		IsAxisAligned = false,
		VertexCount = #LocalVertices,
		LocalVertices = LocalVertices,
		Faces = Faces,
	}
end

--[=[
	Builds the unit 3D Triangle / Wedge prism mesh (ShapeId = 3) with 6 vertices and 5 faces.
	@return ShapeMesh -- Unit 3D triangle/wedge mesh data.
]=]
local function BuildTriangleMesh(): ShapeMesh
	const LocalVertices = {
		vector.create(-1, -1, 1), -- 1: Bottom-Left-Back (+Look)
		vector.create(1, -1, 1), -- 2: Bottom-Right-Back (+Look)
		vector.create(1, 1, 1), -- 3: Top-Right-Back (+Look)
		vector.create(-1, 1, 1), -- 4: Top-Left-Back (+Look)
		vector.create(-1, -1, -1), -- 5: Bottom-Left-Front (-Look)
		vector.create(1, -1, -1), -- 6: Bottom-Right-Front (-Look)
	}

	const SlopeNormal = vector.normalize(vector.create(0, 1, -1))
	const Faces = {
		CreateFace(LocalVertices, 1, 4, 3, 2, vector.create(0, 0, 1)), -- Back vertical quad (+Look)
		CreateFace(LocalVertices, 1, 2, 6, 5, vector.create(0, -1, 0)), -- Bottom quad (-Up)
		CreateFace(LocalVertices, 5, 6, 3, 4, SlopeNormal), -- Sloped ramp quad (+Up / -Look)
		CreateFace(LocalVertices, 1, 5, 4, nil, vector.create(-1, 0, 0)), -- Left triangle (-Right)
		CreateFace(LocalVertices, 2, 3, 6, nil, vector.create(1, 0, 0)), -- Right triangle (+Right)
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
local function BuildPlaneMesh(): ShapeMesh
	const LocalVertices = {
		vector.create(-1, 0, 1), -- 1: Back-Left
		vector.create(1, 0, 1), -- 2: Back-Right
		vector.create(1, 0, -1), -- 3: Front-Right
		vector.create(-1, 0, -1), -- 4: Front-Left
	}

	const Faces = {
		CreateFace(LocalVertices, 2, 1, 4, 3, vector.create(0, 1, 0)), -- Top face (+Up)
		CreateFace(LocalVertices, 1, 2, 3, 4, vector.create(0, -1, 0)), -- Bottom face (-Up)
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

-- Hashmap translating 3-bit ECS ShapeId directly to its prebuilt ShapeMesh vertex/face data
VerticeFile.ShapeData = {
	[0] = BuildCubeMesh(),
	[1] = BuildSphereMesh(),
	[2] = BuildCylinderMesh(),
	[3] = BuildTriangleMesh(),
	[4] = BuildPlaneMesh(),
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
