# Software Rasterization & Parallel Rendering Pipeline

## Classification & Domain Terminology
- **Domain:** Real-Time Software 3D Rasterizer & Graphics Engine
- **Subsystem:** Camera Matrix Projection, Guardband Frustum Clipping, Edge-Function Rasterization & Worker Parallelization
- **Raster Architecture:** Tile-Based / Parallel Actor Worker Rasterizer with 32-bit Floating-Point Z-Buffer (Depth Test)
- **Clipping Model:** 3D Camera-Space Sutherland-Hodgman Polygon Clipping

---

## Architectural Mechanisms

### 1. Camera Transformation & View Frustum
- **`CameraHelper.VectorsToRotation`**: Generates an orthonormal orientation CFrame using view basis vectors (Look, Up, Right).
- **Camera Store (`CameraStore`) & Standalone Focus (`CameraService`)**: Maintains real-time field-of-view, perspective projection matrices, and camera coordinates. `CameraService` seeds from the initial character at most once and tracks `PhysicsController.GetPlayerPosition() + CameraPlayerEyeOffset` directly so camera controls, airborne damping, and `ScreenGui` rendering (`ResetOnSpawn = false`) remain active when the `Character` and `Humanoid` are deleted.
- **View Culling & Camera Collision (`ViewCulling`, `CameraHelper`)**: `ViewCulling` performs fast radial and bounding-sphere tests plus an order-independent `PrepassDominantOccluder` pass (`UpdateClientView` / `UpdateObserverFromVectors`) without requiring a live `Head` `BasePart`. `CameraHelper.RaycastWorld` resolves camera occlusion directly against the ECS `BVH.Raycast` acceleration structure (avoiding Workspace `RaycastParams` allocations).

### 2. Guardband & Polygon Clipping
- **`MathModule.ClipPolygon`**: Evaluates polygon vertices against camera frustum boundary planes using Sutherland-Hodgman clipping.
- Triangles intersecting the near plane are sliced dynamically into quads or clipped triangles, eliminating near-plane projection artifacts.

### 3. Mesh Registry & Perspective Projection (`VerticeFile`, `VerticeHelper`, `MathModule`)
- **`VerticeFile` & `VerticeHelper`**: `VerticeHelper` constructs the procedural local-space unit shape meshes (`BuildCubeMesh`, `BuildSphereMesh`, `BuildCylinderMesh`, `BuildTriangleMesh`, `BuildPlaneMesh`) with winding-verified face normals; `VerticeFile` exposes shape ID/name translation (`IdToShape`, `ShapeToId`) and `ShapeData` lookup.
- **`MathModule.ProjectVertex` / `MathModule.ProjectVertexUV`**: Converts 3D camera-space coordinates into 2D viewport pixel coordinates with reciprocal depth ($1/Z$) and optional UV coordinates.
- **`MathModule.EdgeFunction`**: Computes signed 2D barycentric half-plane determinants for triangle traversal and pixel coverage testing.
- **Frustum OBB Reject & Sub-Span Perspective Rasterization (`RenderMath`, `MathModule.RasterizeTriangleSpan`)**: `RenderMath.TransformShapeCameraVertices` early-rejects entire OBBs outside the camera-space X/Y guardband. Within `RasterizeTriangleSpan`, faces rasterize against worker scanline band bounds (`BandStartY..BandEndY`) using 8-pixel perspective-correct sub-spans (recomputing exact `(u, v)` every 8 pixels) and a fullbright white-tint fast path. Face `UAxisIndex` / `VAxisIndex` map world-space UV tiling (`TileScale`) per face orientation.
- **Depth Buffering:** Rejects occluded fragments via 32-bit floating-point Z-buffer comparisons inside each worker's local band before texture sampling.

### 4. Texture Management (`TextureTable`, `TextureHelper`)
- **`TextureTable`**: Acts as the public texture directory (`Entries` hashmap), ID/name/URL translator (`IdToName`, `NameToId`, `IdToUrl`, `UrlToId`), deduplicated URL decoder (`DecodeRawUrl`, `RegisterUrl` ignoring duplicate URLs), and `64×64` RGBA `buffer` cache (`TextureTable.CachedBuffers[TextureId]`).
- **Workspace Decal Discovery (`ECSBuilderHelper`)**: Scans `Workspace` for `Decal` instances before populating parts, registers unique `Decal.Texture` URLs into `TextureTable.Entries`, syncs `TextureTable.Entries` to clients via `CoreEvents.TextureSyncEvent` for `64×64` decoding, and assigns matching `TextureId`s to parts.
- **ECS Bitfield Integration (`ECSMain`)**: Stores each entity's `TextureId` in bits `5..12` of the 32-bit `Properties` register, replicated to clients and read per-entity in `RenderController.DrawFrame` so different parts render with different cached `64×64` textures in the same frame.

### 5. Frame Pacing & Scanline-Band Parallel Worker Distribution
- **Decoupled Target FPS (`RenderConfig.RenderTargetFPS`, `RenderControllerHelper.StepFrameAccumulator`)**: `RenderController.DrawFrame(DeltaTime)` paces rasterization to `RenderTargetFPS` (`40` FPS default, configurable via `RenderConfig` / `SystemsConfigs`) using a fractional remainder accumulator while client physics and camera stay at full `RenderStepped` rate (60+ Hz). Lag spikes reset the remainder to prevent catch-up bursts, and in-flight worker batches hold the accumulator primed for the next unblocked tick.
- **Dynamic Prefix-Sum Load Balancing (`WorkerPartitionHelper`, `RenderControllerHelper`)**: `RenderControllerHelper.SubmitFace` stages visible clipped 56-byte triangles once and records $O(1)$ scanline row cost deltas into `RowWorkDiff`. `WorkerPartitionHelper.PartitionWorkerBands` integrates cumulative row work (zeroing `RowWorkDiff` in-place), splits `[0..Height - 1]` into contiguous equal-cost horizontal worker bands (`BandStarts` / `BandEnds`), and `DispatchStagedTriangles` dispatches exact-sized command slices (`CompactSlice`) to overlapping `Actor` workers via `SendMessage`.
- **`ParallelWorker.client.luau`**: Rasterizes only its assigned dynamic horizontal band (`BandStartY..BandEndY`) with local `ZBuffer` depth testing, clearing only previously dirtied local rows and returning a compact dirty-row pixel slice (`CompactSlice`) to `RenderController` for $O(\text{rows})$ compositing via `BufferHelper.CompositeWorkerBand`.

### 6. Client Render Cleaner (`RendererCleaner.client.luau`)
- Filters non-visible entities (`!ECSMain.IsEntityVisible`), pre-passes dominant occluders, and synchronizes `ObjectStorage -> RenderECSStorage` incrementally only when `IsNewSlot` or `DirtyFlags` indicate mutations.
- Manages bidirectional slot mappings (`RenderSlotByObjectId` and `ObjectIdByRenderSlot`) and applies $O(1)$ swap-and-pop compaction when entities despawn or leave range.
