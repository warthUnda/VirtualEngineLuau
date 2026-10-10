--!native
--!optimize 2

local HelperFunction = {}

-- Modules --
local BufferHelper = require(game.ReplicatedStorage.Shared.Utilities.BufferHelper) :: ModuleScript
local MathModule = require(game.ReplicatedStorage.Shared.Utilities.Functions.MathModule) :: ModuleScript
local CSModule = require(game.ReplicatedStorage.Shared.Utilities.Functions.CSModule)

-- Caching --
local Rad = math.rad
local Tan = math.tan
local Floor = math.floor

local Min = math.min
local Max = math.max

local Vector3New = Vector3.new

-- ============================================================================
-- 1. FUNCTIONS - RENDERING MATH
-- ============================================================================

-- Gets the vertices of a part in 3D space
function HelperFunction.GetPartWorldVertices(Part: Part, TargetTable: {}) -- Is local number only memory offset, wont get updated
	-- Define matrix data
	const CFrame = Part.CFrame :: CFrame
	const Size = Part.Size :: Vector3
	const Hx: number, Hy: number, Hz: number = Size.X * 0.5, Size.Y * 0.5, Size.Z * 0.5

	-- Convert 3D to 2D and store it in our vertices table, Vector3's
	TargetTable[1] = CFrame * Vector3New(-Hx, -Hy, -Hz)
	TargetTable[2] = CFrame * Vector3New(Hx, -Hy, -Hz)
	TargetTable[3] = CFrame * Vector3New(Hx, Hy, -Hz)
	TargetTable[4] = CFrame * Vector3New(-Hx, Hy, -Hz)
	TargetTable[5] = CFrame * Vector3New(-Hx, -Hy, Hz)
	TargetTable[6] = CFrame * Vector3New(Hx, -Hy, Hz)
	TargetTable[7] = CFrame * Vector3New(Hx, Hy, Hz)
	TargetTable[8] = CFrame * Vector3New(-Hx, Hy, Hz)
end

-- Projects a point in 3D space to 2D screen space
function HelperFunction.ProjectWorldPointToScreen(
	WorldPoint: Vector3,
	CamCFrame: CFrame,
	FovY: number,
	WIDTH: number,
	HEIGHT: number
)
	-- Transform the world point into camera space using custom math.
	-- Replaces CFrame:PointToObjectSpace so we don't rely on a native transform.
	const CamPos = CamCFrame.Position :: Vector3
	const RelX = WorldPoint.X - CamPos.X :: number
	const RelY = WorldPoint.Y - CamPos.Y :: number
	const RelZ = WorldPoint.Z - CamPos.Z :: number

	const Right = CamCFrame.RightVector :: Vector3
	const Up = CamCFrame.UpVector :: Vector3
	const Look = CamCFrame.LookVector :: Vector3

	-- dot products against the orthonormal camera basis (local X, local Y, local Z)
	const LocalX = RelX * Right.X + RelY * Right.Y + RelZ * Right.Z :: number
	const LocalY = RelX * Up.X + RelY * Up.Y + RelZ * Up.Z :: number
	const LocalZ = -(RelX * Look.X + RelY * Look.Y + RelZ * Look.Z) :: number

	const Z = -LocalZ :: number
	if Z <= 0.1 then -- Checks if the point is behind the camera
		return nil
	end

	-- Convert to 2D coordinates, plus Z values
	const FovRad = Rad(FovY) :: number
	const FocalLength = (HEIGHT * 0.5) / Tan(FovRad * 0.5) :: number

	const ScreenX = Floor((LocalX / Z) * FocalLength + (WIDTH * 0.5)) :: number
	const ScreenY = Floor((-LocalY / Z) * FocalLength + (HEIGHT * 0.5)) :: number

	return Vector3New(ScreenX, ScreenY, Z)
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
	FRSBuffer: buffer,
	BufferSuccessRate: buffer,
	SuccessOffset: number
)
	const X0: number, Y0: number, Z0: number = V0.X, V0.Y, V0.Z
	const X1: number, Y1: number, Z1: number = V1.X, V1.Y, V1.Z
	const X2: number, Y2: number, Z2: number = V2.X, V2.Y, V2.Z

	const Area = MathModule.EdgeFunction(X0, Y0, X1, Y1, X2, Y2) :: number
	-- Define how many pixels the object (Triangle) covers
	const invZ0: number, invZ1: number, invZ2: number = 1 / Z0, 1 / Z1, 1 / Z2

	const MinX = Max(0, Min(X0, X1, X2)) :: number
	const MaxX = Min(WIDTH - 1, Max(X0, X1, X2)) :: number
	const MinY = Max(0, Min(Y0, Y1, Y2)) :: number
	const MaxY = Min(HEIGHT - 1, Max(Y0, Y1, Y2)) :: number

	const InvArea = 1 / Area :: number

	local Count = 0 :: number

	const YHeight = MaxY - MinY :: number
	const XWidth = MaxX - MinX :: number
	math.abs(YHeight)
	math.abs(XWidth)

	local LastSuccessRate = buffer.readu8(BufferSuccessRate, SuccessOffset) :: number

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
					Count += 1
				end
			end
		end
	end

	-- Calculate the success rate and apply it to the buffers
	local totalPixels = (MaxX - MinX + 1) * (MaxY - MinY + 1)
	local successRate = math.round(Count / totalPixels * 100)
	buffer.writeu8(BufferSuccessRate, SuccessOffset, successRate)
end

return HelperFunction
