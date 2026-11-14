--!strict
--!native
--!optimize 2

local SystemsConfigs = {}

-- Here, are the configs for all systems, say frustum cullers or replication or even rendering, both client and server

-- Each config should have a SystemsConfigs.Whatever = whatever type
-- Make sure to type them and to in the next line give documentation as to what it does

-- Im thinking about making the virtual engine open source for those that are curious
-- For the renderer ive showed you, it can handle 400 x 400 comfortably while having alot of stress on my intel core 3U
-- if there is no such stress it can easily go 600 x 600

-- i will soon add OOP to my ECS storage here, it will just use a numerical pointer for that to reference its parent OOP object

-- Client --

SystemsConfigs.RenderWidth = 300 :: number
-- Horizontal pixel resolution of the renderer's EditableImage and frame buffers.

SystemsConfigs.RenderHeight = 300 :: number
-- Vertical pixel resolution of the renderer's EditableImage and frame buffers.

SystemsConfigs.RenderTotalPixels = SystemsConfigs.RenderWidth * SystemsConfigs.RenderHeight :: number
-- Total pixel count of the renderer canvas (RenderWidth * RenderHeight).

SystemsConfigs.ActorCount = 3 :: number
-- Number of parallel worker Actors spawned to rasterize triangles across frames.

SystemsConfigs.WorkerBufferMultiplier = 4 :: number
-- Per-pixel byte multiplier used to allocate each worker's triangle command buffer.

SystemsConfigs.RenderBufferLayoutSize = 52 :: number
-- Byte stride of a single serialized textured triangle in the worker render buffer (three 16-byte vertices and one 4-byte packed RGBA color).

SystemsConfigs.TextureSize = 64 :: number
-- Power-of-two width and height in texels for the software renderer's cached texture buffer.

SystemsConfigs.TextureStudsPerTile = 8 :: number
-- World-space studs covered by one texture tile on part faces (set <= 0 to stretch 1x1 across each face).

SystemsConfigs.DefaultTextureUri = "" :: string
-- Optional Roblox asset URI override for textures; leave empty to use the procedural blood texture.

SystemsConfigs.ClearColorR = 15 :: number
-- Red channel (0-255) of the background clear color filled into the pixel buffer each frame.

SystemsConfigs.ClearColorG = 15 :: number
-- Green channel (0-255) of the background clear color filled into the pixel buffer each frame.

SystemsConfigs.ClearColorB = 20 :: number
-- Blue channel (0-255) of the background clear color filled into the pixel buffer each frame.

SystemsConfigs.SunDirection = Vector3.new(-0.4, 0.85, -0.35).Unit :: Vector3
-- Normalized world-space directional light vector used to compute per-face illumination.

SystemsConfigs.AmbientLight = 0.3 :: number
-- Minimum ambient illumination factor (0-1) applied to all rendered part faces.

SystemsConfigs.MinTriangleArea = 0.5 :: number
-- Minimum screen-space signed edge area (2x pixel area; >= 0.5 keeps all visible 1-pixel triangles while culling degenerate slivers).

SystemsConfigs.RenderNearClip = 0.4 :: number
-- Near clipping plane distance in studs for camera-space part rejection and polygon clipping.

SystemsConfigs.RenderFarClip = 200 :: number
-- Far clipping plane distance in studs for camera-space part rejection and polygon clipping (matched to CullingFarClip).

SystemsConfigs.GuardBandScale = 1.25 :: number
-- 25% screen-space frustum guard-band scale so edge-straddling quads use fast-path projection without boundary pop-in.

SystemsConfigs.ScriptableCameraParkPosition = Vector3.new(0, -50000, 0) :: Vector3
-- World position where the client's Workspace Camera is initially parked when switched to Scriptable.

SystemsConfigs.CameraFixedPosition = Vector3.new(0, 1000, -5000) :: Vector3
-- Fixed distant world position where CameraStore locks the Workspace Camera every frame to avoid rendering default Roblox geometry.

SystemsConfigs.DefaultCameraCFrame = CFrame.new(5, 5, 5) :: CFrame
-- Initial virtual camera CFrame in CameraStore before the camera host updates it.

SystemsConfigs.DefaultCameraFOV = 70 :: number
-- Default vertical field of view in degrees for the virtual camera and projection math.

