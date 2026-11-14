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
- **Camera Store (`CameraStore`)**: Maintains real-time field-of-view, perspective projection matrices, and camera coordinates.
- **View Culling (`ViewCulling`)**: Fast radial and bounding-sphere tests cull primitives falling outside near and far clipping planes.

### 2. Guardband & Polygon Clipping
- **`MathModule.ClipPolygon`**: Evaluates polygon vertices against camera frustum boundary planes using Sutherland-Hodgman clipping.
- Triangles intersecting the near plane are sliced dynamically into quads or clipped triangles, eliminating near-plane projection artifacts.

### 3. Perspective Projection & Sub-Pixel Rasterization
- **`MathModule.ProjectVertex` / `MathModule.ProjectVertexUV`**: Converts 3D camera-space coordinates into 2D viewport pixel coordinates with reciprocal depth ($1/Z$) and optional UV coordinates.
- **`MathModule.EdgeFunction`**: Computes signed 2D barycentric half-plane determinants for triangle traversal and pixel coverage testing.
- **Perspective-Correct Texture Mapping (`MathModule.RasterizeTriangleSpan`)**: Interpolates $1/Z$, $U/Z$, and $V/Z$ across horizontal spans, recovering true perspective-correct $(U, V)$ per visible fragment after the Z-test and modulating sampled texels from a power-of-two RGBA texture buffer (`TextureHelper`) by the face's shaded `PackedColor`.
- **Depth Buffering:** Rejects occluded fragments via 32-bit floating-point Z-buffer comparisons before texture sampling.

### 4. Texture Management (`TextureTable`, `TextureHelper`)
- **`TextureTable`**: Acts as the ID/name/URL translator (`IdToName`, `NameToId`, `IdToUrl`, `UrlToId`), deduplicated URL decoder (`DecodeRawUrl`, `RegisterUrl` ignoring duplicate URLs), and `64×64` RGBA `buffer` cache (`TextureTable.CachedBuffers[TextureId]`).
- **Workspace Decal Discovery (`ECSBuilderHelper`)**: Scans `Workspace` for `Decal` instances before populating parts, registers unique `Decal.Texture` URLs into `TextureTable`, publishes them to `ReplicatedStorage.TextureRegistry` for client `64×64` decoding, and assigns matching or random `TextureId`s to parts.
- **ECS Bitfield Integration (`ECSMain`)**: Stores each entity's `TextureId` in bits `5..12` of the 32-bit `Properties` register, replicated to clients and read per-entity in `RenderController.DrawFrame` so different parts render with different cached `64×64` textures in the same frame.

### 4. Parallel Worker Distribution
- Dispatches screen slices or render batches to multi-threaded Roblox `Actor` instances via `SendMessage`.
- **`ParallelWorker.client.luau`**: Receives rendering workloads, rasterizes fragments into local buffers, and returns completed pixel and depth buffers to `RenderController.client.luau` for final display assembly.

### 5. Client Render Cleaner (`RendererCleaner.client.luau`)
- Manages bidirectional slot mappings (`RenderSlotByObjectId` and `ObjectIdByRenderSlot`).
- Applies $O(1)$ swap-and-pop compaction when entities leave the client's visual range.
