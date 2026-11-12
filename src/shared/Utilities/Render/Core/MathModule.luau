--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const BufferHelper = require(script.Parent.BufferHelper)

-- Configs --
const NEAR_CLIP = SystemsConfigs.RenderNearClip :: number
const FAR_CLIP = SystemsConfigs.RenderFarClip :: number

local MathModule = {}

-- ============================================================================
-- 1. FUNCTIONS - VERTEX PROJECTION & CLIPPING MATH
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
	Projects a 3D camera-space vertex onto the 2D integer screen coordinate plane.
	@param ProjectedVertices buffer -- Buffer to receive projected vertex data.
	@param Offset number -- Byte offset in output buffer.
	@param Vertex vector -- Camera-space 3D vertex.
	@param FocalLength number -- Camera focal length scalar.
	@param HalfWidth number -- Half screen width in pixels.
	@param HalfHeight number -- Half screen height in pixels.
]=]
function MathModule.ProjectVertex(
	ProjectedVertices: buffer,
	Offset: number,
	Vertex: vector,
	FocalLength: number,
	HalfWidth: number,
	HalfHeight: number
)
	const InverseZ = 1 / Vertex.z :: number
	buffer.writef32(ProjectedVertices, Offset, math.floor(Vertex.x * InverseZ * FocalLength + HalfWidth))
	buffer.writef32(ProjectedVertices, Offset + 4, math.floor(-Vertex.y * InverseZ * FocalLength + HalfHeight))
	buffer.writef32(ProjectedVertices, Offset + 8, InverseZ)
end

