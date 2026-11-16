--!strict
--!native
--!optimize 2

-- Configs --
export type ShapeFace = {
	V0ByteOffset: number,
	V1ByteOffset: number,
	V2ByteOffset: number,
	V3ByteOffset: number,
	Normal: vector,
	PointOnFace: vector,
	UAxisIndex: number,
	VAxisIndex: number,
}

export type ShapeMesh = {
	ShapeId: number,
	Name: string,
	IsAxisAligned: boolean,
	VertexCount: number,
	LocalVertices: { vector },
	Faces: { ShapeFace },
}

export type CreateFaceFn = (
	LocalVertices: { vector },
	Index0: number,
	Index1: number,
	Index2: number,
	Index3: number?,
	ExplicitNormal: vector?
) -> ShapeFace

-- Tables --
local VerticeCurvedHelper = {}

-- Functions --
-- ============================================================================
-- 1. PROCEDURAL CURVED UNIT MESH BUILDERS (SPHERE & CYLINDER)
-- ============================================================================

--[=[
	Builds the unit Sphere mesh (ShapeId = 1) using latitude/longitude rings.
	@param CreateFace CreateFaceFn -- Winding-verified face constructor from VerticeHelper.
	@return ShapeMesh -- Unit sphere mesh data.
]=]
function VerticeCurvedHelper.BuildSphereMesh(CreateFace: CreateFaceFn): ShapeMesh
	const LatRings = 6 :: number
	const LonSegments = 10 :: number
	const LocalVertices = {} :: { vector }
	const Faces = {} :: { ShapeFace }

	table.insert(LocalVertices, vector.create(0, 1, 0))
	table.insert(LocalVertices, vector.create(0, -1, 0))

	for Ring = 1, LatRings - 1 do
		const Phi = (Ring / LatRings) * math.pi :: number
		const SinPhi = math.sin(Phi) :: number
		const CosPhi = math.cos(Phi) :: number

		for Seg = 0, LonSegments - 1 do
			const Theta = (Seg / LonSegments) * (math.pi * 2) :: number
			table.insert(LocalVertices, vector.create(SinPhi * math.cos(Theta), CosPhi, SinPhi * math.sin(Theta)))
		end
	end

	const FirstRingBase = 3 :: number
	for Seg = 0, LonSegments - 1 do
		const NextSeg = (Seg + 1) % LonSegments :: number
		const V1 = FirstRingBase + Seg :: number
		const V2 = FirstRingBase + NextSeg :: number
		const AvgNormal = vector.normalize(LocalVertices[1] + LocalVertices[V1] + LocalVertices[V2])
		table.insert(Faces, CreateFace(LocalVertices, 1, V1, V2, nil, AvgNormal))
	end

	for Ring = 1, LatRings - 2 do
		const UpperRingBase = 3 + (Ring - 1) * LonSegments :: number
		const LowerRingBase = UpperRingBase + LonSegments :: number

		for Seg = 0, LonSegments - 1 do
			const NextSeg = (Seg + 1) % LonSegments :: number
			const U0 = UpperRingBase + Seg :: number
			const U1 = UpperRingBase + NextSeg :: number
			const L0 = LowerRingBase + Seg :: number
			const L1 = LowerRingBase + NextSeg :: number
			const AvgNormal = vector.normalize(LocalVertices[U0] + LocalVertices[U1] + LocalVertices[L1] + LocalVertices[L0])
			table.insert(Faces, CreateFace(LocalVertices, L0, U0, U1, L1, AvgNormal))
		end
	end

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
	@param CreateFace CreateFaceFn -- Winding-verified face constructor from VerticeHelper.
	@return ShapeMesh -- Unit cylinder mesh data.
]=]
function VerticeCurvedHelper.BuildCylinderMesh(CreateFace: CreateFaceFn): ShapeMesh
	const Segments = 12 :: number
	const LocalVertices = {} :: { vector }
	const Faces = {} :: { ShapeFace }

	for Seg = 0, Segments - 1 do
		const Theta = (Seg / Segments) * (math.pi * 2) :: number
		table.insert(LocalVertices, vector.create(math.cos(Theta), 1, math.sin(Theta)))
	end
	for Seg = 0, Segments - 1 do
		const Theta = (Seg / Segments) * (math.pi * 2) :: number
		table.insert(LocalVertices, vector.create(math.cos(Theta), -1, math.sin(Theta)))
	end

	for Seg = 0, Segments - 1 do
		const NextSeg = (Seg + 1) % Segments :: number
		const Top0 = 1 + Seg :: number
		const Top1 = 1 + NextSeg :: number
		const Bot0 = Segments + 1 + Seg :: number
		const Bot1 = Segments + 1 + NextSeg :: number
		const MidNormal = vector.normalize(
			vector.create(LocalVertices[Top0].x + LocalVertices[Top1].x, 0, LocalVertices[Top0].z + LocalVertices[Top1].z)
		)
		table.insert(Faces, CreateFace(LocalVertices, Bot0, Top0, Top1, Bot1, MidNormal))
	end

	const TopNormal = vector.create(0, 1, 0)
	const BottomNormal = vector.create(0, -1, 0)
	for Seg = 2, Segments - 1 do
		table.insert(Faces, CreateFace(LocalVertices, 1, Seg, Seg + 1, nil, TopNormal))
		table.insert(Faces, CreateFace(LocalVertices, Segments + 1, Segments + Seg + 1, Segments + Seg, nil, BottomNormal))
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

return VerticeCurvedHelper
