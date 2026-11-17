# Player Lifecycle & Network Service

## Classification & Domain Terminology
- **Domain:** Player State Management & Character Lifecycle Coordination
- **Subsystem:** Client-Server Player Tracker & Character Spawning Service
- **Pattern:** Centralized Singleton Service with Signal Dispatches & Bitpacked ECS OOP Linking

---

## Architectural Mechanisms

### 1. Modular Event-Driven Architecture (`PlayerController`, `PlayerClientSync`, `PlayerControllerHelper`, `PlayerService`, `PlayerRecordMethods`, `PlayerServiceHelper`, `PlayerLibrary`)
- **`PlayerController` & `PlayerClientSync`**: `PlayerController` acts as the facade handling server lifecycle and `DynamicObjectsList` bindings while communicating exclusively over `EventBus` (`ServerPlayerRegistryChanged`, `ServerPlayerStateReceived`, `PlayerRegistryReceived`, `SendPlayerState`)—touching zero `RemoteEvent`s directly. `PlayerClientSync` handles client registry linking, zero-lag local entity synchronization, and 20-byte state payload packing.
- **`PlayerControllerHelper`**: Shared static resolution utilities for Controller Actor/Server ECS storages, 20-byte binary state serialization/deserialization, and dynamic ID slot scanning.
- **`PlayerService` & `PlayerRecordMethods`**: OOP constructors (`New`, `FromRegistryEntry`) and buffer mutation methods (`BindToStorage`, `BindClientDynamicId`, `UpdateTransform`, `SetLocalVisibilityAndCollision`, `SetColor`, `UnbindFromStorage`) keeping all modules strictly under the 250-line ceiling.
- **`PlayerServiceHelper`**: Stateless math for horizontal look vector normalization, VerticeFile 3-bit shape ID resolution, and initial character model seeding.
- **`PlayerLibrary`**: Public external API facade for client/server gameplay scripts.

### 2. Connection & Disconnection Management
- Hooks into `Players.PlayerAdded` and `Players.PlayerRemoving` to register session state.
- Initializes player-specific replication caches, tracking tables, and input configurations on the server.
- Registers connected players as visible, anchored, collidable render entities in preallocated ECS component buffers (`Position`, `Directions`, `Visual`, `Properties`).

### 3. DynamicObjectsList OOP Binding
- Binds `PlayerService` OOP records bidirectionally to ECS entity slots through `DynamicObjectsList`.
- Encodes dynamic IDs in bits 22-31 of the 32-bit entity property register, enabling O(1) reverse resolution during BVH spatial raycasts and collision queries.
- Guarantees permanent `EntityId` and OOP binding stability across player disconnections via the ECS free-list slot allocator.

### 4. Binary State Network Streaming
- Decodes compact 20-byte binary state payloads (`PosX`, `PosY`, `PosZ`, `LookX`, `LookZ` as 5 x `f32`) over an unreliable remote event (`PlayerStateEvent`).
- Reconstructs horizontal orthonormal basis matrices (`LookVector`, `UpVector`, `RightVector`) on the fly and sets dirty bitflags for culler/cleaner passes.

### 5. Client View Mode & Collision Suppression
- Differentiates local player and remote player entity states on client instances via `PlayerClientSync`.
- Suppresses self-collision on the local player entity so local raycasts pass through the camera unobstructed.
- Toggles visibility between first-person (hidden local entity) and third-person (rendered local entity).

### 6. Clean Eviction
- Flushes network buffers, culling registries, and spatial query structures when players disconnect, preventing orphaned references and memory leaks.
