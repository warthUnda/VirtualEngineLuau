--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Modules --
const MathModule = require(ReplicatedStorage.Shared.Utilities.Render.Core.MathModule)

-- Configs --
const NEAR_CLIP = 0.4 :: number
const FAR_CLIP = 1000 :: number
const GUARD_BAND_SCALE = 2 :: number

local RenderMath = {}

-- ============================================================================
-- 1. FUNCTIONS - RENDERING MATH
-- ============================================================================

function RenderMath.GetPartCameraVertices(
	PosX: number,
	PosY: number,
	PosZ: number,
	LookX: number,
	LookY: number,
	LookZ: number,
	UpX: number,
	UpY: number,
	UpZ: number,
	RightX: number,
	RightY: number,
	RightZ: number,
	SizeX: number,
	SizeY: number,
	SizeZ: number,
	CameraVertices: buffer,
	CamPosX: number,
	CamPosY: number,
	CamPosZ: number,
	CamRightX: number,
	CamRightY: number,
	CamRightZ: number,
	CamUpX: number,
	CamUpY: number,
	CamUpZ: number,
	CamLookX: number,
	CamLookY: number,
	CamLookZ: number
): boolean
	const Hx: number, Hy: number, Hz: number = SizeX * 0.5, SizeY * 0.5, SizeZ * 0.5

	const RelX = PosX - CamPosX :: number
	const RelY = PosY - CamPosY :: number
	const RelZ = PosZ - CamPosZ :: number

	const Cx = RelX * CamRightX + RelY * CamRightY + RelZ * CamRightZ :: number
	const Cy = RelX * CamUpX + RelY * CamUpY + RelZ * CamUpZ :: number
	const Cz = RelX * CamLookX + RelY * CamLookY + RelZ * CamLookZ :: number

	const RWorldX: number, RWorldY: number, RWorldZ: number = RightX * Hx, RightY * Hx, RightZ * Hx
	const Rz = RWorldX * CamLookX + RWorldY * CamLookY + RWorldZ * CamLookZ :: number

	const UWorldX: number, UWorldY: number, UWorldZ: number = UpX * Hy, UpY * Hy, UpZ * Hy
	const Uz = UWorldX * CamLookX + UWorldY * CamLookY + UWorldZ * CamLookZ :: number

	const LWorldX: number, LWorldY: number, LWorldZ: number = LookX * Hz, LookY * Hz, LookZ * Hz
	const Lz = LWorldX * CamLookX + LWorldY * CamLookY + LWorldZ * CamLookZ :: number

	const ExtentZ = math.abs(Rz) + math.abs(Uz) + math.abs(Lz) :: number
	if Cz + ExtentZ < NEAR_CLIP or Cz - ExtentZ > FAR_CLIP then
		return false
	end

	const Rx = RWorldX * CamRightX + RWorldY * CamRightY + RWorldZ * CamRightZ :: number
	const Ry = RWorldX * CamUpX + RWorldY * CamUpY + RWorldZ * CamUpZ :: number

	const Ux = UWorldX * CamRightX + UWorldY * CamRightY + UWorldZ * CamRightZ :: number
	const Uy = UWorldX * CamUpX + UWorldY * CamUpY + UWorldZ * CamUpZ :: number

	const Lx = LWorldX * CamRightX + LWorldY * CamRightY + LWorldZ * CamRightZ :: number
	const Ly = LWorldX * CamUpX + LWorldY * CamUpY + LWorldZ * CamUpZ :: number

	-- Vertex 1: (-Hx, -Hy, -Hz) -> Center - R - U + L
	buffer.writef32(CameraVertices, 0, Cx - Rx - Ux + Lx)
	buffer.writef32(CameraVertices, 4, Cy - Ry - Uy + Ly)
	buffer.writef32(CameraVertices, 8, Cz - Rz - Uz + Lz)

	-- Vertex 2: (Hx, -Hy, -Hz) -> Center + R - U + L
	buffer.writef32(CameraVertices, 12, Cx + Rx - Ux + Lx)
	buffer.writef32(CameraVertices, 16, Cy + Ry - Uy + Ly)
	buffer.writef32(CameraVertices, 20, Cz + Rz - Uz + Lz)

	-- Vertex 3: (Hx, Hy, -Hz) -> Center + R + U + L
	buffer.writef32(CameraVertices, 24, Cx + Rx + Ux + Lx)
	buffer.writef32(CameraVertices, 28, Cy + Ry + Uy + Ly)
	buffer.writef32(CameraVertices, 32, Cz + Rz + Uz + Lz)

	-- Vertex 4: (-Hx, Hy, -Hz) -> Center - R + U + L
	buffer.writef32(CameraVertices, 36, Cx - Rx + Ux + Lx)
	buffer.writef32(CameraVertices, 40, Cy - Ry + Uy + Ly)
	buffer.writef32(CameraVertices, 44, Cz - Rz + Uz + Lz)

	-- Vertex 5: (-Hx, -Hy, Hz) -> Center - R - U - L
	buffer.writef32(CameraVertices, 48, Cx - Rx - Ux - Lx)
	buffer.writef32(CameraVertices, 52, Cy - Ry - Uy - Ly)
	buffer.writef32(CameraVertices, 56, Cz - Rz - Uz - Lz)

	-- Vertex 6: (Hx, -Hy, Hz) -> Center + R - U - L
	buffer.writef32(CameraVertices, 60, Cx + Rx - Ux - Lx)
	buffer.writef32(CameraVertices, 64, Cy + Ry - Uy - Ly)
	buffer.writef32(CameraVertices, 68, Cz + Rz - Uz - Lz)

	-- Vertex 7: (Hx, Hy, Hz) -> Center + R + U - L
	buffer.writef32(CameraVertices, 72, Cx + Rx + Ux - Lx)
	buffer.writef32(CameraVertices, 76, Cy + Ry + Uy - Ly)
	buffer.writef32(CameraVertices, 80, Cz + Rz + Uz - Lz)

	-- Vertex 8: (-Hx, Hy, Hz) -> Center - R + U - L
	buffer.writef32(CameraVertices, 84, Cx - Rx + Ux - Lx)
	buffer.writef32(CameraVertices, 88, Cy - Ry + Uy - Ly)
	buffer.writef32(CameraVertices, 92, Cz - Rz + Uz - Lz)

	return true
