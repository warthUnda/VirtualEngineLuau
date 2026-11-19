--!strict
--!native
--!optimize 2

--[=[
	@class MathModule
	Vertex projection, inlined Sutherland-Hodgman UV polygon clipping, and rasterizer facade.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
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
	Projects a 3D camera-space vertex and its texture coordinates into a 24-byte padded projected vertex slot.
	@param ProjectedVertices buffer -- Buffer to receive projected vertex data.
	@param Offset number -- Byte offset in output buffer (24-byte stride).
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
	const Scale = InverseZ * FocalLength :: number
	buffer.writef32(ProjectedVertices, Offset, math.floor(Vertex.x * Scale + HalfWidth))
	buffer.writef32(ProjectedVertices, Offset + 4, math.floor(-Vertex.y * Scale + HalfHeight))
	buffer.writef32(ProjectedVertices, Offset + 8, InverseZ)
	buffer.writef32(ProjectedVertices, Offset + 12, TexCoordU)
	buffer.writef32(ProjectedVertices, Offset + 16, TexCoordV)
end

--[=[
	Clips a UV-attributed polygon (24-byte padded stride: X, Y, Z, U, V, +4B pad) against an arbitrary half-space plane using Sutherland-Hodgman.
	@param Input buffer -- Buffer of input 24-byte vertices (Vec3 + UV + pad).
	@param InputCount number -- Number of input vertices.
	@param Output buffer -- Buffer to receive clipped 24-byte vertices.
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

	const Nx = PlaneNormal.x :: number
	const Ny = PlaneNormal.y :: number
	const Nz = PlaneNormal.z :: number
	local OutputCount = 0 :: number
	const LastOffset = (InputCount - 1) * 24 :: number
	local PrevX = buffer.readf32(Input, LastOffset) :: number
	local PrevY = buffer.readf32(Input, LastOffset + 4) :: number
	local PrevZ = buffer.readf32(Input, LastOffset + 8) :: number
	local PrevU = buffer.readf32(Input, LastOffset + 12) :: number
	local PrevV = buffer.readf32(Input, LastOffset + 16) :: number
	local PrevDist = PrevX * Nx + PrevY * Ny + PrevZ * Nz + PlaneOffset :: number

	for i = 0, InputCount - 1 do
		const ReadOff = i * 24 :: number
		const CurX = buffer.readf32(Input, ReadOff) :: number
		const CurY = buffer.readf32(Input, ReadOff + 4) :: number
		const CurZ = buffer.readf32(Input, ReadOff + 8) :: number
		const CurU = buffer.readf32(Input, ReadOff + 12) :: number
		const CurV = buffer.readf32(Input, ReadOff + 16) :: number
		const CurDist = CurX * Nx + CurY * Ny + CurZ * Nz + PlaneOffset :: number
		const PrevIn = PrevDist >= 0 :: boolean
		const CurIn = CurDist >= 0 :: boolean

		if PrevIn ~= CurIn then
			const T = PrevDist / (PrevDist - CurDist) :: number
			const WriteOff = OutputCount * 24 :: number
			buffer.writef32(Output, WriteOff, PrevX + (CurX - PrevX) * T)
			buffer.writef32(Output, WriteOff + 4, PrevY + (CurY - PrevY) * T)
			buffer.writef32(Output, WriteOff + 8, PrevZ + (CurZ - PrevZ) * T)
			buffer.writef32(Output, WriteOff + 12, PrevU + (CurU - PrevU) * T)
			buffer.writef32(Output, WriteOff + 16, PrevV + (CurV - PrevV) * T)
			OutputCount += 1
		end

		if CurIn then
			const WriteOff = OutputCount * 24 :: number
			buffer.writef32(Output, WriteOff, CurX)
			buffer.writef32(Output, WriteOff + 4, CurY)
			buffer.writef32(Output, WriteOff + 8, CurZ)
			buffer.writef32(Output, WriteOff + 12, CurU)
			buffer.writef32(Output, WriteOff + 16, CurV)
			OutputCount += 1
		end

		PrevX, PrevY, PrevZ = CurX, CurY, CurZ
		PrevU, PrevV = CurU, CurV
		PrevDist = CurDist
	end

	return OutputCount
end

MathModule.ClipSpanEdge = RasterizerMath.ClipSpanEdge
MathModule.RasterizeTriangleSpan = RasterizerMath.RasterizeTriangleSpan

return MathModule
