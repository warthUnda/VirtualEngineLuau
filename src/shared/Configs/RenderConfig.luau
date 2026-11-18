--!strict
--!native
--!optimize 2

--[=[
	@class RenderConfig
	Tunable configuration parameters for the software rasterizer, viewport display,
	parallel worker actors, lighting, frustum culling, and camera defaults.
]=]

-- Tables --
local RenderConfig = {}

-- Display & Worker Settings --

RenderConfig.RenderWidth = 1000 :: number
-- Horizontal pixel resolution of the renderer's EditableImage and frame buffers.

RenderConfig.RenderHeight = 1000 :: number
-- Vertical pixel resolution of the renderer's EditableImage and frame buffers.

RenderConfig.RenderTotalPixels = RenderConfig.RenderWidth * RenderConfig.RenderHeight :: number
-- Total pixel count of the renderer canvas (RenderWidth * RenderHeight).

RenderConfig.RendererScreenGuiName = "RendererScreenGui" :: string
-- Name assigned to the self-created ScreenGui instantiated by RenderService.

RenderConfig.RendererImageLabelName = "ViewportLabel" :: string
-- Name assigned to the full-screen ImageLabel created inside RenderService's ScreenGui.

RenderConfig.ActorCount = 3 :: number
-- Number of parallel worker Actors spawned to rasterize triangles across frames.

RenderConfig.WorkerBufferMultiplier = 4 :: number
-- Per-pixel byte multiplier used to allocate each worker's triangle command buffer.

RenderConfig.RenderBufferLayoutSize = 56 :: number
-- Byte stride of a single serialized textured triangle in the worker render buffer (three 16-byte vertices, one 4-byte packed RGBA color, and one 4-byte texture ID).

-- Texture Settings --

RenderConfig.TextureSize = 64 :: number
-- Power-of-two width and height in texels for the software renderer's cached texture buffers.

RenderConfig.TextureStudsPerTile = 0 :: number
-- World-space studs covered by one texture tile on part faces (set <= 0 to stretch 1x1 across each face instead of repeating).

-- Lighting & Clear Color --

RenderConfig.ClearColorR = 15 :: number
-- Red channel (0-255) of the background clear color filled into the pixel buffer each frame.

RenderConfig.ClearColorG = 15 :: number
-- Green channel (0-255) of the background clear color filled into the pixel buffer each frame.

RenderConfig.ClearColorB = 20 :: number
-- Blue channel (0-255) of the background clear color filled into the pixel buffer each frame.

RenderConfig.SunDirection = Vector3.new(-0.4, 0.85, -0.35).Unit :: Vector3
-- Normalized world-space directional light vector used to compute per-face illumination.

RenderConfig.AmbientLight = 0.3 :: number
-- Minimum ambient illumination factor (0-1) applied to all rendered part faces.

RenderConfig.MinTriangleArea = 0.5 :: number
-- Minimum screen-space signed edge area (2x pixel area; >= 0.5 keeps all visible 1-pixel triangles while culling degenerate slivers).

-- Clipping & Frustum Culling --

RenderConfig.RenderNearClip = 0.4 :: number
-- Near clipping plane distance in studs for camera-space part rejection and polygon clipping.

RenderConfig.RenderFarClip = 200 :: number
-- Far clipping plane distance in studs for camera-space part rejection and polygon clipping (matched to CullingFarClip).

RenderConfig.GuardBandScale = 1.25 :: number
-- 25% screen-space frustum guard-band scale so edge-straddling quads use fast-path projection without boundary pop-in.

RenderConfig.CullingPaddingAmount = 1.03 :: number
-- Master frustum culling padding multiplier; 1.03 adds a ~1.2-degree angular buffer over the 70-degree FOV to absorb 1-frame task.wait() rotation lag.

RenderConfig.CullingBaseTanY = 0.7002 :: number
-- Exact vertical frustum half-angle tangent at the reference 70-degree FOV (tan(35 deg) = 0.7002).

RenderConfig.CullingBaseBackPadding = 3.5 :: number
-- 3.5-stud backward origin shift so adjacent parts do not pop in when turning while still rejecting geometry behind the camera.

RenderConfig.CullingRadiusPaddingFactor = 0.35 :: number
-- Secant-corrected L1 cube circumradius factor ((sqrt(3)/6) * sec(35 deg) = 0.2887 * 1.2208 = 0.3524) so rotated corners never pop at frustum planes.

RenderConfig.CullingNearClip = 0.4 :: number
-- Near clipping plane distance in studs for view frustum culling (matched to RenderNearClip).

RenderConfig.CullingFarClip = 200 :: number
-- Far clipping plane distance in studs for view frustum culling (matched to RenderFarClip).

RenderConfig.OccluderInscribedRadiusFactor = 0.32 :: number
-- Conservative scale factor applied to an entity's smallest axis so foreground occluders never overestimate back-face coverage.

RenderConfig.OccluderMinProjectedRadius = 0.26 :: number
-- Minimum projected screen-space radius required for a foreground entity to become the active dominant occluder without false edge pop-in.

-- Scene Cleaner --

RenderConfig.CleanerTickInterval = 0 :: number
-- Yield duration in seconds between client RendererCleaner culling passes.

return RenderConfig
