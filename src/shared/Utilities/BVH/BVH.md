# BVH (Bounding Volume Hierarchy) & Spatial Raycasting System

## Classification & Domain Terminology
- **Domain:** Spatial Acceleration & Query Pipeline
- **Subsystem:** Broadphase / Narrowphase Ray Intersection & Oriented Bounding Box (OBB) Solver
- **Data Representation:** Linear Contiguous Entity Buffers with 3D Oriented Bounding Box Attributes (Position, Extents, Orthonormal Direction Basis)
- **Time Complexity:** $O(N)$ vectorized broadphase filtering with SIMD-aligned direction and face projection

---

## Architectural Mechanisms

### 1. Unified ECS Buffer Integration
The BVH module queries the engine's centralized Entity Component System (ECS) buffers directly:
- **`PositionData`**: Floating-point 3D origin of bounding boxes.
- **`SizeData`**: Half-extents along the entity's principal local axes.
- **`DirectionsData`**: 9-component orthonormal matrix representing Right, Up, and Look vectors.

### 2. High-Performance Raycasting
- **`BVH.Raycast`**: Evaluates ray intersections against unrotated and rotated oriented bounding boxes (OBBs). It computes the ray entry and exit intervals ($t_{\min}, t_{\max}$) along local slab axes, returning:
  1. `EntityId`: Unique integer ID of the closest intersected entity.
  2. `DynamicObject`: Any registered OOP object bound to that entity.
  3. `HitDistance`: Scalar ray travel distance to the contact surface.
  4. `HitPosition`: World-space 3D contact point.
  5. `HitNormal`: Outward unit surface normal vector.
- **Callable Module (`__call`)**: Allows invoking the module directly as a function `BVH(Storage, Origin, Direction)` where `Direction`'s magnitude dictates the search distance.

### 3. Broadphase Volume Queries & Zero-Allocation Build
- **`BVH.Rebuild` / `BVHHelper.BuildSubtree`**: Constructs the flat-buffer binary BVH tree using scalar-only traversal and stack allocation (`0` per-node Lua table allocations).
- **`BVH.EnsureFresh`**: Refreshes the static BVH once per simulation substep before batched broadphase queries.
- **`BVH.QueryAABBScalar` & `BVH.QueryAABB`**: Queries an axis-aligned bounding box (`MinX..MaxZ`) directly into a reusable `u32` candidate buffer (`QueryAABBScalar(..., SkipNeedsRebuild)`) with zero table allocation on the physics hot path, alongside array convenience wrapper `BVH.QueryAABB`.

### 4. Dynamic Live Tracking & Ignore Filtering
- Intersected entities with an attached dynamic OOP instance automatically resolve and return that OOP table.
- Filter criteria support scalar Entity IDs, OOP object tables, or compound filter tables to ignore self or companion colliders.