--[=[
	Clips an input polygon against an arbitrary half-space plane using Sutherland-Hodgman.
	@param Input buffer -- Buffer of input 3D vector vertices.
	@param InputCount number -- Number of input vertices.
	@param Output buffer -- Buffer to receive clipped 3D vertices.
	@param PlaneNormal vector -- Inward-pointing clipping plane normal.
	@param PlaneOffset number -- Plane distance constant.
	@return number -- Number of output vertices after clipping.
]=]
function MathModule.ClipPolygon(
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
	local PreviousVertex = BufferHelper.ReadVec3(Input, (InputCount - 1) * 12)
	local PreviousDistance = vector.dot(PreviousVertex, PlaneNormal) + PlaneOffset :: number

	for i = 1, InputCount do
		const CurrentVertex = BufferHelper.ReadVec3(Input, (i - 1) * 12)
		const CurrentDistance = vector.dot(CurrentVertex, PlaneNormal) + PlaneOffset :: number
		const PreviousInside = (PreviousDistance >= 0) :: boolean
		const CurrentInside = (CurrentDistance >= 0) :: boolean

		if PreviousInside ~= CurrentInside then
			const IntersectionFactor = PreviousDistance / (PreviousDistance - CurrentDistance) :: number
			BufferHelper.WriteVec3(
				Output,
				OutputCount * 12,
				PreviousVertex + (CurrentVertex - PreviousVertex) * IntersectionFactor
			)
			OutputCount += 1
		end

		if CurrentInside then
			BufferHelper.WriteVec3(Output, OutputCount * 12, CurrentVertex)
			OutputCount += 1
		end

		PreviousVertex = CurrentVertex
		PreviousDistance = CurrentDistance
	end

	return OutputCount
end

-- ============================================================================
-- 2. FUNCTIONS - EXACT SPAN RASTERIZATION MATH
-- ============================================================================

--[=[
	Clips an active horizontal raster scanline span against a single linear edge function.
	@param RowEdgeWeight number -- Initial edge value at span start.
	@param EdgeStepX number -- Edge value differential per horizontal pixel step.
	@param SpanStartOffsetX number -- Current span start pixel offset.
	@param SpanEndOffsetX number -- Current span end pixel offset.
	@return (number, number) -- Clipped (SpanStartOffsetX, SpanEndOffsetX).
]=]
function MathModule.ClipSpanEdge(
	RowEdgeWeight: number,
	EdgeStepX: number,
	SpanStartOffsetX: number,
	SpanEndOffsetX: number
): (number, number)
	if EdgeStepX == 0 then
		if RowEdgeWeight < 0 then
			return 1, 0
		end
		return SpanStartOffsetX, SpanEndOffsetX
	end

	if EdgeStepX > 0 then
		if RowEdgeWeight < 0 then
			return math.max(SpanStartOffsetX, (-RowEdgeWeight + EdgeStepX - 1) // EdgeStepX), SpanEndOffsetX
		end
		return SpanStartOffsetX, SpanEndOffsetX
	end

	if RowEdgeWeight < 0 then
		return 1, 0
	end

	return SpanStartOffsetX, math.min(SpanEndOffsetX, RowEdgeWeight // -EdgeStepX)
end

--[=[
	Rasterizes a 2D screen-space triangle into the color pixel and Z depth buffers.
	@param Vertex0X number -- Screen vertex 0 X.
	@param Vertex0Y number -- Screen vertex 0 Y.
	@param ScaledInverseZ0 number -- Pre-scaled 1/Z depth for vertex 0.
	@param Vertex1X number -- Screen vertex 1 X.
	@param Vertex1Y number -- Screen vertex 1 Y.
	@param ScaledInverseZ1 number -- Pre-scaled 1/Z depth for vertex 1.
	@param Vertex2X number -- Screen vertex 2 X.
	@param Vertex2Y number -- Screen vertex 2 Y.
	@param ScaledInverseZ2 number -- Pre-scaled 1/Z depth for vertex 2.
	@param PackedColor number -- Packed 32-bit RGBA color.
	@param WIDTH number -- Target framebuffer width.
	@param HEIGHT number -- Target framebuffer height.
	@param RowStride number -- Byte stride per horizontal scanline row.
	@param PixelBuffer buffer -- Destination color pixel buffer.
	@param ZBuffer buffer -- Destination 32-bit float Z-buffer.
	@return (number, number) -- Modified scanline row range (MinY, MaxY).
]=]
function MathModule.RasterizeTriangleSpan(
	Vertex0X: number,
	Vertex0Y: number,
	ScaledInverseZ0: number,
	Vertex1X: number,
	Vertex1Y: number,
	ScaledInverseZ1: number,
	Vertex2X: number,
	Vertex2Y: number,
	ScaledInverseZ2: number,
	PackedColor: number,
	WIDTH: number,
	HEIGHT: number,
	RowStride: number,
	PixelBuffer: buffer,
	ZBuffer: buffer
): (number, number)
	const MinX = math.max(0, math.min(Vertex0X, Vertex1X, Vertex2X)) :: number
	const MaxX = math.min(WIDTH - 1, math.max(Vertex0X, Vertex1X, Vertex2X)) :: number
	const MinY = math.max(0, math.min(Vertex0Y, Vertex1Y, Vertex2Y)) :: number
	const MaxY = math.min(HEIGHT - 1, math.max(Vertex0Y, Vertex1Y, Vertex2Y)) :: number

	if MinX > MaxX or MinY > MaxY then
		return HEIGHT, -1
	end

	const Edge0StepX = Vertex2Y - Vertex1Y :: number
	const Edge1StepX = Vertex0Y - Vertex2Y :: number
	const Edge2StepX = Vertex1Y - Vertex0Y :: number
	const Edge0StepY = Vertex1X - Vertex2X :: number
	const Edge1StepY = Vertex2X - Vertex0X :: number
	const Edge2StepY = Vertex0X - Vertex1X :: number

	const ScaledInverseZVector = vector.create(ScaledInverseZ0, ScaledInverseZ1, ScaledInverseZ2)
	const EdgeStepVectorX = vector.create(Edge0StepX, Edge1StepX, Edge2StepX)
	const EdgeStepVectorY = vector.create(Edge0StepY, Edge1StepY, Edge2StepY)

	const InverseZStepX = vector.dot(EdgeStepVectorX, ScaledInverseZVector) :: number
	const InverseZStepY = vector.dot(EdgeStepVectorY, ScaledInverseZVector) :: number

	const InitialEdgeWeight0 = (MinX - Vertex1X) * Edge0StepX + (MinY - Vertex1Y) * Edge0StepY :: number
	const InitialEdgeWeight1 = (MinX - Vertex2X) * Edge1StepX + (MinY - Vertex2Y) * Edge1StepY :: number
	const InitialEdgeWeight2 = (MinX - Vertex0X) * Edge2StepX + (MinY - Vertex0Y) * Edge2StepY :: number
	local RowEdgeWeights = vector.create(InitialEdgeWeight0, InitialEdgeWeight1, InitialEdgeWeight2)
	local RowInverseZ = vector.dot(RowEdgeWeights, ScaledInverseZVector) :: number

	const MaxSpanOffsetX = MaxX - MinX :: number
	local RowOffset = (MinY * WIDTH + MinX) * 4 :: number

	for _ = MinY, MaxY do
		local SpanStartOffsetX: number, SpanEndOffsetX: number =
			MathModule.ClipSpanEdge(RowEdgeWeights.x, Edge0StepX, 0, MaxSpanOffsetX)
		if SpanStartOffsetX <= SpanEndOffsetX then
			SpanStartOffsetX, SpanEndOffsetX =
				MathModule.ClipSpanEdge(RowEdgeWeights.y, Edge1StepX, SpanStartOffsetX, SpanEndOffsetX)
		end
		if SpanStartOffsetX <= SpanEndOffsetX then
			SpanStartOffsetX, SpanEndOffsetX =
				MathModule.ClipSpanEdge(RowEdgeWeights.z, Edge2StepX, SpanStartOffsetX, SpanEndOffsetX)
		end

		if SpanStartOffsetX <= SpanEndOffsetX then
			local BufferOffset = RowOffset + SpanStartOffsetX * 4 :: number
			const EndOffset = RowOffset + SpanEndOffsetX * 4 :: number
			local InterpolatedInverseZ = RowInverseZ + SpanStartOffsetX * InverseZStepX :: number

			while BufferOffset <= EndOffset do
				if InterpolatedInverseZ > buffer.readf32(ZBuffer, BufferOffset) then
					buffer.writef32(ZBuffer, BufferOffset, InterpolatedInverseZ)
					buffer.writeu32(PixelBuffer, BufferOffset, PackedColor)
				end

				InterpolatedInverseZ += InverseZStepX
				BufferOffset += 4
			end
		end

		RowEdgeWeights += EdgeStepVectorY
		RowInverseZ += InverseZStepY
		RowOffset += RowStride
	end

	return MinY, MaxY
end

return MathModule