end

local function ClipPolygon(
	Input: buffer,
	InputCount: number,
	Output: buffer,
	PlaneX: number,
	PlaneY: number,
	PlaneZ: number,
	PlaneOffset: number
): number
	if InputCount == 0 then
		return 0
	end

	local OutputCount = 0 :: number
	local PreviousOffset = (InputCount - 1) * 12 :: number
	local PreviousX = buffer.readf32(Input, PreviousOffset) :: number
	local PreviousY = buffer.readf32(Input, PreviousOffset + 4) :: number
	local PreviousZ = buffer.readf32(Input, PreviousOffset + 8) :: number
	local PreviousDistance = PreviousX * PlaneX + PreviousY * PlaneY + PreviousZ * PlaneZ + PlaneOffset :: number

	for i = 1, InputCount do
		const CurrentOffset = (i - 1) * 12 :: number
		const CurrentX = buffer.readf32(Input, CurrentOffset) :: number
		const CurrentY = buffer.readf32(Input, CurrentOffset + 4) :: number
		const CurrentZ = buffer.readf32(Input, CurrentOffset + 8) :: number
		const CurrentDistance = CurrentX * PlaneX + CurrentY * PlaneY + CurrentZ * PlaneZ + PlaneOffset :: number
		const PreviousInside = PreviousDistance >= 0 :: boolean
		const CurrentInside = CurrentDistance >= 0 :: boolean

		if PreviousInside ~= CurrentInside then
			const T = PreviousDistance / (PreviousDistance - CurrentDistance) :: number
			OutputCount += 1
			const OutputOffset = (OutputCount - 1) * 12 :: number
			buffer.writef32(Output, OutputOffset, PreviousX + (CurrentX - PreviousX) * T)
			buffer.writef32(Output, OutputOffset + 4, PreviousY + (CurrentY - PreviousY) * T)
			buffer.writef32(Output, OutputOffset + 8, PreviousZ + (CurrentZ - PreviousZ) * T)
		end

		if CurrentInside then
			OutputCount += 1
			buffer.copy(Output, (OutputCount - 1) * 12, Input, CurrentOffset, 12)
		end

		PreviousX, PreviousY, PreviousZ = CurrentX, CurrentY, CurrentZ
		PreviousDistance = CurrentDistance
	end

	return OutputCount
