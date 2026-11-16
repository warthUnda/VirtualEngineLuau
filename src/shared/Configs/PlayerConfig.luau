--!strict
--!native
--!optimize 2

-- Tables --
local PlayerConfig = {}

-- Configs --

-- Player ECS Rendering & Collider Settings --

PlayerConfig.PlayerRenderSize = Vector3.new(2.0, 5.0, 2.0) :: Vector3
-- Bounding box dimensions (X, Y, Z) in studs for rendered player ECS entities (matches 2x PhysicsConfig.PlayerHalfExtents).

PlayerConfig.PlayerDefaultColor = Color3.fromRGB(90, 170, 255) :: Color3
-- Fallback RGB color applied to rendered player ECS entities when no character body color is present.

PlayerConfig.PlayerRenderShape = "Cube" :: string
-- VerticeFile shape preset name used to rasterize player ECS entities.

PlayerConfig.PlayerCanCollide = true :: boolean
-- Whether remote player ECS entities act as solid colliders in BVH raycasts and physics contact queries.

-- Player Network Sync Settings --

PlayerConfig.PlayerStateRemoteEventName = "PlayerStateEvent" :: string
-- Name of the UnreliableRemoteEvent inside CoreEvents streaming compact 20-byte binary player transforms from client to server.

PlayerConfig.PlayerRegistryRemoteEventName = "PlayerRegistryEvent" :: string
-- Name of the RemoteEvent inside CoreEvents synchronizing active player DynamicObjectsList OOP bindings to clients.

PlayerConfig.PlayerSyncInterval = 0.05 :: number
-- Minimum interval in seconds between client-to-server player transform sync packets.

PlayerConfig.PlayerStatePayloadBytes = 20 :: number
-- Byte stride of the binary player state payload (PosX, PosY, PosZ, LookX, LookZ as 5 x f32).

return PlayerConfig
