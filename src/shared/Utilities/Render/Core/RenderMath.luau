--!native
--!optimize 2

local RenderMath = {}
local NEAR_CLIP = 0.4
local FAR_CLIP = 1000
local GUARD_BAND_SCALE = 2

-- Modules --
local BufferHelper = require(game.ReplicatedStorage.Shared.Utilities.Render.Core.BufferHelper) :: ModuleScript
local MathModule = require(game.ReplicatedStorage.Shared.Utilities.Render.Core.MathModule) :: ModuleScript

-- ============================================================================
-- 1. FUNCTIONS - RENDERING MATH
-- ============================================================================

local function DivisibleBy4(n: number): boolean
	return bit32.band(n, 3) == 0
end

local function DivisibleBy2(n: number): boolean
	return bit32.band(n, 1) == 0
end

local function DivisibleBy3(n: number): boolean
	return bit32.band(n, 2) == 0
end

-- Projects a point in 3D space to 2D screen space
function RenderMath.ProjectWorldPointToScreen(
	WorldPoint: Vector3,
	CamPosition: Vector3,
	CamRight: Vector3,
	CamUp: Vector3,
	CamLook: Vector3,
	FovY: number,
	WIDTH: number,
	HEIGHT: number
)
	-- Transform the world point into camera space using custom math.
	-- Replaces CFrame:PointToObjectSpace so we don't rely on a native transform.

	const RelX = WorldPoint.X - CamPosition.X :: number
	const RelY = WorldPoint.Y - CamPosition.Y :: number
	const RelZ = WorldPoint.Z - CamPosition.Z :: number

	-- dot products against the orthonormal camera basis (local X, local Y, local Z)
	const LocalX = RelX * CamRight.X + RelY * CamRight.Y + RelZ * CamRight.Z :: number
	const LocalY = RelX * CamUp.X + RelY * CamUp.Y + RelZ * CamUp.Z :: number
	const LocalZ = -(RelX * CamLook.X + RelY * CamLook.Y + RelZ * CamLook.Z) :: number

	const Z = -LocalZ :: number
	if Z <= 0.4 then -- Checks if the point is behind the camera
		return nil
	end

	-- Convert to 2D coordinates, plus Z values
	const FovRad = math.rad(FovY) :: number
	const FocalLength = (HEIGHT * 0.5) / math.tan(FovRad * 0.5) :: number

	const ScreenX = math.floor((LocalX / Z) * FocalLength + (WIDTH * 0.5)) :: number
	const ScreenY = math.floor((-LocalY / Z) * FocalLength + (HEIGHT * 0.5)) :: number

	return Vector3.new(ScreenX, ScreenY, Z)
end

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
)
	const Hx: number, Hy: number, Hz: number = Size.X * 0.5, Size.Y * 0.5, Size.Z * 0.5

	local function TransformPoint(LX: number, LY: number, LZ: number, VertexIndex: number)
		local WorldPoint = Position + RightVector * LX + UpVector * LY - LookVector * LZ
		local Relative = WorldPoint - CamPosition

		local Offset = (VertexIndex - 1) * 12
		buffer.writef32(
			CameraVertices,
			Offset,
			Relative.X * CamRight.X + Relative.Y * CamRight.Y + Relative.Z * CamRight.Z
		)
		buffer.writef32(CameraVertices, Offset + 4, Relative.X * CamUp.X + Relative.Y * CamUp.Y + Relative.Z * CamUp.Z)
		buffer.writef32(
			CameraVertices,
			Offset + 8,
			Relative.X * CamLook.X + Relative.Y * CamLook.Y + Relative.Z * CamLook.Z
		)
	end

	TransformPoint(-Hx, -Hy, -Hz, 1)
	TransformPoint(Hx, -Hy, -Hz, 2)
	TransformPoint(Hx, Hy, -Hz, 3)
	TransformPoint(-Hx, Hy, -Hz, 4)
	TransformPoint(-Hx, -Hy, Hz, 5)
	TransformPoint(Hx, -Hy, Hz, 6)
	TransformPoint(Hx, Hy, Hz, 7)
	TransformPoint(-Hx, Hy, Hz, 8)
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

	local OutputCount = 0
	local PreviousOffset = (InputCount - 1) * 12
	local PreviousX = buffer.readf32(Input, PreviousOffset)
	local PreviousY = buffer.readf32(Input, PreviousOffset + 4)
	local PreviousZ = buffer.readf32(Input, PreviousOffset + 8)
	local PreviousDistance = PreviousX * PlaneX + PreviousY * PlaneY + PreviousZ * PlaneZ + PlaneOffset

	for i = 1, InputCount do
		local CurrentOffset = (i - 1) * 12
		local CurrentX = buffer.readf32(Input, CurrentOffset)
		local CurrentY = buffer.readf32(Input, CurrentOffset + 4)
		local CurrentZ = buffer.readf32(Input, CurrentOffset + 8)
		local CurrentDistance = CurrentX * PlaneX + CurrentY * PlaneY + CurrentZ * PlaneZ + PlaneOffset
		local PreviousInside = PreviousDistance >= 0
		local CurrentInside = CurrentDistance >= 0

		if PreviousInside ~= CurrentInside then
			local T = PreviousDistance / (PreviousDistance - CurrentDistance)
			OutputCount += 1
			local OutputOffset = (OutputCount - 1) * 12
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

