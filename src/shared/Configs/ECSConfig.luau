--!strict
--!native
--!optimize 2

local ECSConfig = {}

-- ECS Component Buffer Layout --

ECSConfig.ECSComponentStride = 12 :: number
-- Byte stride per entity for 3-float ECS component buffers (Position, Orientation, Visual, and Size: 3 x f32 = 12 bytes).

ECSConfig.ECSDirectionStride = 36 :: number
-- Byte stride per entity for the Directions ECS buffer (LookVector, UpVector, and RightVector: 9 x f32 = 36 bytes).

ECSConfig.ECSComponentBufferSize = 100000 :: number
-- Allocated byte capacity for each 12-byte-stride ECS component buffer (Position, Orientation, Visual, Size).

ECSConfig.ECSDirectionBufferSize = 300000 :: number
-- Allocated byte capacity for each 36-byte-stride Directions ECS buffer.

ECSConfig.ECSMaxEntities = ECSConfig.ECSComponentBufferSize // ECSConfig.ECSComponentStride :: number
-- Maximum number of entities that can be stored in the preallocated ECS component buffers.

ECSConfig.ECSPropertiesStride = 4 :: number
-- Byte stride per entity for the bitpacked u32 Properties ECS buffer (CanCollide, IsVisible, Anchored, HasDynamicId, TextureId, ShapeId, DynamicId).

ECSConfig.ECSPropertiesBufferSize = 40000 :: number
-- Allocated byte capacity for each 4-byte-stride Properties ECS buffer.

ECSConfig.DynamicObjectsMaxCount = 1023 :: number
-- Maximum 10-bit ID capacity (bits 22-31 of the Properties u32 register) for the Dynamic OOP / Objects List.

-- Server ECS Builder & Replication --

ECSConfig.ReplicationTickInterval = 0 :: number
-- Yield duration in seconds between server replication delta broadcast passes.

ECSConfig.StaticObjectsFolderName = "Static" :: string
-- Name of the Workspace folder whose descendant BaseParts are flagged as static entities in the server ECS.

ECSConfig.WorkspaceCleanupDelay = 5 :: number
-- Delay in seconds after server startup before original Workspace BaseParts are destroyed once registered in the ECS.

ECSConfig.CoreEventsFolderName = "CoreEvents" :: string
-- Name of the ReplicatedStorage folder containing networking RemoteEvents.

ECSConfig.ReplicateRemoteEventName = "ReplicateEvent" :: string
-- Name of the RemoteEvent used to replicate ECS component delta buffers from server to client.

return ECSConfig