SystemsConfigs.DefaultCameraView = "FirstPerson" :: string
-- Initial CameraService view preset activated when the render controller starts.

SystemsConfigs.CameraMaxVerticalAngle = 60 :: number
-- Default maximum vertical look angle in degrees (up/down pitch clamp) in CameraService.

SystemsConfigs.CleanerTickInterval = 0 :: number
-- Yield duration in seconds between client RendererCleaner culling passes.

-- Server --

SystemsConfigs.ReplicationTickInterval = 0 :: number
-- Yield duration in seconds between server replication delta broadcast passes.

SystemsConfigs.StaticObjectsFolderName = "Static" :: string
-- Name of the Workspace folder whose descendant BaseParts are flagged as static entities in the server ECS.

SystemsConfigs.WorkspaceCleanupDelay = 5 :: number
-- Delay in seconds after server startup before original Workspace BaseParts are destroyed once registered in the ECS.

-- Shared --

SystemsConfigs.CoreEventsFolderName = "CoreEvents" :: string
-- Name of the ReplicatedStorage folder containing networking RemoteEvents.

SystemsConfigs.ReplicateRemoteEventName = "ReplicateEvent" :: string
-- Name of the RemoteEvent used to replicate ECS component delta buffers from server to client.

SystemsConfigs.CullingPaddingAmount = 1.03 :: number
-- Master frustum culling padding multiplier; 1.03 adds a ~1.2-degree angular buffer over the 70-degree FOV to absorb 1-frame task.wait() rotation lag.

SystemsConfigs.CullingBaseTanY = 0.7002 :: number
-- Exact vertical frustum half-angle tangent at the reference 70-degree FOV (tan(35 deg) = 0.7002).

SystemsConfigs.CullingBaseBackPadding = 3.5 :: number
-- 3.5-stud backward origin shift so adjacent parts do not pop in when turning while still rejecting geometry behind the camera.

SystemsConfigs.CullingRadiusPaddingFactor = 0.35 :: number
-- Secant-corrected L1 cube circumradius factor ((sqrt(3)/6) * sec(35 deg) = 0.2887 * 1.2208 = 0.3524) so rotated corners never pop at frustum planes.

SystemsConfigs.CullingNearClip = 0.4 :: number
-- Near clipping plane distance in studs for view frustum culling (matched to RenderNearClip).

SystemsConfigs.CullingFarClip = 200 :: number
-- Far clipping plane distance in studs for view frustum culling (matched to RenderFarClip).

SystemsConfigs.OccluderInscribedRadiusFactor = 0.32 :: number
-- Conservative scale factor applied to an entity's smallest axis so foreground occluders never overestimate back-face coverage.

SystemsConfigs.OccluderMinProjectedRadius = 0.26 :: number
-- Minimum projected screen-space radius required for a foreground entity to become the active dominant occluder without false edge pop-in.

SystemsConfigs.ECSComponentStride = 12 :: number
-- Byte stride per entity for 3-float ECS component buffers (Position, Orientation, Visual, and Size: 3 x f32 = 12 bytes).

SystemsConfigs.ECSDirectionStride = 36 :: number
-- Byte stride per entity for the Directions ECS buffer (LookVector, UpVector, and RightVector: 9 x f32 = 36 bytes).

SystemsConfigs.ECSComponentBufferSize = 100000 :: number
-- Allocated byte capacity for each 12-byte-stride ECS component buffer (Position, Orientation, Visual, Size).

SystemsConfigs.ECSDirectionBufferSize = 300000 :: number
-- Allocated byte capacity for each 36-byte-stride Directions ECS buffer.

SystemsConfigs.ECSMaxEntities = SystemsConfigs.ECSComponentBufferSize // SystemsConfigs.ECSComponentStride :: number
-- Maximum number of entities that can be stored in the preallocated ECS component buffers.

SystemsConfigs.ECSPropertiesStride = 4 :: number
-- Byte stride per entity for the bitpacked u32 Properties ECS buffer (CanCollide, IsVisible, Anchored, HasDynamicId, DynamicId).

SystemsConfigs.ECSPropertiesBufferSize = 40000 :: number
-- Allocated byte capacity for each 4-byte-stride Properties ECS buffer.

SystemsConfigs.DynamicObjectsMaxCount = 4095 :: number
-- Maximum 12-bit ID capacity (bits 20-31 of the Properties u32 register) for the Dynamic OOP / Objects List.

