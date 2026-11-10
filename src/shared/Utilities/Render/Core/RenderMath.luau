--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Modules --
const MathModule = require(ReplicatedStorage.Shared.Utilities.Render.Core.MathModule) :: ModuleScript

-- Configs --
const NEAR_CLIP = 0.4 :: number
const FAR_CLIP = 1000 :: number
const GUARD_BAND_SCALE = 2 :: number

local RenderMath = {}

-- ============================================================================
-- 1. FUNCTIONS - RENDERING MATH
-- ============================================================================

function RenderMath.GetPartCameraVertices(
	Position: Vector3,
	LookVector: Vector3,
	UpVector: Vector3,
	RightVector: Vector3,
	Size: Vector3,
	CameraVertices: buffer,
	CamPosition: Vector3,
	CamRight: Vector3,
	CamUp: Vector3,
	CamLook: Vector3
): boolean
	const Hx: number, Hy: number, Hz: number = Size.X * 0.5, Size.Y * 0.5, Size.Z * 0.5

	const RelX = Position.X - CamPosition.X :: number
	const RelY = Position.Y - CamPosition.Y :: number
	const RelZ = Position.Z - CamPosition.Z :: number

	const CamRightX: number, CamRightY: number, CamRightZ: number = CamRight.X, CamRight.Y, CamRight.Z
	const CamUpX: number, CamUpY: number, CamUpZ: number = CamUp.X, CamUp.Y, CamUp.Z
	const CamLookX: number, CamLookY: number, CamLookZ: number = CamLook.X, CamLook.Y, CamLook.Z

	const Cx = RelX * CamRightX + RelY * CamRightY + RelZ * CamRightZ :: number
	const Cy = RelX * CamUpX + RelY * CamUpY + RelZ * CamUpZ :: number
	const Cz = RelX * CamLookX + RelY * CamLookY + RelZ * CamLookZ :: number

	const RWorldX: number, RWorldY: number, RWorldZ: number = RightVector.X * Hx, RightVector.Y * Hx, RightVector.Z * Hx
	const Rz = RWorldX * CamLookX + RWorldY * CamLookY + RWorldZ * CamLookZ :: number

	const UWorldX: number, UWorldY: number, UWorldZ: number = UpVector.X * Hy, UpVector.Y * Hy, UpVector.Z * Hy
	const Uz = UWorldX * CamLookX + UWorldY * CamLookY + UWorldZ * CamLookZ :: number

	const LWorldX: number, LWorldY: number, LWorldZ: number = LookVector.X * Hz, LookVector.Y * Hz, LookVector.Z * Hz
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
			const Z = buffer.readf32(ClipBufferA, Offset + 8) :: number
			buffer.writef32(ProjectedVertices, Offset, math.floor((X / Z) * FocalLength + WIDTH * 0.5))
			buffer.writef32(ProjectedVertices, Offset + 4, math.floor((-Y / Z) * FocalLength + HEIGHT * 0.5))
			buffer.writef32(ProjectedVertices, Offset + 8, Z)
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
		const Z = buffer.readf32(Output, Offset + 8) :: number
		buffer.writef32(ProjectedVertices, Offset, math.floor((X / Z) * FocalLength + WIDTH * 0.5))
		buffer.writef32(ProjectedVertices, Offset + 4, math.floor((-Y / Z) * FocalLength + HEIGHT * 0.5))
		buffer.writef32(ProjectedVertices, Offset + 8, Z)
	end

	return VertexCount
end

-- ============================================================================
-- 2. DRAWING OBJECTS - DRAWING TRIANGLES
-- ============================================================================

function RenderMath.DrawTriangle(
	V0: Vector3,
	V1: Vector3,
	V2: Vector3,
	R: number,
	G: number,
	B: number,
	WIDTH: number,
	HEIGHT: number,
	PixelBuffer: buffer,
	ZBuffer: buffer
)
	const X0: number, Y0: number, Z0: number = V0.X, V0.Y, V0.Z
	const X1: number, Y1: number, Z1: number = V1.X, V1.Y, V1.Z
	const X2: number, Y2: number, Z2: number = V2.X, V2.Y, V2.Z

	const Area = MathModule.EdgeFunction(X0, Y0, X1, Y1, X2, Y2) :: number
	if Area == 0 then
		return
	end

	const MinX = math.max(0, math.min(X0, X1, X2)) :: number
	const MaxX = math.min(WIDTH - 1, math.max(X0, X1, X2)) :: number
	const MinY = math.max(0, math.min(Y0, Y1, Y2)) :: number
	const MaxY = math.min(HEIGHT - 1, math.max(Y0, Y1, Y2)) :: number

	if MinX > MaxX or MinY > MaxY then
		return
	end

	-- Define how many pixels the object (Triangle) covers
	const InvArea = 1 / Area :: number
	const ScaledInvZ0 = (1 / Z0) * InvArea :: number
	const ScaledInvZ1 = (1 / Z1) * InvArea :: number
	const ScaledInvZ2 = (1 / Z2) * InvArea :: number

	const Edge0X = Y2 - Y1 :: number
	const Edge1X = Y0 - Y2 :: number
	const Edge2X = Y1 - Y0 :: number
	const Edge0Y = X1 - X2 :: number
	const Edge1Y = X2 - X0 :: number
	const Edge2Y = X0 - X1 :: number

	const StepInvZX = Edge0X * ScaledInvZ0 + Edge1X * ScaledInvZ1 + Edge2X * ScaledInvZ2 :: number
	const StepInvZY = Edge0Y * ScaledInvZ0 + Edge1Y * ScaledInvZ1 + Edge2Y * ScaledInvZ2 :: number

	local RowW0 = MathModule.EdgeFunction(X1, Y1, X2, Y2, MinX, MinY) :: number
	local RowW1 = MathModule.EdgeFunction(X2, Y2, X0, Y0, MinX, MinY) :: number
	local RowW2 = MathModule.EdgeFunction(X0, Y0, X1, Y1, MinX, MinY) :: number
	local RowInvZ = RowW0 * ScaledInvZ0 + RowW1 * ScaledInvZ1 + RowW2 * ScaledInvZ2 :: number

	const PackedColor = bit32.bor(R, bit32.lshift(G, 8), bit32.lshift(B, 16), 0xFF000000) :: number
	const RowStride = WIDTH * 4 :: number
	local RowOffset = (MinY * WIDTH + MinX) * 4 :: number

	for Y: number = MinY, MaxY do
		local W0 = RowW0
		local W1 = RowW1
		local W2 = RowW2
		local InterpolatedInvZ = RowInvZ
		local BufferOffset = RowOffset
		local EnteredSpan = false :: boolean

		for X: number = MinX, MaxX do
			-- Check if the object (triangle) is visible
			if W0 >= 0 and W1 >= 0 and W2 >= 0 then
				EnteredSpan = true

				if InterpolatedInvZ > buffer.readf32(ZBuffer, BufferOffset) then -- Checks if the pixel is closer to the camera
					buffer.writef32(ZBuffer, BufferOffset, InterpolatedInvZ)
					buffer.writeu32(PixelBuffer, BufferOffset, PackedColor)
				end
			elseif EnteredSpan then
				break
			end

			W0 += Edge0X
			W1 += Edge1X
			W2 += Edge2X
			InterpolatedInvZ += StepInvZX
			BufferOffset += 4
		end

		RowW0 += Edge0Y
		RowW1 += Edge1Y
		RowW2 += Edge2Y
		RowInvZ += StepInvZY
		RowOffset += RowStride
	end
end

return RenderMath
