# Network Replication & Interest-Management System

## Classification & Domain Terminology
- **Domain:** Network Protocol & Delta Compression Pipeline
- **Subsystem:** Client-Observer Frustum Culling & Dynamic Entity Delta Streaming
- **Topology:** Authoritative Server Broadcast with Client-Side Slot Mapping
- **Bandwidth Optimization:** Observer View-Cone Spatial Partitioning with Binary Delta Buffers

---

## Architectural Mechanisms

### 1. Spatial Interest Management (`PlayerCuller.luau`)
- Evaluates world entities relative to each connected player's camera position and view direction.
- Entities outside the player's view distance or view-cone angle are culled from network packet serialization, keeping network overhead minimal.

### 2. Binary Delta Serialization (`ReplicatorExecuter.server.luau`)
- Packs dynamic entity transforms into compact contiguous memory buffers (`DeltaPositions`, `DeltaOrientations`, `DeltaVisuals`).
- Dispatches serialized delta packets across the network via custom RemoteEvents at fixed synchronization ticks.

### 3. Client Ingestion & Entity Slot Mapping (`ReplicationReceiver.client.luau`)
- Receives server delta buffers on each client.
- Maintains a bidirectional lookup table (`ClientSlotByServerId`) mapping server IDs to persistent local client slots.
- Automatically assigns new local slots for incoming entities and updates existing local buffers in-place without garbage generation.
