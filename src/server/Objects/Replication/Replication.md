# Network Replication & Interest-Management System

## Classification & Domain Terminology
- **Domain:** Network Protocol & Delta Compression Pipeline
- **Subsystem:** Client-Observer Frustum Culling & Dynamic Entity Delta Streaming
- **Topology:** Authoritative Server Broadcast with Client-Side Slot Mapping
- **Bandwidth Optimization:** Observer View-Cone Spatial Partitioning with Binary Delta Buffers

---

## Architectural Mechanisms

### 1. Spatial Interest Management (`PlayerCuller.luau`, `PlayerFunctions.luau` & `EntityVersionTracker.luau`)
- Evaluates world entities relative to each connected player's standalone virtual observer state (`Origin`, `Look`, `Up`, `Right`, `FovDegrees`), seeded at most once from an initial character (or `PlayerDefaultSpawnPosition`) and continuously updated via compact 56-byte binary `ObserverStateEvent` (`UnreliableRemoteEvent`) buffers so replication remains active after `Character` / `Humanoid` deletion.
- Runs `ViewCulling.PrepassDominantOccluder` once per player view so static and dynamic occluders block entities regardless of entity ID order.
- Static geometry streams incrementally within `ECSConfig.StaticStreamRadius` instead of forcing distant geometry on join; entities outside view bounds are skipped while preserving each player's compact 4B/entity `SentVersion` buffer so unchanged entities are never re-transmitted when re-entering the frustum.
- Freed entity slots (`ActiveFlags == 0` where a client had `SentVersion > 0`) emit a compact **3-byte despawn record** (`u16 ServerId`, `u8 Mask = 0x80`) and zero `SentVersion`, while other live entities stay at permanently stable `ServerId`s.

### 2. Binary Delta Serialization (`ReplicatorExecuter.server.luau` & `EntityVersionTracker.luau`)
- Waits for each client's Actor-cloned `ReplicationReceiver` to signal readiness (`ReplicateEvent:FireServer()` -> `PlayerFunctions.MarkClientReady`) before broadcasting snapshots, preventing dropped initial world packets during client `Actor` bootstrap.
- Runs `EntityVersionTracker.SyncEntityVersions` once per tick (skipping inactive free-list slots with a single `ActiveFlags` check) against a shared server shadow copy and packs changed entity components into a **single binary delta payload buffer** (`8`-byte header `UpdatedCount / WorldEntityCount / Tick` + `u16 ServerId, u8 ComponentMask` + changed components, with `Right = Look × Up` reconstructed client-side to save 12 bytes per orientation update).
- Dispatches serialized delta payloads across `CoreEvents.ReplicateEvent`, capped per tick by `ECSConfig.MaxEntitiesPerReplicationPacket`.

### 3. Event-Driven Replication Transport (`EventBus`, `ReplicationSender`, `ReplicationReceiver` & `ServerReplicationGateway`)
- **Zero RemoteEvents Outside Replication:** Domain subsystems (`PlayerController`, `PlayerClientSync`, `ViewObserverCodec`, `ECSBuilderHelper`) never reference `RemoteEvent` or `UnreliableRemoteEvent` instances; instead, they publish and subscribe to named topics on `EventBus` (`src/shared/Utilities/EventBus.luau`).
- **Centralized Remotes (`ClientRemotes.luau` & `ServerReplicationGateway.luau`):** `ServerReplicationGateway` resolves and binds all 5 remotes (`ReplicateEvent`, `ObserverStateEvent`, `TextureSyncEvent`, `PlayerStateEvent`, `PlayerRegistryEvent`) inside `ReplicatedStorage.CoreEvents` on the server, while `ClientRemotes` resolves them in one place inside `src/client/Objects/Replication/`.
- **Outbound Client Sender (`ReplicationSender.client.luau` & `ReplicationSenderHelper.luau`):** Cloned into the Controller Actor VM by `RenderBootstrap.luau`; `ReplicationSenderHelper` subscribes to `EventBus` and buffers early startup emissions until remotes resolve, while `ReplicationSender.client.luau` directly maps each topic (`RequestInitialSync`, `SendObserverState`, `SendPlayerState`) to its `Remotes.*:FireServer(...)` call.
- **Inbound Client Receiver (`ReplicationReceiver.client.luau` & `ReplicationReceiverHelper.luau`):** Listens exclusively to `.OnClientEvent`, unpacking ECS binary deltas (`IngestPayload`), decoding synced textures (`ApplySyncedTextures`), forwarding player registry snapshots onto `EventBus` (`PlayerRegistryReceived`), and emitting `RequestInitialSync` once ready.
