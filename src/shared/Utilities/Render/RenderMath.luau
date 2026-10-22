--!native
--!optimize 2

local HelperFunction = {}
local NEAR_CLIP = 0.4
local FAR_CLIP = 1000
local GUARD_BAND_SCALE = 2

-- Modules --
local BufferHelper = require(game.ReplicatedStorage.Shared.Utilities.BufferHelper) :: ModuleScript
local MathModule = require(game.ReplicatedStorage.Shared.Utilities.Functions.MathModule) :: ModuleScript

-- ============================================================================
-- 1. FUNCTIONS - RENDERING MATH
-- ============================================================================

-- Gets the vertices of a part in 3D space
function HelperFunction.GetPartWorldVertices(
	Position: Vector3,
	LookVector: Vector3,
	UpVector: Vector3,
	RightVector: Vector3,
	Size: Vector3,

	ScreenVertice: {},
	CamPosition: Vector3,
	CamRight: Vector3,
	CamUp: Vector3,
	CamLook: Vector3,
	FovY: number,
	WIDTH: number,
	HEIGHT: number
) -- Is local number only memory offset, wont get updated
	-- Define matrix data
	const Hx: number, Hy: number, Hz: number = Size.X * 0.5, Size.Y * 0.5, Size.Z * 0.5

	local function TransformPoint(lx: number, ly: number, lz: number): Vector3
		return Position + (RightVector * lx) + (UpVector * ly) - (LookVector * lz)
	end

	-- Convert 3D to 2D and store it in our vertices table, Vector3's
	local v1 = TransformPoint(-Hx, -Hy, -Hz)
	local v2 = TransformPoint(Hx, -Hy, -Hz)
	local v3 = TransformPoint(Hx, Hy, -Hz)
	local v4 = TransformPoint(-Hx, Hy, -Hz)
	local v5 = TransformPoint(-Hx, -Hy, Hz)
	local v6 = TransformPoint(Hx, -Hy, Hz)
	local v7 = TransformPoint(Hx, Hy, Hz)
	local v8 = TransformPoint(-Hx, Hy, Hz)

	-- Project world vertices to screen space
	ScreenVertice[1] =
		HelperFunction.ProjectWorldPointToScreen(v1, CamPosition, CamRight, CamUp, CamLook, FovY, WIDTH, HEIGHT)
	ScreenVertice[2] =
		HelperFunction.ProjectWorldPointToScreen(v2, CamPosition, CamRight, CamUp, CamLook, FovY, WIDTH, HEIGHT)
	ScreenVertice[3] =
		HelperFunction.ProjectWorldPointToScreen(v3, CamPosition, CamRight, CamUp, CamLook, FovY, WIDTH, HEIGHT)
	ScreenVertice[4] =
		HelperFunction.ProjectWorldPointToScreen(v4, CamPosition, CamRight, CamUp, CamLook, FovY, WIDTH, HEIGHT)
	ScreenVertice[5] =
		HelperFunction.ProjectWorldPointToScreen(v5, CamPosition, CamRight, CamUp, CamLook, FovY, WIDTH, HEIGHT)
	ScreenVertice[6] =
		HelperFunction.ProjectWorldPointToScreen(v6, CamPosition, CamRight, CamUp, CamLook, FovY, WIDTH, HEIGHT)
	ScreenVertice[7] =
		HelperFunction.ProjectWorldPointToScreen(v7, CamPosition, CamRight, CamUp, CamLook, FovY, WIDTH, HEIGHT)
	ScreenVertice[8] =
		HelperFunction.ProjectWorldPointToScreen(v8, CamPosition, CamRight, CamUp, CamLook, FovY, WIDTH, HEIGHT)
end

