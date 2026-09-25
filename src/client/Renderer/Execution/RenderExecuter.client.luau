-- Services
local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- Screen Dimensions
local WIDTH = 320
local HEIGHT = 240
local TOTAL_PIXELS = WIDTH * HEIGHT
local BUFFER_SIZE = TOTAL_PIXELS * 4

local Player = game:GetService("Players").LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

-- References
local imageLabel = PlayerGui:WaitForChild("ScreenGui").ImageLabel
local camera = Workspace.CurrentCamera

local PartStore = require(game.StarterPlayer.StarterPlayerScripts.Client.Renderer.Stores.PartStores)

-- Output Screen EditableImage
local editableImage = AssetService:CreateEditableImage({
	Size = Vector2.new(WIDTH, HEIGHT),
})
imageLabel.ImageContent = Content.fromObject(editableImage)

-- Screen Buffers
local pixelBuffer = buffer.create(BUFFER_SIZE)
local zBuffer = table.create(TOTAL_PIXELS, 1000.0)

-- ============================================================================
-- 1. GEOMETRY SETUP
-- ============================================================================

local PART_TRIANGLES = {
	{ 1, 3, 2 },
	{ 1, 4, 3 }, -- Back
	{ 5, 6, 7 },
	{ 5, 7, 8 }, -- Front
	{ 1, 2, 6 },
	{ 1, 6, 5 }, -- Bottom
	{ 3, 4, 8 },
	{ 3, 8, 7 }, -- Top
	{ 1, 5, 8 },
	{ 1, 8, 4 }, -- Left
	{ 2, 3, 7 },
	{ 2, 7, 6 }, -- Right
}

local function getPartWorldVertices(part)
	local cf = part.CFrame
	local size = part.Size
	local hX, hY, hZ = size.X / 2, size.Y / 2, size.Z / 2

	return {
		cf * Vector3.new(-hX, -hY, -hZ),
		cf * Vector3.new(hX, -hY, -hZ),
		cf * Vector3.new(hX, hY, -hZ),
		cf * Vector3.new(-hX, hY, -hZ),
		cf * Vector3.new(-hX, -hY, hZ),
		cf * Vector3.new(hX, -hY, hZ),
		cf * Vector3.new(hX, hY, hZ),
		cf * Vector3.new(-hX, hY, hZ),
	}
end

local function projectWorldPointToScreen(worldPoint, camCFrame, fovY)
	local camLocalPoint = camCFrame:PointToObjectSpace(worldPoint)
	local z = -camLocalPoint.Z
	if z <= 0.1 then
		return nil
	end

	local fovRad = math.rad(fovY)
	local focalLength = (HEIGHT / 2) / math.tan(fovRad / 2)

	local screenX = math.floor((camLocalPoint.X / z) * focalLength + (WIDTH / 2))
	local screenY = math.floor((-camLocalPoint.Y / z) * focalLength + (HEIGHT / 2))

	return { screenX, screenY, z }
end

-- ============================================================================
-- 2. RASTERIZER (FLAT COLORED)
-- ============================================================================

local function clearBuffers()
	for i = 1, TOTAL_PIXELS do
		zBuffer[i] = 1000.0
		local offset = (i - 1) * 4
		buffer.writeu8(pixelBuffer, offset + 0, 15)
		buffer.writeu8(pixelBuffer, offset + 1, 15)
		buffer.writeu8(pixelBuffer, offset + 2, 20)
		buffer.writeu8(pixelBuffer, offset + 3, 255)
	end
end

local function edgeFunction(ax, ay, bx, by, px, py)
	return (px - ax) * (by - ay) - (py - ay) * (bx - ax)
end

local function drawTriangle(v0, v1, v2, r, g, b)
	local x0, y0, z0 = v0[1], v0[2], v0[3]
	local x1, y1, z1 = v1[1], v1[2], v1[3]
	local x2, y2, z2 = v2[1], v2[2], v2[3]

	local area = edgeFunction(x0, y0, x1, y1, x2, y2)
	if area <= 0 then
		return
	end

	local invZ0, invZ1, invZ2 = 1 / z0, 1 / z1, 1 / z2

	local minX = math.max(0, math.min(x0, x1, x2))
	local maxX = math.min(WIDTH - 1, math.max(x0, x1, x2))
	local minY = math.max(0, math.min(y0, y1, y2))
	local maxY = math.min(HEIGHT - 1, math.max(y0, y1, y2))

	for y = minY, maxY do
		for x = minX, maxX do
			local w0 = edgeFunction(x1, y1, x2, y2, x, y)
			local w1 = edgeFunction(x2, y2, x0, y0, x, y)
			local w2 = edgeFunction(x0, y0, x1, y1, x, y)

			if w0 >= 0 and w1 >= 0 and w2 >= 0 then
				local l0 = w0 / area
				local l1 = w1 / area
				local l2 = w2 / area

				local interpolatedInvZ = l0 * invZ0 + l1 * invZ1 + l2 * invZ2
				local currentZ = 1 / interpolatedInvZ

				local bufferIdx = (y * WIDTH + x) + 1

				if currentZ < zBuffer[bufferIdx] then
					zBuffer[bufferIdx] = currentZ

					local screenOffset = (y * WIDTH + x) * 4
					buffer.writeu8(pixelBuffer, screenOffset + 0, r)
					buffer.writeu8(pixelBuffer, screenOffset + 1, g)
					buffer.writeu8(pixelBuffer, screenOffset + 2, b)
					buffer.writeu8(pixelBuffer, screenOffset + 3, 255)
				end
			end
		end
	end
end

-- ============================================================================
-- 3. RENDER LOOP
-- ============================================================================

for i, targetPart: BasePart in pairs(game.Workspace:GetDescendants()) do
	if not targetPart:IsA("BasePart") then
		continue
	end
	targetPart.Transparency = 1
end

RunService.RenderStepped:Connect(function()
	clearBuffers()

	local PartArray = PartStore.ReturnArray()

	for i = 1, #PartArray do
		local targetPart = PartArray[i]

		if not targetPart then
			continue
		end

		local camCFrame = camera.CFrame
		local camFOV = camera.FieldOfView

		-- Fetch target part's current color (0-255 scale)
		local partColor = targetPart.Color
		local r = math.floor(partColor.R * 255)
		local g = math.floor(partColor.G * 255
		local b = math.floor(partColor.B * 255)

		local wrldVertices = getPartWorldVertice(targetPart)
		local screenVertices = {}

		for i, worldPos in ipairs(worldVertices) do
			screenVertices[i] = projectWorldPointToScreen(worldPos, camCFrame, camFOV)
		end

		for _, tri in ipairs(PART_TRIANGLES) do
			local v0 = screenVertices[tri[1]]
			local v1 = screenVertices[tri[2]]
			local v2 = screenVertices[tri[3]]

			if v0 and v1 and v2 the
				drawTriangle(v0, v1, v2, r, g, b
			end
		end
	end

	editableImage:WritePixelsBuffer(Vector2.zero, Vector2.new(WIDTH, HEIGHT), pixelBuffer)
end)