end

function RenderMath.GetProjectionParameters(FovY: number, WIDTH: number, HEIGHT: number): (number, number, number)
	const FocalLength = (HEIGHT * 0.5) / math.tan(math.rad(FovY) * 0.5) :: number
	const GuardBandX = (WIDTH * 0.5 * GUARD_BAND_SCALE) / FocalLength :: number
	const GuardBandY = (HEIGHT * 0.5 * GUARD_BAND_SCALE) / FocalLength :: number
	return FocalLength, GuardBandX, GuardBandY
end

function RenderMath.ClipAndProjectTriangle(
	CameraVertices: buffer,
	V0Index: number,
	V1Index: number,
	V2Index: number,
	ProjectedVertices: buffer,
	ClipBufferA: buffer,
	ClipBufferB: buffer,
	FocalLength: number,
	GuardBandX: number,
	GuardBandY: number,
	WIDTH: number,
	HEIGHT: number
): number
	buffer.copy(ClipBufferA, 0, CameraVertices, (V0Index - 1) * 12, 12)
	buffer.copy(ClipBufferA, 12, CameraVertices, (V1Index - 1) * 12, 12)
	buffer.copy(ClipBufferA, 24, CameraVertices, (V2Index - 1) * 12, 12)

	local FullyInside = true :: boolean
	for i = 1, 3 do
		const Offset = (i - 1) * 12 :: number
		const X = buffer.readf32(ClipBufferA, Offset) :: number
		const Y = buffer.readf32(ClipBufferA, Offset + 4) :: number
		const Z = buffer.readf32(ClipBufferA, Offset + 8) :: number
		if
			Z < NEAR_CLIP
			or Z > FAR_CLIP
			or X + GuardBandX * Z < 0
			or -X + GuardBandX * Z < 0
			or Y + GuardBandY * Z < 0
			or -Y + GuardBandY * Z < 0
		then
			FullyInside = false
			break
		end
	end

	if FullyInside then
		for i = 1, 3 do
			const Offset = (i - 1) * 12 :: number
			const X = buffer.readf32(ClipBufferA, Offset) :: number
			const Y = buffer.readf32(ClipBufferA, Offset + 4) :: number
			const InvZ = 1 / buffer.readf32(ClipBufferA, Offset + 8) :: number
			buffer.writef32(ProjectedVertices, Offset, math.floor(X * InvZ * FocalLength + WIDTH * 0.5))
			buffer.writef32(ProjectedVertices, Offset + 4, math.floor(-Y * InvZ * FocalLength + HEIGHT * 0.5))
			buffer.writef32(ProjectedVertices, Offset + 8, InvZ)
		end
		return 3
	end

	local Input = ClipBufferA :: buffer
	local Output = ClipBufferB :: buffer
	local VertexCount = 3 :: number

	VertexCount = ClipPolygon(Input, VertexCount, Output, 0, 0, 1, -NEAR_CLIP)
	Input, Output = Output, Input
	VertexCount = ClipPolygon(Input, VertexCount, Output, 0, 0, -1, FAR_CLIP)
	Input, Output = Output, Input
	VertexCount = ClipPolygon(Input, VertexCount, Output, 1, 0, GuardBandX, 0)
	Input, Output = Output, Input
	VertexCount = ClipPolygon(Input, VertexCount, Output, -1, 0, GuardBandX, 0)
	Input, Output = Output, Input
	VertexCount = ClipPolygon(Input, VertexCount, Output, 0, 1, GuardBandY, 0)
	Input, Output = Output, Input
	VertexCount = ClipPolygon(Input, VertexCount, Output, 0, -1, GuardBandY, 0)

	for i = 1, VertexCount do
		const Offset = (i - 1) * 12 :: number
		const X = buffer.readf32(Output, Offset) :: number
		const Y = buffer.readf32(Output, Offset + 4) :: number
		const InvZ = 1 / buffer.readf32(Output, Offset + 8) :: number
		buffer.writef32(ProjectedVertices, Offset, math.floor(X * InvZ * FocalLength + WIDTH * 0.5))
		buffer.writef32(ProjectedVertices, Offset + 4, math.floor(-Y * InvZ * FocalLength + HEIGHT * 0.5))
		buffer.writef32(ProjectedVertices, Offset + 8, InvZ)
	end

	return VertexCount