-- Projects a point in 3D space to 2D screen space
function HelperFunction.ProjectWorldPointToScreen(
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

function HelperFunction.GetPartCameraVertices(
	Position: Vector3,
	LookVector: Vector3,
	UpVector: Vector3,
	RightVector: Vector3,
	Size: Vector3,
	CameraVertices: { Vector3 },
	CamPosition: Vector3,
	CamRight: Vector3,
	CamUp: Vector3,
	CamLook: Vector3
)
	const Hx: number, Hy: number, Hz: number = Size.X * 0.5, Size.Y * 0.5, Size.Z * 0.5

	local function TransformPoint(LX: number, LY: number, LZ: number): Vector3
		local WorldPoint = Position + RightVector * LX + UpVector * LY - LookVector * LZ
		local Relative = WorldPoint - CamPosition

		return Vector3.new(
			Relative.X * CamRight.X + Relative.Y * CamRight.Y + Relative.Z * CamRight.Z,
			Relative.X * CamUp.X + Relative.Y * CamUp.Y + Relative.Z * CamUp.Z,
			Relative.X * CamLook.X + Relative.Y * CamLook.Y + Relative.Z * CamLook.Z
		)
	end

	CameraVertices[1] = TransformPoint(-Hx, -Hy, -Hz)
	CameraVertices[2] = TransformPoint(Hx, -Hy, -Hz)
	CameraVertices[3] = TransformPoint(Hx, Hy, -Hz)
	CameraVertices[4] = TransformPoint(-Hx, Hy, -Hz)
	CameraVertices[5] = TransformPoint(-Hx, -Hy, Hz)
	CameraVertices[6] = TransformPoint(Hx, -Hy, Hz)
	CameraVertices[7] = TransformPoint(Hx, Hy, Hz)
	CameraVertices[8] = TransformPoint(-Hx, Hy, Hz)
end

local function ClipPolygon(
	Input: { Vector3 },
	InputCount: number,
	Output: { Vector3 },
	PlaneX: number,
	PlaneY: number,
	PlaneZ: number,
	PlaneOffset: number
): number
	table.clear(Output)
	if InputCount == 0 then
		return 0
	end

	local OutputCount = 0
	local Previous = Input[InputCount]
	local PreviousDistance = Previous.X * PlaneX + Previous.Y * PlaneY + Previous.Z * PlaneZ + PlaneOffset

	for i = 1, InputCount do
		local Current = Input[i]
		local CurrentDistance = Current.X * PlaneX + Current.Y * PlaneY + Current.Z * PlaneZ + PlaneOffset
		local PreviousInside = PreviousDistance >= 0
		local CurrentInside = CurrentDistance >= 0

		if PreviousInside ~= CurrentInside then
			local T = PreviousDistance / (PreviousDistance - CurrentDistance)
			OutputCount += 1
			Output[OutputCount] = Previous + (Current - Previous) * T
		end

		if CurrentInside then
			OutputCount += 1
			Output[OutputCount] = Current
		end

		Previous = Current
		PreviousDistance = CurrentDistance
	end

	return OutputCount
end

function HelperFunction.ClipAndProjectTriangle(
	V0: Vector3,
	V1: Vector3,
	V2: Vector3,
	ProjectedVertices: { Vector3 },
	ClipBufferA: { Vector3 },
	ClipBufferB: { Vector3 },
	FovY: number,
	WIDTH: number,
	HEIGHT: number
): number
	ClipBufferA[1] = V0
	ClipBufferA[2] = V1
	ClipBufferA[3] = V2

	const FocalLength = (HEIGHT * 0.5) / math.tan(math.rad(FovY) * 0.5) :: number
	const GuardBandX = (WIDTH * 0.5 * GUARD_BAND_SCALE) / FocalLength
	const GuardBandY = (HEIGHT * 0.5 * GUARD_BAND_SCALE) / FocalLength

	local FullyInside = true
	for i = 1, 3 do
		local Point = ClipBufferA[i]
		if Point.Z < NEAR_CLIP
			or Point.Z > FAR_CLIP
			or Point.X + GuardBandX * Point.Z < 0
			or -Point.X + GuardBandX * Point.Z < 0
			or Point.Y + GuardBandY * Point.Z < 0
			or -Point.Y + GuardBandY * Point.Z < 0
		then
			FullyInside = false
			break
		end
	end

	if FullyInside then
		for i = 1, 3 do
			local CameraPoint = ClipBufferA[i]
			ProjectedVertices[i] = Vector3.new(
				math.floor((CameraPoint.X / CameraPoint.Z) * FocalLength + WIDTH * 0.5),
				math.floor((-CameraPoint.Y / CameraPoint.Z) * FocalLength + HEIGHT * 0.5),
				CameraPoint.Z
			)
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
		local CameraPoint = Output[i]
		ProjectedVertices[i] = Vector3.new(
			math.floor((CameraPoint.X / CameraPoint.Z) * FocalLength + WIDTH * 0.5),
			math.floor((-CameraPoint.Y / CameraPoint.Z) * FocalLength + HEIGHT * 0.5),
			CameraPoint.Z
		)
	end

	return VertexCount
end

-- ============================================================================
-- 2. DRAWING OBJECTS - DRAWING TRIANGLES
-- ============================================================================

function HelperFunction.DrawTriangle(
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
		for X: number = MinX, MaxX do
			const W0 = MathModule.EdgeFunction(X1, Y1, X2, Y2, X, Y) :: number
			const W1 = MathModule.EdgeFunction(X2, Y2, X0, Y0, X, Y) :: number
			const W2 = MathModule.EdgeFunction(X0, Y0, X1, Y1, X, Y) :: number

			-- Check if the object (triangle) is visible
			if W0 >= 0 and W1 >= 0 and W2 >= 0 then
				const L0 = W0 * InvArea :: number
				const L1 = W1 * InvArea :: number
				const L2 = W2 * InvArea :: number

				const InterpolatedInvZ = L0 * invZ0 + L1 * invZ1 + L2 * invZ2 :: number
				const CurrentZ = MathModule.solveCurrentZ(InterpolatedInvZ, FRSBuffer) :: number -- Checks if the object is in front of the camera

				local XYWidth = Y * WIDTH + X :: number

				const bufferOffset = XYWidth * 4 :: number

				if CurrentZ < buffer.readf32(ZBuffer, bufferOffset) then -- Checks if the pixel is closer to the camera
					buffer.writef32(ZBuffer, bufferOffset, CurrentZ)
					BufferHelper.BufferPixelWrite(PixelBuffer, (XYWidth * 4), R, G, B, 255)
				end
			end
		end
	end
end

return HelperFunction