function RenderMath.ClipAndProjectTriangle(
	CameraVertices: buffer,
	V0Index: number,
	V1Index: number,
	V2Index: number,
	ProjectedVertices: buffer,
	ClipBufferA: buffer,
	ClipBufferB: buffer,
	FovY: number,
	WIDTH: number,
	HEIGHT: number
): number
	buffer.copy(ClipBufferA, 0, CameraVertices, (V0Index - 1) * 12, 12)
	buffer.copy(ClipBufferA, 12, CameraVertices, (V1Index - 1) * 12, 12)
	buffer.copy(ClipBufferA, 24, CameraVertices, (V2Index - 1) * 12, 12)

	const FocalLength = (HEIGHT * 0.5) / math.tan(math.rad(FovY) * 0.5) :: number
	const GuardBandX = (WIDTH * 0.5 * GUARD_BAND_SCALE) / FocalLength
	const GuardBandY = (HEIGHT * 0.5 * GUARD_BAND_SCALE) / FocalLength

	local FullyInside = true
	for i = 1, 3 do
		local Offset = (i - 1) * 12
		local X = buffer.readf32(ClipBufferA, Offset)
		local Y = buffer.readf32(ClipBufferA, Offset + 4)
		local Z = buffer.readf32(ClipBufferA, Offset + 8)
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
			local Offset = (i - 1) * 12
			local X = buffer.readf32(ClipBufferA, Offset)
			local Y = buffer.readf32(ClipBufferA, Offset + 4)
			local Z = buffer.readf32(ClipBufferA, Offset + 8)
			buffer.writef32(ProjectedVertices, Offset, math.floor((X / Z) * FocalLength + WIDTH * 0.5))
			buffer.writef32(ProjectedVertices, Offset + 4, math.floor((-Y / Z) * FocalLength + HEIGHT * 0.5))
			buffer.writef32(ProjectedVertices, Offset + 8, Z)
		end
		return 3
	end

	local Input = ClipBufferA
	local Output = ClipBufferB
	local VertexCount = 3

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
		local Offset = (i - 1) * 12
		local X = buffer.readf32(Output, Offset)
		local Y = buffer.readf32(Output, Offset + 4)
		local Z = buffer.readf32(Output, Offset + 8)
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
	ZBuffer: buffer,
	FRSBuffer: buffer
)
	const X0: number, Y0: number, Z0: number = V0.X, V0.Y, V0.Z
	const X1: number, Y1: number, Z1: number = V1.X, V1.Y, V1.Z
	const X2: number, Y2: number, Z2: number = V2.X, V2.Y, V2.Z

	const Area = MathModule.EdgeFunction(X0, Y0, X1, Y1, X2, Y2) :: number
	-- Define how many pixels the object (Triangle) covers
	const invZ0: number, invZ1: number, invZ2: number = 1 / Z0, 1 / Z1, 1 / Z2

	const MinX = math.max(0, math.min(X0, X1, X2)) :: number
	const MaxX = math.min(WIDTH - 1, math.max(X0, X1, X2)) :: number
	const MinY = math.max(0, math.min(Y0, Y1, Y2)) :: number
	const MaxY = math.min(HEIGHT - 1, math.max(Y0, Y1, Y2)) :: number

	const InvArea = 1 / Area :: number

	-- Begin drawing the raw pixels (Fills a box)

	for Y: number = MinY, MaxY do
		const W00 = MathModule.EdgeFunction(X1, Y1, X2, Y2, MinX, Y) :: number
		const W10 = MathModule.EdgeFunction(X2, Y2, X0, Y0, MinX, Y) :: number
		const W20 = MathModule.EdgeFunction(X0, Y0, X1, Y1, MinX, Y) :: number

		const W01 = MathModule.EdgeFunction(X1, Y1, X2, Y2, MinX + 2, Y) :: number
		const W11 = MathModule.EdgeFunction(X2, Y2, X0, Y0, MinX + 2, Y) :: number
		const W21 = MathModule.EdgeFunction(X0, Y0, X1, Y1, MinX + 2, Y) :: number

		for X: number = MinX, MaxX do
			const XStep = (X - MinX) * 0.5 :: number
			const W0 = W00 + (W01 - W00) * XStep
			const W1 = W10 + (W11 - W10) * XStep
			const W2 = W20 + (W21 - W20) * XStep
			-- Check if the object (triangle) is visible
			if W0 >= 0 and W1 >= 0 and W2 >= 0 then
				const L0 = W0 * InvArea :: number
				const L1 = W1 * InvArea :: number
				const L2 = W2 * InvArea :: number

				const InterpolatedInvZ = L0 * invZ0 + L1 * invZ1 + L2 * invZ2 :: number
				const CurrentZ = MathModule.SolveCurrentZ(InterpolatedInvZ, FRSBuffer) :: number -- Checks if the object is in front of the camera

				const XYWidth = Y * WIDTH + X :: number
				const bufferOffset = XYWidth * 4 :: number

				if CurrentZ < buffer.readf32(ZBuffer, bufferOffset) then -- Checks if the pixel is closer to the camera
					buffer.writef32(ZBuffer, bufferOffset, CurrentZ)
					BufferHelper.BufferPixelWrite(PixelBuffer, bufferOffset, R, G, B, 255)
				end
			end
		end
	end
end

return RenderMath
