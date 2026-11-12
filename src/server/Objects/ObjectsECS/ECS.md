# Contiguous Memory ECS (Entity Component System)

## Classification & Domain Terminology
- **Domain:** Data-Oriented Component Architecture & Memory Cache Management
- **Subsystem:** Stride-Aligned Native Buffer Storage with Dynamic OOP Object Binding
- **Allocation Strategy:** Pre-Allocated Dense Memory Buffers with $O(1)$ Swap-and-Pop Lifecycle Compaction
- **Memory Footprint:** Cache-friendly contiguous flat buffers per component stream

---

## Architectural Mechanisms

### 1. Dense Buffer Layout & Component Strides
Components are stored across parallel contiguous byte buffers indexed by entity slot offsets:
- **`PositionData`**: 32-bit floating-point triples ($X, Y, Z$).
- **`SizeData`**: Half-extents ($HX, HY, HZ$).
- **`DirectionsData`**: 9-component orientation matrix (Right, Up, Look vectors).
- **`PropertiesData`**: 32-bit packed bitfields (Collision, Visibility, Anchored, and Dynamic ID).
- **`VisualData`**: Packed color, material, and visual identifier payloads.

### 2. $O(1)$ Swap-and-Pop Deletion
- When an entity is despawned via `DeleteEntity`, the last allocated entity in the buffer stream is copied into the vacant index slot.
- Slot pointers and counter registries (`EntityECSCount`) decrement in constant $O(1)$ time without requiring buffer shifting or heap allocations.

### 3. Bitfield Packing (`ECSMain.PackProperties`)
- Encodes boolean state flags and integer object identifiers into a single 32-bit register:
  - Bit 1: `FLAG_CAN_COLLIDE`
  - Bit 2: `FLAG_IS_VISIBLE`
  - Bit 3: `FLAG_ANCHORED`
  - Bits 16-31: Dynamic Object ID reference

### 4. Dynamic OOP Binding (`DynamicObjectsMain`)
- Bridges data-oriented flat buffers with high-level game logic scripts.
- Binds complex OOP instances to scalar `EntityId` keys in an auxiliary lookup registry for bidirectional retrieval.