end

-- ============================================================================
-- 2. DRAWING OBJECTS - DRAWING TRIANGLES
-- ============================================================================

function RenderMath.DrawTriangle(
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
	PixelBuffer: buffer,
	ZBuffer: buffer
)
	const MinX = math.max(0, math.min(X0, X1, X2)) :: number
	const MaxX = math.min(WIDTH - 1, math.max(X0, X1, X2)) :: number
	const MinY = math.max(0, math.min(Y0, Y1, Y2)) :: number
	const MaxY = math.min(HEIGHT - 1, math.max(Y0, Y1, Y2)) :: number

	-- Define how many pixels the object (Triangle) covers
	const Edge0X = Y2 - Y1 :: number
	const Edge1X = Y0 - Y2 :: number
	const Edge2X = Y1 - Y0 :: number
	const Edge0Y = X1 - X2 :: number
	const Edge1Y = X2 - X0 :: number
	const Edge2Y = X0 - X1 :: number

	const StepInvZX = Edge0X * ScaledInvZ0 + Edge1X * ScaledInvZ1 + Edge2X * ScaledInvZ2 :: number
	const StepInvZY = Edge0Y * ScaledInvZ0 + Edge1Y * ScaledInvZ1 + Edge2Y * ScaledInvZ2 :: number

	const StepEdgeX = vector.create(Edge0X, Edge1X, Edge2X)
	const StepEdgeY = vector.create(Edge0Y, Edge1Y, Edge2Y)

	const RowW0 = (MinX - X1) * Edge0X + (MinY - Y1) * Edge0Y :: number
	const RowW1 = (MinX - X2) * Edge1X + (MinY - Y2) * Edge1Y :: number
	const RowW2 = (MinX - X0) * Edge2X + (MinY - Y0) * Edge2Y :: number
	local RowW = vector.create(RowW0, RowW1, RowW2)
	local RowInvZ = RowW0 * ScaledInvZ0 + RowW1 * ScaledInvZ1 + RowW2 * ScaledInvZ2 :: number

	const RowStride = WIDTH * 4 :: number
	local RowOffset = (MinY * WIDTH + MinX) * 4 :: number

	for Y: number = MinY, MaxY do
		local W = RowW
		local InterpolatedInvZ = RowInvZ
		local BufferOffset = RowOffset
		local EnteredSpan = false :: boolean

		for X: number = MinX, MaxX do
			-- Check if the object (triangle) is visibles
			if W.x >= 0 and W.y >= 0 and W.z >= 0 then
				EnteredSpan = true

				if InterpolatedInvZ > buffer.readf32(ZBuffer, BufferOffset) then -- Checks if the pixel is closer to the camera
					buffer.writef32(ZBuffer, BufferOffset, InterpolatedInvZ)
					buffer.writeu32(PixelBuffer, BufferOffset, PackedColor)
				end
			elseif EnteredSpan then
				break
			end

			W += StepEdgeX
			InterpolatedInvZ += StepInvZX
			BufferOffset += 4
		end

		RowW += StepEdgeY
		RowInvZ += StepInvZY
		RowOffset += RowStride
	end
end

return RenderMath
