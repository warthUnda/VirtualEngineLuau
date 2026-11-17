# BVH (Bounding Volume Hierarchy) & Spatial Raycasting System

## Classification & Domain Terminology
- **Domain:** Spatial Acceleration & Query Pipeline
- **Subsystem:** Broadphase / Narrowphase Ray Intersection & Oriented Bounding Box (OBB) Solver
- **Data Representation:** Linear Contiguous Entity Buffers with 3D Oriented Bounding Box Attributes (Position, Extents, Orthonormal Direction Basis)
- **Time Complexity:** $O(\log N)$ average-case traversal through flat binary BVH; $O(N)$ vectorized broadphase filtering with SIMD-aligned direction and face projection

---

## Modular Decomposition & File Layout

- **`init.luau`**: Unified facade exposing `Rebuild`, `Raycast`, `QueryAABB`, `QueryAABBScalar`, and `EnsureFresh`.
- **`BVHState.luau`**: Manages pre-allocated flat tree buffers (`NodeBuffer`, `ItemBoundsBuffer`, `EntityOrderBuffer`, `TestedGenBuffer`, `CachedStateBuffer`), buffer growth, and mutation state tracking.
- **`BVHRaycast.luau`**: Stack-based ray traversal through the binary BVH tree, resolving the closest OBB contact.
- **`BVHQuery.luau`**: AABB spatial query implementation providing both array-returning `QueryAABB` and zero-allocation scalar `QueryAABBScalar` directly into pre-allocated `u32` buffers.
- **`BVHSubtreeBuilder.luau`**: Deterministic recursive binary tree builder packing node bounds and child offsets into linear contiguous buffers.
- **`BVHDynamicSweep.luau`**: Ray sweep routine for active `DynamicObjectsList` entries and non-ECS OOP colliders.
- **`BVHMath.luau`**: Pure mathematical ray-slab kernels (`TestNodeAABB`, `TestBoxOBB`, `TestEntityOBB`).
- **`BVHHelper.luau`**: Storage resolution (Actor/Client/Server/Render), incremental mutation scanner budget, and ignore filter predicates.

---

## Architectural Mechanisms

### 1. Modular Decomposition & Unified ECS Buffer Integration (`init`, `BVHState`, `BVHRaycast`, `BVHDynamicSweep`, `BVHQuery`, `BVHHelper`, `BVHSubtreeBuilder`, `BVHMath`)
The `BVH` facade delegates state buffers and rebuild tracking to `BVHState`, static subtree construction to `BVHSubtreeBuilder`, ray traversal and OOP fallback sweeps to `BVHRaycast` / `BVHDynamicSweep`, AABB volume queries to `BVHQuery`, and pure slab/OBB math to `BVHMath`, reading ECS buffers directly:
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

### 3. Broadphase Volume Queries & Direct Auto-Rebuild
- **`BVH.Rebuild` / `BVHHelper.BuildSubtree`**: Constructs the flat-buffer binary BVH tree using scalar-only traversal and stack allocation (`0` per-node Lua table allocations).
- **`BVH.EnsureFresh` / `BVHState.EnsureFreshAndResolve`**: Directly checks storage counts and static-slot state inside `if` guards and rebuilds in place when needed—without separate boolean-question helper indirection.
- **`BVH.QueryAABBScalar` & `BVH.QueryAABB`**: Queries an axis-aligned bounding box (`MinX..MaxZ`) directly into a reusable `u32` candidate buffer (`QueryAABBScalar(..., SkipCheck)`) with zero table allocation on the physics hot path, alongside array convenience wrapper `BVH.QueryAABB`.

### 4. Dynamic Live Tracking & Collision Flags
- Intersected entities with an attached dynamic OOP instance automatically resolve and return that OOP table.
- Collision exclusion is driven directly by the entity's ECS `FLAG_CAN_COLLIDE` bitfield (zero ignore-list table overhead inside BVH).