-- Physics --

SystemsConfigs.PhysicsGravity = 98.0 :: number
-- Downward gravitational acceleration in studs per second squared.

SystemsConfigs.PhysicsFallGravityMultiplier = 1.2 :: number
-- Multiplier applied to downward gravity when falling so jump arcs feel grounded rather than floaty.

SystemsConfigs.PhysicsMaxDeltaTime = 0.05 :: number
-- Maximum clamped frame delta time in seconds to prevent tunneling during frame spikes.

SystemsConfigs.PhysicsSubsteps = 2 :: number
-- Number of physics integration and collision substeps executed per frame.

SystemsConfigs.PlayerDefaultSpawnPosition = Vector3.new(0, 12, 0) :: Vector3
-- Fallback world spawn position for the player physics body when no character root part is present.

SystemsConfigs.PlayerVoidResetY = -500.0 :: number
-- World Y threshold below which the player physics body resets back to its spawn position.

SystemsConfigs.PlayerMass = 80.0 :: number
-- Mass of the player physics body in kilograms used for force acceleration and collision impulses.

SystemsConfigs.PlayerHalfExtents = Vector3.new(1.0, 2.5, 1.0) :: Vector3
-- Collision box half-extents (X, Y, Z) in studs for the player physics body.

SystemsConfigs.PlayerMoveForce = 4400.0 :: number
-- Horizontal driving force in Newtons applied to accelerate the player on grounded surfaces.

SystemsConfigs.PlayerMaxGroundSpeed = 60 :: number
-- Target maximum horizontal ground speed in studs per second.

SystemsConfigs.PlayerGroundFriction = 10.0 :: number
-- Ground traction damping rate per second applied to lateral drift and coasting velocity.

SystemsConfigs.PlayerBrakeMultiplier = 1.65 :: number
-- Extra braking multiplier applied when releasing movement input or counter-steering against momentum.

SystemsConfigs.PlayerStopSpeed = 4.0 :: number
-- Minimum speed reference in studs per second used to bring low-speed coasting cleanly to rest.

SystemsConfigs.PlayerAirControlMultiplier = 0.2 :: number
-- Fraction of ground driving force available while airborne so jumps preserve takeoff inertia.

SystemsConfigs.PlayerAirDrag = 0.45 :: number
-- Linear aerodynamic drag per second applied while the player is airborne.

SystemsConfigs.PlayerJumpImpulse = 2600.0 :: number
-- Upward impulse in Newton-seconds applied when jumping from grounded contact.

SystemsConfigs.PlayerWalkableNormalY = 0.65 :: number
-- Minimum surface normal Y component required for a contact to count as walkable ground.

SystemsConfigs.ObjectDefaultDensity = 1.2 :: number
-- Default mass per cubic stud used to derive dynamic ECS entity mass from bounding volume.

SystemsConfigs.ObjectLinearDrag = 0.6 :: number
-- Linear air damping per second applied to dynamic ECS object velocities.

SystemsConfigs.ObjectSurfaceFriction = 6.5 :: number
-- Tangential surface friction rate per second applied to dynamic ECS objects in contact.

SystemsConfigs.ObjectRestitution = 0.15 :: number
-- Normal impact restitution (0-1) for dynamic ECS object collisions.

SystemsConfigs.ObjectSleepSpeedThreshold = 0.08 :: number
-- Velocity magnitude threshold in studs per second below which grounded dynamic objects settle to sleep.

SystemsConfigs.PhysicsBroadphasePadding = 2.0 :: number
-- World-space AABB padding in studs around a moving body when querying the BVH for collision candidates.

SystemsConfigs.PlayerMaxWishScale = 2.5 :: number
-- Maximum movement speed multiplier allowed when combining directional player movement inputs.

-- BVH --

SystemsConfigs.BVHStackCapacity = 64 :: number
-- Maximum depth of the iterative BVH traversal stack for raycasting and spatial queries.

SystemsConfigs.BVHMaxLeafEntities = 1 :: number
-- Maximum number of entities grouped into a single BVH leaf node during tree construction.

SystemsConfigs.BVHMutationScanBudget = 256 :: number
-- Number of static entities scanned per query to detect silent buffer mutations without full-array scans.

return SystemsConfigs
