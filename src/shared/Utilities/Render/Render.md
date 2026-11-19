# Software Rasterization & Parallel Rendering Pipeline

## Classification & Domain Terminology
- **Domain:** Real-Time Software 3D Rasterizer & Graphics Engine
- **Subsystem:** BVH Frustum Culler, 2-Pass Parallel Actor Geometry & 2D `32×32` Tile-Based Rasterizer
- **Raster Architecture:** Dual-Stream (`32B` untextured / `64B` textured, aligned) 2D `32×32` L1-Tile Rasterizer with Conservative Tile Hi-Z (`TileMinZ`/`TileMaxZ`) and Direct Per-Band `EditableImage:WritePixelsBuffer` Upload
- **Clipping Model:** 6-Bit Outcode Masked 3D Camera-Space Sutherland-Hodgman Polygon Clipping

---

## Architectural Mechanisms

### 1. Camera Transformation & View Frustum
- **Single-Player OOP `CameraService` & `CameraMethods`**: Manages the active camera singleton (`SetCFrame`, `SetCameraView`, `SetCameraHost`, `ChangeFOV`, `ChangeSensitivity`, `GetCFrame`, `GetFOV`, `Destroy`).
- **Renderer-Side Camera & Guardband Plane Caching (`RenderService` & `RenderControllerHelper`)**: Caches camera basis SIMD `vector`s, projection scalars (`CachedFocalLength`, `CachedGuardBandX`, `CachedGuardBandY`), and precomputed guardband clip plane vectors (`CachedPlaneLeft`, `CachedPlaneRight`, `CachedPlaneBottom`, `CachedPlaneTop`) directly on `RenderObject`.
- **BVH Frustum Culling & Front-to-Back Culling ECS (`RendererCleaner`, `RenderBVHHelper`, `CleanerHelper`, `CleanerSortHelper`, `ViewCulling`, `ViewCullingBatchHelper`)**:
  - `RendererCleaner` paces default `CleanerTickInterval == 0` ticks via `RunService.RenderStepped:Wait()` and gates culling passes on camera/player/entity/dirty changes (`CleanerHelper.NeedsSync` with 32-bit `buffer.readu32` dirty-word scans and post-sync `ObjDirtyFlags` reset), reducing stationary frames to zero culling work.
  - `RenderBVHHelper` builds a dedicated visible-entity flat 32-byte BVH (reusing `BVHSubtreeBuilder`, indexing both anchored and sleeping unanchored visible parts regardless of `CanCollide`) with `O(1)` lazy demotion of awakened unanchored parts (`StaticMembership = 2`) and 6-plane AABB `p-vertex` frustum traversal.
  - `ViewCullingBatchHelper` runs dominant-occluder prepass and register-cached filtering only over BVH frustum candidates (guarding `1/Z` strictly behind `HasOccluder`), and `CleanerSortHelper.SortAscendingByDepth` orders `RenderECSStorage` strictly **front-to-back (`ForwardZ - Radius` ascending)** to maximize Early-Z and Tile Hi-Z rejection.

### 2. Geometry Fast Paths & Dual-Stream (`32B` / `64B`) Staging
- **OBB `AllInside` Single Projection (`RenderMath`, `RenderEntityStageHelper`, `RenderQuadEmitHelper`)**: `TransformShapeCameraVertices` returns `AllInside` when the entire OBB sits inside Near/Far and guardband bounds, projecting each unique shape vertex once instead of per-face and bypassing polygon clipping completely.
- **Cube Fast Path (`RenderCubeStageHelper`)**: Computes all 8 cube corners via a 14-op add/sub vector tree (zero multiplies/loops), backface-culls all 6 faces with direct scalar comparisons, and emits directly into compact `32B` untextured or `64B` textured command buffers.
- **Outcode-Masked Polygon Clipping (`PolygonClipMath`, `MathModule`)**: Evaluates 6-bit vertex outcodes for instant trivial-reject (`bit32.band ~= 0`) and clips only crossed planes (`bit32.bor`) with inlined buffer reads/writes.

### 3. 2-Pass Parallel Actor Pipeline (`RenderInstanceMethods`, `RenderFrameDispatchHelper`, `RenderWorkerGateway`, `ParallelWorker`)
- **Pass 1 (Parallel Geometry Staging):** Splits front-to-back `RenderECSStorage` into contiguous chunks across the 3 `Actor` workers (`ActorCount = 3`) using a `17% / 41.5% / 41.5%` front-heavy chunk ratio (`WorkerPartitionHelper.ComputeStageChunkCounts`) to compensate for near-plane polygon clipping on closest entities, reusing cached per-worker ECS slices across frames (`RenderWorkerGateway`).
- **Pass 2 (Single-Copy Dual Scatter & 2D Tile Rasterization):** `RenderFrameDispatchHelper` merges `RowWorkDiff`, partitions equal-cost bands accounting for baseline per-row clear/upload cost (`WorkerPartitionHelper.PartitionWorkerBands`), scatters chunks in strict front-to-back order with contiguous untextured run coalescing and slice reuse (`WorkerScatterHelper.ScatterDualChunksToWorkers`), and reuses worker `BandPixelSlice` / `RowWorkDiff` buffers (`ParallelWorker`) to eliminate per-frame multi-megabyte heap allocations.
- **Direct Per-Band GPU Upload (`RenderWorkerGateway`):** Workers clear and rasterize their band directly into a compact pixel slice and return it to `ControllerActor`, which writes directly into `EditableImage:WritePixelsBuffer(Vector2.new(0, BandStartY), Vector2.new(Width, BandHeight), BandSlice)`—eliminating the `4 MB` CPU `FinalPixel` compositing copy.

### 4. L1-Resident `32×32` Tile Binning, Lazy Hi-Z & Pre-Shaded Textured Spans
- **2D Tile Binning & Lazy Buffer Init (`TileBinnerHelper`, `TileRasterizerMath`):** Bins incoming `32B` untextured and `64B` textured triangles into tail-linked `32×32` tile lists (preserving front-to-back order), lazily initializes `TilePixelBuf` / `TileZBuf` on the first visible triangle per tile (skipping clears on full-cover or single-entry tiles), sets `SkipZTest` on the first visible triangle and `SkipZWrite` on the last binned triangle per tile, and skips `BandPixelBuf` row copy-back when no triangle touches the tile.
- **Conservative Tile Hi-Z (`TileMinZ` / `TileMaxZ`):** Evaluates 4-corner linear edge and `InvZ` bounds per tile to skip occluded tiles (`TriTileMaxZ <= TileMinZ`), bypass per-row edge clipping on full-cover tiles, and skip Z-buffer reads when `FullCover and TriTileMinZ > TileMaxZ`.
- **L1 Pre-Shaded Texture Cache & Hoisted Spans (`TileShadedTexHelper`, `TileTexturedSpanHelper`, `TileSpanHelper`, `RasterizerMath`):** Pre-bakes lit `(TexBuf, Shade8)` variants into a 16-slot per-worker L1 ring cache so scanlines copy pre-shaded RGBA32 texels without per-pixel SWAR shading, while hoisting `SkipZTest`, `SkipZWrite`, ULP-safe `InBounds` clamping (`[1e-3, TexW - 1e-3]`), and a 16-entry `1/Steps` reciprocal LUT outside per-pixel loops.
