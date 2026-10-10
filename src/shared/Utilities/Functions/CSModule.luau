--!native
--!optimize 2
local TouchInputService = game:GetService("TouchInputService")

local CsModule = {}

local BufferHelper = require(game.ReplicatedStorage.Shared.Utilities.BufferHelper)
local MathModule = require(game.ReplicatedStorage.Shared.Utilities.Functions.MathModule)

function CsModule.CellulAutoRndr(
	MinX: number,
	MaxX: number,
	MinY: number,
	MaxY: number,

	X0: number,
	X1: number,
	X2: number,
	Y0: number,
	Y1: number,
	Y2: number,

	InvArea: number,
	invZ0: number,
	invZ1: number,
	invZ2: number,

	R: number,
	G: number,
	B: number,

	WIDTH: number,
	HEIGHT: number,

	PixelBuffer: buffer,
	FRSBuffer: buffer,
	ZBuffer: buffer
)
	local Visited = {} :: { [number]: boolean }

	for Y = MinY, MaxY do
		for X = MinX, MaxX do
			const PixelIndex = Y * WIDTH + X
			if Visited[PixelIndex] then
				continue
			end

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
					BufferHelper.BufferPixelWrite(PixelBuffer, bufferOffset, R, G, B, 255)
					SpreadSeed(
						X,
						Y,
						MinX,
						MaxX,
						MinY,
						MaxY,
						X0,
						X1,
						X2,
						Y0,
						Y1,
						Y2,
						InvArea,
						invZ0,
						invZ1,
						invZ2,
						R,
						G,
						B,
						WIDTH,
						HEIGHT,
						PixelBuffer,
						FRSBuffer,
						ZBuffer,
						Visited
					)
				end
			end
		end
	end
end

return CsModule
