# Player Lifecycle & Network Service

## Classification & Domain Terminology
- **Domain:** Player State Management & Character Lifecycle Coordination
- **Subsystem:** Client-Server Player Tracker & Character Spawning Service
- **Pattern:** Centralized Singleton Service with Signal Dispatches & Bitpacked ECS OOP Linking

---

## Architectural Mechanisms

### 1. Connection & Disconnection Management
- Hooks into `Players.PlayerAdded` and `Players.PlayerRemoving` to register session state.
- Initializes player-specific replication caches, tracking tables, and input configurations on the server.
- Registers connected players as visible, anchored, collidable render entities in preallocated ECS component buffers (`Position`, `Directions`, `Visual`, `Properties`).

### 2. DynamicObjectsList OOP Binding
- Binds `PlayerService` OOP records bidirectionally to ECS entity slots through `DynamicObjectsList`.
- Encodes dynamic IDs in bits 22-31 of the 32-bit entity property register, enabling O(1) reverse resolution during BVH spatial raycasts and collision queries.
- Guarantees OOP binding integrity across O(1) swap-and-pop entity compaction when earlier players disconnect.

### 3. Binary State Network Streaming
- Decodes compact 20-byte binary state payloads (`PosX`, `PosY`, `PosZ`, `LookX`, `LookZ` as 5 x `f32`) over an unreliable remote event (`PlayerStateEvent`).
- Reconstructs horizontal orthonormal basis matrices (`LookVector`, `UpVector`, `RightVector`) on the fly and sets dirty bitflags for culler/cleaner passes.

### 4. Client View Mode & Collision Suppression
- Differentiates local player and remote player entity states on client instances.
- Suppresses self-collision on the local player entity so local raycasts pass through the camera unobstructed.
- Toggles visibility between first-person (hidden local entity) and third-person (rendered local entity).

### 5. Clean Eviction
- Flushes network buffers, culling registries, and spatial query structures when players disconnect, preventing orphaned references and memory leaks.
