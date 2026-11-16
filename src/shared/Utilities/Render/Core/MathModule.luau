--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const BufferHelper = require(script.Parent.BufferHelper)
const RasterizerMath = require(script.Parent.RasterizerMath)

-- Configs --
const NEAR_CLIP = SystemsConfigs.RenderNearClip :: number
const FAR_CLIP = SystemsConfigs.RenderFarClip :: number

-- Tables --
local MathModule = {}

-- Functions --
-- ============================================================================
-- 1. VERTEX PROJECTION, SUTHERLAND-HODGMAN CLIPPING & RASTERIZER FACADE
-- ============================================================================

--[=[
	Calculates the signed 2D edge function value for point relative to directed edge AB.
	@param VertexAX number -- Vertex A X.
	@param VertexAY number -- Vertex A Y.
	@param VertexBX number -- Vertex B X.
	@param VertexBY number -- Vertex B Y.
	@param PointX number -- Sample point X.
	@param PointY number -- Sample point Y.
	@return number -- Cross product / signed determinant value.
]=]
function MathModule.EdgeFunction(
	VertexAX: number,
	VertexAY: number,
	VertexBX: number,
	VertexBY: number,
	PointX: number,
	PointY: number
): number
	return (PointX - VertexAX) * (VertexBY - VertexAY) - (PointY - VertexAY) * (VertexBX - VertexAX)
end

--[=[
	Tests whether a camera-space vertex is inside the near/far planes and frustum guardband.
	@param Vertex vector -- Camera-space vertex.
	@param GuardBandX number -- Horizontal guardband slope factor.
	@param GuardBandY number -- Vertical guardband slope factor.
	@return boolean -- True if vertex lies within the safe frustum bounds.
]=]
function MathModule.IsVertexInside(Vertex: vector, GuardBandX: number, GuardBandY: number): boolean
	const DepthZ = Vertex.z :: number
	if DepthZ < NEAR_CLIP or DepthZ > FAR_CLIP then
		return false
	end

	return math.abs(Vertex.x) <= GuardBandX * DepthZ and math.abs(Vertex.y) <= GuardBandY * DepthZ
end

--[=[
	Projects a 3D camera-space vertex and its texture coordinates into a 20-byte projected vertex slot.
	@param ProjectedVertices buffer -- Buffer to receive projected vertex data.
	@param Offset number -- Byte offset in output buffer (20-byte stride).
	@param Vertex vector -- Camera-space 3D vertex.
	@param TexCoordU number -- Horizontal texture coordinate.
	@param TexCoordV number -- Vertical texture coordinate.
	@param FocalLength number -- Camera focal length scalar.
	@param HalfWidth number -- Half screen width in pixels.
	@param HalfHeight number -- Half screen height in pixels.
]=]
function MathModule.ProjectVertexUV(
	ProjectedVertices: buffer,
	Offset: number,
	Vertex: vector,
	TexCoordU: number,
	TexCoordV: number,
	FocalLength: number,
	HalfWidth: number,
	HalfHeight: number
)
	const InverseZ = 1 / Vertex.z :: number
	buffer.writef32(ProjectedVertices, Offset, math.floor(Vertex.x * InverseZ * FocalLength + HalfWidth))
	buffer.writef32(ProjectedVertices, Offset + 4, math.floor(-Vertex.y * InverseZ * FocalLength + HalfHeight))
	buffer.writef32(ProjectedVertices, Offset + 8, InverseZ)
	buffer.writef32(ProjectedVertices, Offset + 12, TexCoordU)
	buffer.writef32(ProjectedVertices, Offset + 16, TexCoordV)
end

--[=[
	Clips a UV-attributed polygon (20-byte stride: X, Y, Z, U, V) against an arbitrary half-space plane using Sutherland-Hodgman.
	@param Input buffer -- Buffer of input 20-byte vertices (Vec3 + UV).
	@param InputCount number -- Number of input vertices.
	@param Output buffer -- Buffer to receive clipped 20-byte vertices.
	@param PlaneNormal vector -- Inward-pointing clipping plane normal.
	@param PlaneOffset number -- Plane distance constant.
	@return number -- Number of output vertices after clipping.
]=]
function MathModule.ClipPolygonUV(
	Input: buffer,
	InputCount: number,
	Output: buffer,
	PlaneNormal: vector,
	PlaneOffset: number
): number
	if InputCount == 0 then
		return 0
	end

	local OutputCount = 0 :: number
	const LastOffset = (InputCount - 1) * 20 :: number
	local PreviousVertex = BufferHelper.ReadVec3(Input, LastOffset)
	local PreviousU = buffer.readf32(Input, LastOffset + 12) :: number
	local PreviousV = buffer.readf32(Input, LastOffset + 16) :: number
	local PreviousDistance = vector.dot(PreviousVertex, PlaneNormal) + PlaneOffset :: number

	for i = 1, InputCount do
		const ReadBaseOffset = (i - 1) * 20 :: number
		const CurrentVertex = BufferHelper.ReadVec3(Input, ReadBaseOffset)
		const CurrentU = buffer.readf32(Input, ReadBaseOffset + 12) :: number
		const CurrentV = buffer.readf32(Input, ReadBaseOffset + 16) :: number
		const CurrentDistance = vector.dot(CurrentVertex, PlaneNormal) + PlaneOffset :: number
		const PreviousInside = (PreviousDistance >= 0) :: boolean
		const CurrentInside = (CurrentDistance >= 0) :: boolean

		if PreviousInside ~= CurrentInside then
			const IntersectionFactor = PreviousDistance / (PreviousDistance - CurrentDistance) :: number
			const WriteBaseOffset = OutputCount * 20 :: number
			BufferHelper.WriteVec3(
				Output,
				WriteBaseOffset,
				PreviousVertex + (CurrentVertex - PreviousVertex) * IntersectionFactor
			)
			buffer.writef32(Output, WriteBaseOffset + 12, PreviousU + (CurrentU - PreviousU) * IntersectionFactor)
			buffer.writef32(Output, WriteBaseOffset + 16, PreviousV + (CurrentV - PreviousV) * IntersectionFactor)
			OutputCount += 1
		end

		if CurrentInside then
			const WriteBaseOffset = OutputCount * 20 :: number
			BufferHelper.WriteVec3(Output, WriteBaseOffset, CurrentVertex)
			buffer.writef32(Output, WriteBaseOffset + 12, CurrentU)
			buffer.writef32(Output, WriteBaseOffset + 16, CurrentV)
			OutputCount += 1
		end

		PreviousVertex = CurrentVertex
		PreviousU = CurrentU
		PreviousV = CurrentV
		PreviousDistance = CurrentDistance
	end

	return OutputCount
end

MathModule.ClipSpanEdge = RasterizerMath.ClipSpanEdge
MathModule.RasterizeTriangleSpan = RasterizerMath.RasterizeTriangleSpan

return MathModule
