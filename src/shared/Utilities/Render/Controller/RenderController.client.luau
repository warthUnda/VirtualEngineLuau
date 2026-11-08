--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const AssetService = game:GetService("AssetService") :: AssetService
const RunService = game:GetService("RunService") :: RunService

-- Static References --
const Player = game:GetService("Players").LocalPlayer :: Player
const PlayerGui = Player:WaitForChild("PlayerGui") :: PlayerGui
const PlayerScripts = Player:WaitForChild("PlayerScripts") :: PlayerScripts

const ImageLabel = PlayerGui:WaitForChild("ScreenGui"):WaitForChild("ImageLabel") :: ImageLabel

const Camera = workspace.CurrentCamera :: Camera

const SelfActor = script.Parent :: Actor

-- Modules --
const BufferHelper = require(ReplicatedStorage.Shared.Utilities.Render.Core.BufferHelper) :: ModuleScript

const RenderConfigs = require(game.ReplicatedStorage.Shared.Utilities.Render.RenderConfigs) :: ModuleScript
const RenderMath = require(game.ReplicatedStorage.Shared.Utilities.Render.Core.RenderMath) :: ModuleScript
const MathModule = require(game.ReplicatedStorage.Shared.Utilities.Render.Core.MathModule) :: ModuleScript

const CameraStore = require(
	ReplicatedStorage:WaitForChild("Shared")
		:WaitForChild("Utilities")
		:WaitForChild("Render")
		:WaitForChild("Camera")
		:WaitForChild("CameraStore")
) :: ModuleScript

local CameraService = require(
	ReplicatedStorage:WaitForChild("Shared")
		:WaitForChild("Utilities")
		:WaitForChild("Render")
		:WaitForChild("Camera")
		:WaitForChild("CameraService")
)

const PartStore = require(script.Parent.PartStore) :: ModuleScript

-- Configs --
const WIDTH: number, HEIGHT: number = RenderConfigs.GetDimensions2D()
const TOTAL_PIXELS = WIDTH * HEIGHT :: number
const SUN_DIRECTION = Vector3.new(-0.4, 0.85, -0.35).Unit
const SUN_RAY_LENGTH = 15000
const AMBIENT_LIGHT = 0.3
const RAY_ORIGIN_BIAS = 0.05
const SHADOW_CACHE_REFRESH = 0.5
const SHADOW_CACHE_MOVE_EPSILON = 0.25
const MAX_SHADOW_RAYS_PER_FRAME = 8
const PART_VERTEX_SIGNS = {
	Vector3.new(-1, -1, -1),
	Vector3.new(1, -1, -1),
	Vector3.new(1, 1, -1),
	Vector3.new(-1, 1, -1),
	Vector3.new(-1, -1, 1),
	Vector3.new(1, -1, 1),
	Vector3.new(1, 1, 1),
	Vector3.new(-1, 1, 1),
}

const ActorCount = RenderConfigs.GetActorCount() :: number

local Received = 0 :: number
local CurrentFrame = 0 :: number

-- Tables --
local OffsetBuffer = buffer.create(ActorCount * 4) :: buffer
local BufferTable = {} :: { buffer }
local ScoreBuffer = buffer.create(ActorCount * 4) :: buffer

local PART_TRIANGLES = RenderConfigs.GetPartTriangles() :: buffer
local SphereVertices = RenderConfigs.GetSphereVertices() :: { Vector3 }

-- Buffers
const FinalPixel = buffer.create(TOTAL_PIXELS * 4) :: buffer
const FinalZ = buffer.create(TOTAL_PIXELS * 4) :: buffer
local WorldVertices = buffer.create(8 * 12)
local FaceIllumination = buffer.create(12 * 4)
local ShadowCacheParts = {} :: { BasePart }
local ShadowCachePositions = {} :: { Vector3 }
local ShadowCacheNormals = {} :: { Vector3 }
local ShadowCacheResults = {} :: { boolean }
local ShadowCacheUpdatedAt = {} :: { number }
local PendingShadowSamples = {} :: { number }
local PendingShadowOrigins = {} :: { Vector3 }
local PendingShadowNormals = {} :: { Vector3 }
local PendingShadowParts = {} :: { BasePart }
local ShadowRayParams = RaycastParams.new()
ShadowRayParams.FilterType = Enum.RaycastFilterType.Exclude
local ShadowRayExcludes = table.create(2) :: { Instance }
local ScreenVertices = buffer.create(8 * 12)
local ProjectedVertices = buffer.create(12 * 12)
local ClipBufferA = buffer.create(12 * 12)
local ClipBufferB = buffer.create(12 * 12)

