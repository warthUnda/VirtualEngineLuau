# Contiguous Memory ECS (Entity Component System)

## Classification & Domain Terminology
- **Domain:** Data-Oriented Component Architecture & Memory Cache Management
- **Subsystem:** Stride-Aligned Native Buffer Storage with Dynamic OOP Object Binding
- **Allocation Strategy:** Pre-Allocated Dense Memory Buffers with $O(1)$ Swap-and-Pop Lifecycle Compaction
- **Memory Footprint:** Cache-friendly contiguous flat buffers per component stream

---

## Architectural Mechanisms

### 1. Dense Buffer Layout & Component Strides
Components are stored across parallel contiguous byte buffers whose byte sizes derive directly from `ECSMaxEntities * Stride` (`8192` capacity):
- **`PositionData`**: 32-bit floating-point triples ($X, Y, Z$) (`12` bytes/entity).
- **`SizeData`**: Full dimensions ($X, Y, Z$) (`12` bytes/entity).
- **`DirectionsData`**: 9-component orientation matrix (`Look` at `0..11`, `Up` at `12..23`, `Right` at `24..35`; `36` bytes/entity). Legacy `OrientationData` aliases directly onto the `Look` slice (`0..11`) of `DirectionsBuffer` with `0` extra allocation.
- **`PropertiesData`**: 32-bit packed bitfields (Collision, Visibility, Anchored, Texture ID, Shape ID, and Dynamic ID; `4` bytes/entity).
- **`VisualData`**: Packed 4-byte (`u32`) RGBA visual payload (`4` bytes/entity).
- **Change Tracking**: Per-entity `DirtyFlags` (`u8`) and `VersionBuffer` (`u32`) track component mutations without redundant buffer scanning.

### 2. $O(1)$ Swap-and-Pop Deletion
- When an entity is despawned via `DeleteEntity`, the last allocated entity in the buffer stream is copied into the vacant index slot, `DynamicObjectsList` reverse bindings (`EntityIdByDynamicId`) are updated for the moved tail entity, and any registered `SetSwapPopCallback` listener (such as `PhysicsController` or `ReplicationReceiver`) is notified.
- Slot pointers and counter registries (`EntityECSCount`) decrement in constant $O(1)$ time with `MAX_ENTITIES` capacity guarding on `RegisterEntity`.

### 3. Bitfield Packing (`ECSMain.PackProperties`)
- Encodes boolean state flags and integer object identifiers into a single 32-bit register:
  - Bit 1: `FLAG_CAN_COLLIDE`
  - Bit 2: `FLAG_IS_VISIBLE`
  - Bit 3: `FLAG_ANCHORED`
  - Bits 16-31: Dynamic Object ID reference

### 4. Dynamic OOP Binding (`DynamicObjectsMain`)
- Bridges data-oriented flat buffers with high-level game logic scripts.
- Binds complex OOP instances to scalar `EntityId` keys in an auxiliary lookup registry for bidirectional retrieval.
