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

### 4. Texture Management (`TextureHelper`)
- **`TextureHelper.LoadRobloxTemplateTexture`**: Asynchronously loads `SystemsConfigs.DefaultTextureUri` via `AssetService:CreateEditableImageAsync`, resamples it to `SystemsConfigs.TextureSize` (power-of-two for bitmask UV wrapping), and falls back to `TextureHelper.CreateProceduralTemplateTexture` (a classic Roblox stud template) if asset loading is unavailable.
- **`RenderController.Init`**: Loads the template texture once and broadcasts it to all worker actors via `"Set Texture"` so zero texture data is transferred per frame.

### 4. Parallel Worker Distribution
- Dispatches screen slices or render batches to multi-threaded Roblox `Actor` instances via `SendMessage`.
- **`ParallelWorker.client.luau`**: Receives rendering workloads, rasterizes fragments into local buffers, and returns completed pixel and depth buffers to `RenderController.client.luau` for final display assembly.

### 5. Client Render Cleaner (`RendererCleaner.client.luau`)
- Manages bidirectional slot mappings (`RenderSlotByObjectId` and `ObjectIdByRenderSlot`).
- Applies $O(1)$ swap-and-pop compaction when entities leave the client's visual range.