local function ReadProjectedVertex(VertexIndex: number): Vector3
	local Offset = (VertexIndex - 1) * 12
	return Vector3.new(
		buffer.readf32(ProjectedVertices, Offset),
		buffer.readf32(ProjectedVertices, Offset + 4),
		buffer.readf32(ProjectedVertices, Offset + 8)
	)
end

local function QueueShadowSample(SampleIndex: number, Part: BasePart, Origin: Vector3, Normal: Vector3)
	if PendingShadowOrigins[SampleIndex] == nil then
		PendingShadowSamples[#PendingShadowSamples + 1] = SampleIndex
	end

	PendingShadowOrigins[SampleIndex] = Origin
	PendingShadowNormals[SampleIndex] = Normal
	PendingShadowParts[SampleIndex] = Part
end

-- Create Information Data for workers
for i = 1, ActorCount do
	BufferTable[i] = buffer.create(TOTAL_PIXELS * 32)
	buffer.writef32(ScoreBuffer, (i - 1) * 4, 0)
	buffer.writeu32(OffsetBuffer, (i - 1) * 4, 0)
end

-- Connecting Editable image to ImageLabel --
const EditableImage = AssetService:CreateEditableImage({ Size = Vector2.new(WIDTH, HEIGHT) }) :: EditableImage
ImageLabel.ImageContent = Content.fromObject(EditableImage) :: Content

CameraService:SetCameraHost()
CameraService:SetCameraView("FirstPerson")

-- Wait for the camera to initialize
task.spawn(function()
	-- Switch camera to scriptable so default controls don't override it
	Camera.CameraType = Enum.CameraType.Scriptable

	-- Set position: Y = -50000 (underground) or 50000 (sky)
	-- Looking straight ahead or down
	local targetPosition = Vector3.new(0, -50000, 0)
	Camera.CFrame = CFrame.new(targetPosition)
end)

-- ============================================================================
-- 1. LISTENER - LISTENS TO RETURNING DATA
-- ============================================================================

SelfActor:BindToMessage("Return Render Calculations", function(PixelBuffer: buffer, ZBuffer: buffer, FrameId: number)
	if FrameId ~= CurrentFrame then -- ignore stale frames
		return
	end

	for i = 1, TOTAL_PIXELS do -- Overwrites the FinalZ and FinalPixel buffers
		const Offset = (i - 1) * 4 :: number
		if buffer.readf32(ZBuffer, Offset) < buffer.readf32(FinalZ, Offset) then
			buffer.writef32(FinalZ, Offset, buffer.readf32(ZBuffer, Offset))
			buffer.writeu32(FinalPixel, Offset, buffer.readu32(PixelBuffer, Offset))
		end
	end

	Received += 1

	-- If all workers have returned their data, write it to the image
	if Received == ActorCount then
		EditableImage:WritePixelsBuffer(Vector2.zero, Vector2.new(WIDTH, HEIGHT), FinalPixel)
		Received = 0
	end
end)

-- ============================================================================
-- 2. GATHER DATA - SEND DATA TO WORKERS
-- ============================================================================

RunService.RenderStepped:Connect(function()
	-- Tables
	const PartSizeArray = PartStore.GetSizeArray() :: { Vector3 }
	const PartPositionArray = PartStore.GetPositionArray() :: { Vector3 }
	const PartInstanceArray = PartStore.GetInstanceArray() :: { BasePart }

	local PartLookVectorArray = PartStore.GetLookVectorArray() :: { Vector3 }
	local PartUpVectorArray = PartStore.GetUpVectorArray() :: { Vector3 }
	local PartRightVectorArray = PartStore.GetRightVectorArray() :: { Vector3 }

	local ColorArrayR = PartStore.GetColorArrayR() :: {}
	local ColorArrayG = PartStore.GetColorArrayG() :: {}
	local ColorArrayB = PartStore.GetColorArrayB() :: {}

	const CamTable = CameraStore.GetCameraTable()

	local CamPosition = CameraStore.GetCameraPosition()
	local CamRight = CameraStore.GetCameraRight()
	local CamUp = CameraStore.GetCameraUp()
	local CamLook = CameraStore.GetCameraLook()

	-- Configs
	const CamCFrame = CamTable.CameraCFrame :: CFrame
	const CamFOV = CamTable.CameraFOV :: number

	-- Pre loop Updates --
	BufferHelper.ClearBuffers(TOTAL_PIXELS, FinalPixel, FinalZ)

	CurrentFrame += 1
	Received = 0

	for i = 1, ActorCount do
		buffer.writef32(ScoreBuffer, (i - 1) * 4, 0)
	end

	table.clear(PendingShadowSamples)
	table.clear(PendingShadowOrigins)
	table.clear(PendingShadowNormals)
	table.clear(PendingShadowParts)
	local ShadowCacheTime = os.clock()

	-- Loop through all parts
	for i = 1, #PartPositionArray do
		const TargetPosition = PartPositionArray[i] :: Vector3
		local TargetPart = PartInstanceArray[i] :: BasePart?
		local LookVector = PartLookVectorArray[i] :: Vector3
		local UpVector = PartUpVectorArray[i] :: Vector3
		local RightVector = PartRightVectorArray[i] :: Vector3
		const TargetSize = PartSizeArray[i] :: Vector3

		const PartColorR = ColorArrayR[i] :: number
		const PartColorG = ColorArrayG[i] :: number
		const PartColorB = ColorArrayB[i] :: number

		-- 2.5 miliseconds part here:

		if not TargetPosition or not TargetSize or PartColorR == nil or PartColorG == nil or PartColorB == nil then
			continue
		end

		-- Variables
		local ShadedRHolder = math.floor(PartColorR * 255)
		local ShadedGHolder = math.floor(PartColorG * 255)
		local ShadedBHolder = math.floor(PartColorB * 255)

		local HalfX, HalfY, HalfZ = TargetSize.X * 0.5, TargetSize.Y * 0.5, TargetSize.Z * 0.5
		for VertexIndex = 1, 8 do
			local Signs = PART_VERTEX_SIGNS[VertexIndex]
			local WorldPosition = TargetPosition
				+ RightVector * (Signs.X * HalfX)
				+ UpVector * (Signs.Y * HalfY)
				- LookVector * (Signs.Z * HalfZ)
			local VertexOffset = (VertexIndex - 1) * 12
			buffer.writef32(WorldVertices, VertexOffset, WorldPosition.X)
			buffer.writef32(WorldVertices, VertexOffset + 4, WorldPosition.Y)
			buffer.writef32(WorldVertices, VertexOffset + 8, WorldPosition.Z)
		end

		for FaceIndex = 1, 6 do
			local TriangleOffset = (FaceIndex - 1) * 6
			local V0Index = buffer.readu8(PART_TRIANGLES, TriangleOffset)
			local V1Index = buffer.readu8(PART_TRIANGLES, TriangleOffset + 1)
			local V2Index = buffer.readu8(PART_TRIANGLES, TriangleOffset + 2)
			local V0Offset = (V0Index - 1) * 12
			local V1Offset = (V1Index - 1) * 12
			local V2Offset = (V2Index - 1) * 12
			local V0 = Vector3.new(
				buffer.readf32(WorldVertices, V0Offset),
				buffer.readf32(WorldVertices, V0Offset + 4),
				buffer.readf32(WorldVertices, V0Offset + 8)
			)
			local V1 = Vector3.new(
				buffer.readf32(WorldVertices, V1Offset),
				buffer.readf32(WorldVertices, V1Offset + 4),
				buffer.readf32(WorldVertices, V1Offset + 8)
			)
			local V2 = Vector3.new(
				buffer.readf32(WorldVertices, V2Offset),
				buffer.readf32(WorldVertices, V2Offset + 4),
				buffer.readf32(WorldVertices, V2Offset + 8)
			)
			local FaceNormal = (V1 - V0):Cross(V2 - V0).Unit
			local FaceCenter = (V0 + V1 + V2) * 0.33
			local Sunlight = math.max(0, FaceNormal:Dot(SUN_DIRECTION))
			local Illumination = AMBIENT_LIGHT + (1 - AMBIENT_LIGHT) * Sunlight

			local FirstTriangleIndex = (FaceIndex - 1) * 2 + 1
			local SecondTriangleIndex = FirstTriangleIndex + 1
			local CacheIndex = (i - 1) * 6 + FaceIndex
			local CachedShadow = false

			if Sunlight > 0 and TargetPart then
				if ShadowCacheParts[CacheIndex] ~= TargetPart then
					ShadowCacheParts[CacheIndex] = TargetPart
					ShadowCachePositions[CacheIndex] = nil
					ShadowCacheNormals[CacheIndex] = nil
					ShadowCacheResults[CacheIndex] = nil
					ShadowCacheUpdatedAt[CacheIndex] = nil
				end

				local CachedPosition = ShadowCachePositions[CacheIndex]
				local CachedNormal = ShadowCacheNormals[CacheIndex]
				local Moved = not CachedPosition
					or (FaceCenter - CachedPosition).Magnitude > SHADOW_CACHE_MOVE_EPSILON
					or not CachedNormal
					or FaceNormal:Dot(CachedNormal) < 0.99
				local UpdatedAt = ShadowCacheUpdatedAt[CacheIndex]
				local Expired = not UpdatedAt or ShadowCacheTime - UpdatedAt >= SHADOW_CACHE_REFRESH

				if Moved or Expired then
					QueueShadowSample(
						CacheIndex,
						TargetPart,
						FaceCenter + SUN_DIRECTION * RAY_ORIGIN_BIAS,
						FaceNormal
					)
				end
				CachedShadow = ShadowCacheResults[CacheIndex] == true
			end

			if CachedShadow then
				Illumination = AMBIENT_LIGHT
			end

			buffer.writef32(FaceIllumination, (FirstTriangleIndex - 1) * 4, Illumination)
			buffer.writef32(FaceIllumination, (SecondTriangleIndex - 1) * 4, Illumination)
		end

		-- 2.5 miliseconds part here:

		-- Updates
		RenderMath.GetPartCameraVertices(
			TargetPosition,
			LookVector,
			UpVector,
			RightVector,
			TargetSize,
			ScreenVertices,
			CamPosition,
			CamRight,
			CamUp,
			CamLook
		)

		-- Loop through all triangles
		-- 1.49 miliseconds part here:

		local MemoryOffset = 0

		for TriangleIndex = 1, 12 do
			local V0TRI = buffer.readu8(PART_TRIANGLES, MemoryOffset)
			MemoryOffset += 1
			local V1TRI = buffer.readu8(PART_TRIANGLES, MemoryOffset)
			MemoryOffset += 1
			local V2TRI = buffer.readu8(PART_TRIANGLES, MemoryOffset)
			MemoryOffset += 1

			local Illumination = buffer.readf32(FaceIllumination, (TriangleIndex - 1) * 4)
			local ShadedR = math.floor(ShadedRHolder * Illumination)
			local ShadedG = math.floor(ShadedGHolder * Illumination)
			local ShadedB = math.floor(ShadedBHolder * Illumination)

			local ClippedVertexCount = RenderMath.ClipAndProjectTriangle(
				ScreenVertices,
				V0TRI,
				V1TRI,
				V2TRI,
				ProjectedVertices,
				ClipBufferA,
				ClipBufferB,
				CamFOV,
				WIDTH,
				HEIGHT
			)

			for ClippedTriangleIndex = 2, ClippedVertexCount - 1 do
				const V0 = ReadProjectedVertex(1)
				const V1 = ReadProjectedVertex(ClippedTriangleIndex)
				const V2 = ReadProjectedVertex(ClippedTriangleIndex + 1)

				-- Variables
				const X0: number, Y0: number = V0.X, V0.Y
				const X1: number, Y1: number = V1.X, V1.Y
				const X2: number, Y2: number = V2.X, V2.Y

				const MinX = math.max(0, math.min(X0, X1, X2)) :: number
				const MaxX = math.min(WIDTH - 1, math.max(X0, X1, X2)) :: number
				const MinY = math.max(0, math.min(Y0, Y1, Y2)) :: number
				const MaxY = math.min(HEIGHT - 1, math.max(Y0, Y1, Y2)) :: number

				local Area = MathModule.EdgeFunction(X0, Y0, X1, Y1, X2, Y2)
				if Area <= 0.1 then
					continue
				end

				if MinX > MaxX or MinY > MaxY then
					continue
				end

				local Result = (MaxX - MinX + 1) * (MaxY - MinY + 1) :: number

				local SmallestValue = math.huge :: number
				local SVIndex = 0 :: number

				-- Find the smallest value then increase it
				for i = 1, ActorCount do
					const Score = buffer.readf32(ScoreBuffer, (i - 1) * 4) :: number

					if Score <= SmallestValue then
						SmallestValue = Score
						SVIndex = i
					end
				end

				-- Apply changes and create a information buffer for workers
				buffer.writef32(ScoreBuffer, (SVIndex - 1) * 4, SmallestValue + Result)
				const RBOffset = buffer.readu32(OffsetBuffer, (SVIndex - 1) * 4) :: number -- Render buffer memory offset
				const RenderBuffer = BufferTable[SVIndex] :: buffer

				local RenderResult = BufferHelper.CreateRenderBuffer(
					RenderBuffer,
					RBOffset,
					V0,
					V1,
					V2,
					ShadedR,
					ShadedG,
					ShadedB
				) :: number

				buffer.writeu32(OffsetBuffer, (SVIndex - 1) * 4, RenderResult)
			end
		end
	end

	local ShadowRayCount = math.min(#PendingShadowSamples, MAX_SHADOW_RAYS_PER_FRAME)
	for PendingIndex = 1, ShadowRayCount do
		local SampleIndex = PendingShadowSamples[PendingIndex]
		local TargetPart = PendingShadowParts[SampleIndex]
		ShadowRayExcludes[1] = TargetPart
		ShadowRayExcludes[2] = Player.Character
		ShadowRayParams.FilterDescendantsInstances = ShadowRayExcludes
		local RayOrigin = PendingShadowOrigins[SampleIndex]
		ShadowCacheResults[SampleIndex] =
			workspace:Raycast(RayOrigin, SUN_DIRECTION * SUN_RAY_LENGTH, ShadowRayParams) ~= nil
		ShadowCachePositions[SampleIndex] = RayOrigin - SUN_DIRECTION * RAY_ORIGIN_BIAS
		ShadowCacheNormals[SampleIndex] = PendingShadowNormals[SampleIndex]
		ShadowCacheUpdatedAt[SampleIndex] = ShadowCacheTime
	end

	-- 1.49 miliseconds part here:

	-- Sends the information to all workers workers
	for i, TargetActor: Actor in ipairs(PlayerScripts:WaitForChild("WorkerFolder"):GetChildren()) do
		const RenderBuffer = BufferTable[i] :: buffer

		TargetActor:SendMessage(
			"Execute Rendering",
			RenderBuffer,
			buffer.readu32(OffsetBuffer, (i - 1) * 4),
			CurrentFrame
		)
	end

	for i = 1, ActorCount do
		buffer.writeu32(OffsetBuffer, (i - 1) * 4, 0)
	end
end)
