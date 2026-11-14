--!strict
--!native
--!optimize 2

local ECSConfig = {}

-- ECS Component Buffer Layout --

ECSConfig.ECSMaxEntities = 8192 :: number
-- Maximum number of entities that can be stored in the preallocated ECS component buffers (power of 2).

ECSConfig.ECSComponentStride = 12 :: number
-- Byte stride per entity for 3-float ECS component buffers (Position and Size: 3 x f32 = 12 bytes).

ECSConfig.ECSDirectionStride = 36 :: number
-- Byte stride per entity for the Directions ECS buffer (LookVector, UpVector, and RightVector: 9 x f32 = 36 bytes).

ECSConfig.ECSVisualStride = 4 :: number
-- Byte stride per entity for the compact RGBA Visual ECS buffer (R, G, B, A = 4 bytes).

ECSConfig.ECSPropertiesStride = 4 :: number
-- Byte stride per entity for the bitpacked u32 Properties ECS buffer (CanCollide, IsVisible, Anchored, HasDynamicId, TextureId, ShapeId, DynamicId).

ECSConfig.ECSComponentBufferSize = ECSConfig.ECSMaxEntities * ECSConfig.ECSComponentStride :: number
-- Allocated byte capacity for each 12-byte-stride ECS component buffer (Position, Size).

ECSConfig.ECSDirectionBufferSize = ECSConfig.ECSMaxEntities * ECSConfig.ECSDirectionStride :: number
-- Allocated byte capacity for each 36-byte-stride Directions ECS buffer.

ECSConfig.ECSVisualBufferSize = ECSConfig.ECSMaxEntities * ECSConfig.ECSVisualStride :: number
-- Allocated byte capacity for each 4-byte-stride Visual ECS buffer.

ECSConfig.ECSPropertiesBufferSize = ECSConfig.ECSMaxEntities * ECSConfig.ECSPropertiesStride :: number
-- Allocated byte capacity for each 4-byte-stride Properties ECS buffer.

ECSConfig.DynamicObjectsMaxCount = 1023 :: number
-- Maximum 10-bit ID capacity (bits 22-31 of the Properties u32 register) for the Dynamic OOP / Objects List.

-- Server ECS Builder & Replication --

ECSConfig.ReplicationTickInterval = 0.05 :: number
-- Yield duration in seconds between server replication delta broadcast passes.

ECSConfig.StaticStreamRadius = 260 :: number
-- Radial streaming distance in studs for replicating static geometry around each player observer.

ECSConfig.MaxEntitiesPerReplicationPacket = 2048 :: number
-- Maximum number of entities packed into a single ReplicateEvent packet per player per tick to prevent network queue buildup.

ECSConfig.StaticObjectsFolderName = "Static" :: string
-- Name of the Workspace folder whose descendant BaseParts are flagged as static entities in the server ECS.

ECSConfig.WorkspaceCleanupDelay = 5 :: number
-- Delay in seconds after server startup before original Workspace BaseParts are destroyed once registered in the ECS.

ECSConfig.CoreEventsFolderName = "CoreEvents" :: string
-- Name of the ReplicatedStorage folder containing networking RemoteEvents.

ECSConfig.ReplicateRemoteEventName = "ReplicateEvent" :: string
-- Name of the RemoteEvent used to replicate ECS component delta buffers from server to client.

ECSConfig.ObserverRemoteEventName = "ObserverStateEvent" :: string
-- Name of the UnreliableRemoteEvent used to sync virtual client observer transforms to the server culler without a Character.

ECSConfig.ObserverSyncInterval = 0.05 :: number
-- Minimum interval in seconds between client-to-server virtual observer transform sync packets.

ECSConfig.TextureSyncRemoteEventName = "TextureSyncEvent" :: string
-- Name of the RemoteEvent used to replicate TextureTable's public texture hashmap from server to client.

return ECSConfig
