# Network Replication & Interest-Management System

## Classification & Domain Terminology
- **Domain:** Network Protocol & Delta Compression Pipeline
- **Subsystem:** Client-Observer Frustum Culling & Dynamic Entity Delta Streaming
- **Topology:** Authoritative Server Broadcast with Client-Side Slot Mapping
- **Bandwidth Optimization:** Observer View-Cone Spatial Partitioning with Binary Delta Buffers

---

## Architectural Mechanisms

### 1. Spatial Interest Management (`PlayerCuller.luau` & `PlayerFunctions.luau`)
- Evaluates world entities relative to each connected player's standalone virtual observer state (`Origin`, `Look`, `Up`, `Right`, `FovDegrees`), seeded at most once from an initial character (or `PlayerDefaultSpawnPosition`) and continuously updated via compact 56-byte binary `ObserverStateEvent` (`UnreliableRemoteEvent`) buffers so replication remains active after `Character` / `Humanoid` deletion.
- Runs `ViewCulling.PrepassDominantOccluder` once per player view so static and dynamic occluders block entities regardless of entity ID order.
- Static geometry streams incrementally within `ECSConfig.StaticStreamRadius` instead of forcing distant geometry on join; entities outside view bounds are skipped while preserving each player's compact 4B/entity `SentVersion` buffer so unchanged entities are never re-transmitted when re-entering the frustum.
- Entities relocated via O(1) swap-and-pop compaction trigger `ECSData.SetSwapPopCallback`, flagging a dedicated 1B/entity `ForceResync` bitbuffer for the overwritten slot so connected clients immediately receive the replacement tail entity regardless of frustum culling.

### 2. Binary Delta Serialization (`ReplicatorExecuter.server.luau`)
- Waits for each client's Actor-cloned `ReplicationReceiver` to signal readiness (`ReplicateEvent:FireServer()` -> `PlayerFunctions.MarkClientReady`) before broadcasting snapshots, preventing dropped initial world packets during client `Actor` bootstrap.
- Runs `PlayerFunctions.SyncEntityVersions` once per tick against a shared server shadow copy and packs changed entity components into a **single binary delta payload buffer** (`8`-byte header `UpdatedCount / WorldEntityCount / Tick` + `u16 ServerId, u8 ComponentMask` + changed components, with `Right = Look × Up` reconstructed client-side to save 12 bytes per orientation update).
- Dispatches serialized delta payloads across `CoreEvents.ReplicateEvent`, capped per tick by `ECSConfig.MaxEntitiesPerReplicationPacket`.

### 3. Client Ingestion & Entity Slot Mapping (`ReplicationReceiver.client.luau`)
- Receives single binary delta payloads on each client and detects server despawn compactions when `WorldEntityCount` shrinks, evicting stale client slots.
- Maintains bidirectional lookup buffers (`ClientSlotByServerId` / `ServerIdByClientSlot`) synchronized via `SetSwapPopCallback`, updating local buffers in-place, reconstructing `Right = Look × Up`, and flagging modified slots via `ECSData.MarkDirty`.
