--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

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

function MathModule.EdgeFunction(Ax: number, Ay: number, Bx: number, By: number, Px: number, Py: number): number
	return (Px - Ax) * (By - Ay) - (Py - Ay) * (Bx - Ax)
end

function MathModule.IsVertexInside(Vertex: vector, GuardBandX: number, GuardBandY: number): boolean
	const Z = Vertex.z :: number
	if Z < NEAR_CLIP or Z > FAR_CLIP then
		return false
	end

	return math.abs(Vertex.x) <= GuardBandX * Z and math.abs(Vertex.y) <= GuardBandY * Z
end

function MathModule.ProjectVertex(
	ProjectedVertices: buffer,
	Offset: number,
	Vertex: vector,
	FocalLength: number,
	HalfWidth: number,
	HalfHeight: number
)
	const InvZ = 1 / Vertex.z :: number
	buffer.writef32(ProjectedVertices, Offset, math.floor(Vertex.x * InvZ * FocalLength + HalfWidth))
	buffer.writef32(ProjectedVertices, Offset + 4, math.floor(-Vertex.y * InvZ * FocalLength + HalfHeight))
	buffer.writef32(ProjectedVertices, Offset + 8, InvZ)
end

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
	local Previous = BufferHelper.ReadVec3(Input, (InputCount - 1) * 12)
	local PreviousDistance = vector.dot(Previous, PlaneNormal) + PlaneOffset :: number

	for i = 1, InputCount do
		const Current = BufferHelper.ReadVec3(Input, (i - 1) * 12)
		const CurrentDistance = vector.dot(Current, PlaneNormal) + PlaneOffset :: number
		const PreviousInside = PreviousDistance >= 0 :: boolean
		const CurrentInside = CurrentDistance >= 0 :: boolean

		if PreviousInside ~= CurrentInside then
			const T = PreviousDistance / (PreviousDistance - CurrentDistance) :: number
			BufferHelper.WriteVec3(Output, OutputCount * 12, Previous + (Current - Previous) * T)
			OutputCount += 1
		end

		if CurrentInside then
			BufferHelper.WriteVec3(Output, OutputCount * 12, Current)
			OutputCount += 1
		end

		Previous = Current
		PreviousDistance = CurrentDistance
	end

	return OutputCount
end

-- ============================================================================
-- 2. FUNCTIONS - EXACT SPAN RASTERIZATION MATH
-- ============================================================================

function MathModule.ClipSpanEdge(RowW: number, EdgeX: number, StartDX: number, EndDX: number): (number, number)
	if EdgeX == 0 then
		if RowW < 0 then
			return 1, 0
		end
		return StartDX, EndDX
	end

	if EdgeX > 0 then
		if RowW < 0 then
			return math.max(StartDX, (-RowW + EdgeX - 1) // EdgeX), EndDX
		end
		return StartDX, EndDX
	end

	if RowW < 0 then
		return 1, 0
	end

	return StartDX, math.min(EndDX, RowW // -EdgeX)
end

function MathModule.RasterizeTriangleSpan(
	X0: number,
	Y0: number,
	ScaledInvZ0: number,
	X1: number,
	Y1: number,
	ScaledInvZ1: number,
	X2: number,
	Y2: number,
	ScaledInvZ2: number,
	PackedColor: number,
	WIDTH: number,
	HEIGHT: number,
	RowStride: number,
	PixelBuffer: buffer,
	ZBuffer: buffer
): (number, number)
	const MinX = math.max(0, math.min(X0, X1, X2)) :: number
	const MaxX = math.min(WIDTH - 1, math.max(X0, X1, X2)) :: number
	const MinY = math.max(0, math.min(Y0, Y1, Y2)) :: number
	const MaxY = math.min(HEIGHT - 1, math.max(Y0, Y1, Y2)) :: number

	if MinX > MaxX or MinY > MaxY then
		return HEIGHT, -1
	end

	const Edge0X = Y2 - Y1 :: number
	const Edge1X = Y0 - Y2 :: number
	const Edge2X = Y1 - Y0 :: number
	const Edge0Y = X1 - X2 :: number
	const Edge1Y = X2 - X0 :: number
	const Edge2Y = X0 - X1 :: number

	const ScaledInvZVec = vector.create(ScaledInvZ0, ScaledInvZ1, ScaledInvZ2)
	const StepEdgeX = vector.create(Edge0X, Edge1X, Edge2X)
	const StepEdgeY = vector.create(Edge0Y, Edge1Y, Edge2Y)

	const StepInvZX = vector.dot(StepEdgeX, ScaledInvZVec) :: number
	const StepInvZY = vector.dot(StepEdgeY, ScaledInvZVec) :: number

	const RowW0 = (MinX - X1) * Edge0X + (MinY - Y1) * Edge0Y :: number
	const RowW1 = (MinX - X2) * Edge1X + (MinY - Y2) * Edge1Y :: number
	const RowW2 = (MinX - X0) * Edge2X + (MinY - Y0) * Edge2Y :: number
	local RowW = vector.create(RowW0, RowW1, RowW2)
	local RowInvZ = vector.dot(RowW, ScaledInvZVec) :: number

	const MaxSpanDX = MaxX - MinX :: number
	local RowOffset = (MinY * WIDTH + MinX) * 4 :: number

	for _ = MinY, MaxY do
		local StartDX: number, EndDX: number = MathModule.ClipSpanEdge(RowW.x, Edge0X, 0, MaxSpanDX)
		if StartDX <= EndDX then
			StartDX, EndDX = MathModule.ClipSpanEdge(RowW.y, Edge1X, StartDX, EndDX)
		end
		if StartDX <= EndDX then
			StartDX, EndDX = MathModule.ClipSpanEdge(RowW.z, Edge2X, StartDX, EndDX)
		end

		if StartDX <= EndDX then
			local BufferOffset = RowOffset + StartDX * 4 :: number
			const EndOffset = RowOffset + EndDX * 4 :: number
			local InterpolatedInvZ = RowInvZ + StartDX * StepInvZX :: number

			while BufferOffset <= EndOffset do
				if InterpolatedInvZ > buffer.readf32(ZBuffer, BufferOffset) then
					buffer.writef32(ZBuffer, BufferOffset, InterpolatedInvZ)
					buffer.writeu32(PixelBuffer, BufferOffset, PackedColor)
				end

				InterpolatedInvZ += StepInvZX
				BufferOffset += 4
			end
		end

		RowW += StepEdgeY
		RowInvZ += StepInvZY
		RowOffset += RowStride
	end

	return MinY, MaxY
end

return MathModule
