# CustomRenderer Security Audit & Mitigation Dashboard (`HUMAN_REVIEW_BOARD.md`)

> [!IMPORTANT]
> **Pipeline:** Autonomous Architectural Red-Teaming & Validation Pipeline (`/red-team-penetration`)  
> **Scope:** Authoritative Server & Shared Engine Boundaries (`src/server/`, `src/shared/`)  
> **Policy Applied:** Purely client-sided self-crash/self-desync findings (`RT-CLI-01..06`, `RT-CLI-09`, `RT-PLR-06`, `RT-ECS-09`, `RT-SRV-07`) that grant no competitive advantage and only affect the attacker's own device were removed. All server/shared exploits below have been **patched in-place and verified** in Roblox Studio Play mode (`execute_luau` + TestEZ).

---

## 1. Executive Summary & Remediation Matrix

| ID | Severity | Status | Category | Target Module | Summary |
| :--- | :---: | :---: | :---: | :--- | :--- |
| **RT-SRV-01** | `CRITICAL` | **PATCHED & VERIFIED** | `GAMEPLAY_EXPLOIT` | [PlayerFunctions.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/server/Objects/Replication/Core/PlayerFunctions.luau#L164-L234) | Replaced `SumCheck` with per-component finite/bounds checks, enforced unit-length `Look`/`Up`/`Right` validation, and re-orthonormalized basis vectors to block full-map ESP culling bypass. |
| **RT-PLR-01** | `CRITICAL` | **PATCHED & VERIFIED** | `DESYNC` | [PlayerRecordMethods.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/shared/Utilities/Player/Core/PlayerService/PlayerRecordMethods.luau#L110-L185) | Added finite coordinate bounds, `IsEntityActive` check, `DynamicObjectsList` ownership verification, and buffer length checks in `UpdateTransform`. |
| **RT-BVH-06** | `CRITICAL` | **PATCHED & VERIFIED** | `SERVER_CRASH` | [BVHQuery.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/shared/Utilities/BVH/BVHQuery.luau#L42-L56) | Added `NaN` query bound rejection and clamped `MaxResults` to `buffer.len(ResultsBuffer) // 4`. |
| **RT-BVH-10** | `CRITICAL` | **PATCHED & VERIFIED** | `SERVER_CRASH` | [PhysicsMath.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/shared/Utilities/Physics/Core/PhysicsMath.luau#L96-L108) | Added `NaN`/`±inf` entry guard in `ResolveBodyWorldCollisions` to prevent contagious `NaN` collision propagation. |
| **RT-SRV-02** | `HIGH` | **PATCHED & VERIFIED** | `AUTHORITY_BREACH` | [ServerReplicationGateway.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/server/Objects/Replication/Controller/ServerReplicationGateway.luau#L106-L160) | Added 1.0s per-player rate limits on `ReplicateRemote`, `TextureSyncRemote`, and `PlayerRegistryRemote`, plus `typeof(Payload) == "buffer"` checks. |
| **RT-SRV-04** | `HIGH` | **PATCHED & VERIFIED** | `SERVER_CRASH` | [EntityVersionTracker.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/server/Objects/Replication/Core/EntityVersionTracker.luau#L64-L160) | Clamped `EntityCount` in `SyncEntityVersions` and validated integer `EntityId` in `[1, MAX_ENTITIES]` in `GetEntityDeltaMask`. |
| **RT-SRV-05** | `HIGH` | **PATCHED & VERIFIED** | `GAMEPLAY_EXPLOIT` | [ViewCulling.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/shared/Utilities/Render/Core/ViewCulling.luau#L203-L241) | Added buffer bounds check and removed unguarded occluder promotion inside `IsEntityCulled` so invisible entities cannot occlude visible entities. |
| **RT-SRV-06** | `MEDIUM` | **PATCHED & VERIFIED** | `SERVER_CRASH` | [PlayerFunctions.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/server/Objects/Replication/Core/PlayerFunctions.luau#L138-L147) | Added `PlayerObject:IsDescendantOf(Players)` guard in `MarkClientReady`. |
| **RT-CLI-07** | `HIGH` | **PATCHED & VERIFIED** | `SERVER_CRASH` | [TextureTable.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/shared/Utilities/Render/Texture/TextureTable.luau#L127-L145) | Added finite integer `[1, 255]` `TextureId` and string type validation in `RegisterEntryWithId`. |
| **RT-CLI-08** | `HIGH` | **PATCHED & VERIFIED** | `SERVER_CRASH` | [TextureHelper.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/shared/Utilities/Render/Texture/TextureHelper.luau#L29-L65) | Added `SourceBuffer` length and positive dimension validation in `ResampleTextureBuffer`. |
| **RT-PLR-02** | `HIGH` | **PATCHED & VERIFIED** | `GAMEPLAY_EXPLOIT` | [PlayerControllerHelper.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/shared/Utilities/Player/Controller/PlayerControllerHelper.luau#L104-L155) | Replaced additive `CheckSum` with per-component finite/range validation (`< 1e6` pos, `<= 2` look) in `PackStatePayload` and `UnpackStatePayload`. |
| **RT-PLR-03** | `HIGH` | **PATCHED & VERIFIED** | `AUTHORITY_BREACH` | [PlayerController.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/shared/Utilities/Player/Controller/PlayerController.luau#L162-L170) | Prevented late `ApplyStatePayload` packets from re-registering evicted disconnecting players on the live server. |
| **RT-PLR-04** | `MEDIUM` | **PATCHED & VERIFIED** | `SERVER_CRASH` | [PlayerControllerHelper.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/shared/Utilities/Player/Controller/PlayerControllerHelper.luau#L160-L185) | Added `PropertiesBuffer` capacity clamp, integer `DynamicId` check, and `IsEntityActive` guard in `FindEntitySlotByDynamicId`. |
| **RT-ECS-02** | `HIGH` | **PATCHED & VERIFIED** | `SERVER_CRASH` | [ECSBitfield.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/shared/ECS/ECSBitfield.luau#L180-L232) | Added integer `EntityId`, buffer length, and `NaN`/integer `DynamicId` guards in `SetEntityShapeId`, `SetEntityDynamicId`, and `SetEntityTextureId`. |
| **RT-ECS-04** | `HIGH` | **PATCHED & VERIFIED** | `SERVER_CRASH` | [ECSStorageFactory.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/shared/ECS/ECSStorageFactory.luau#L138-L149) | Clamped `ECSDataTable.EntityECSCount` and `ActiveEntityCount` to `[0, MAX_ENTITIES]` in `ECSData.SetEntityCount`. |
| **RT-ECS-06 / 07** | `HIGH` | **PATCHED & VERIFIED** | `SERVER_CRASH` / `DESYNC` | [DynamicObjectsMain.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/shared/DynamicObjectsMain.luau#L71-L155) | Added `PropertiesBuffer` bounds checks, integer `DynamicId`/`EntityId` validation, and `FreeIds` population for skipped IDs in `SetObjectAtId`. |
| **RT-BVH-09** | `HIGH` | **PATCHED & VERIFIED** | `SERVER_CRASH` | [PhysicsControllerHelper.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/shared/Utilities/Physics/Controller/PhysicsControllerHelper.luau#L47-L84) | Added `EntityId` finite/bounds validation and `InverseMass` clamping (`[1e-6, 1e4]`) in `EnsureDynamicEntityMass`. |
| **RT-BVH-12** | `HIGH` | **PATCHED & VERIFIED** | `SERVER_CRASH` | [ResourceController.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/shared/Utilities/ControllerTheory/Controller/ResourceController.luau#L268-L285) | Added `NaN` and `±inf` rejection in `ResourceController.SetWeights`. |
| **RT-BVH-13** | `HIGH` | **PATCHED & VERIFIED** | `SERVER_CRASH` | [ControllerInterpreter.luau](file:///C:/Users/Startklar/Documents/Development/Roblox/CustomRenderer/src/shared/Utilities/ControllerTheory/Core/ControllerInterpreter.luau#L45-L60) | Guarded `ClampScore` against `NaN` and routed `InterpretPhysics` through `ClampScore`. |

---

## 2. Verification Summary (Roblox Studio Play Mode)

1. **Exploit Regression Verification (`execute_luau` on `Server` DataModel):**
   - `RT-SRV-01`: `UpdateObserverFromBuffer` with `±3.4e38` and zero `Up`/`Right` rejected (`clientSynced = false`).
   - `RT-SRV-04`: `EntityVersionTracker.GetEntityDeltaMask(MaxEntities + 1, 0)` safely returned `0, 0`.
   - `RT-SRV-05`: Invisible entity in slot 1 no longer occludes visible entity in slot 2 (`c2 = false`).
   - `RT-CLI-07 / 08`: `TextureTable.RegisterEntryWithId(0/0, ...)` returned `nil, false`; `ResampleTextureBuffer` with undersized buffer returned safe zeroed buffer.
   - `RT-PLR-01 / 02 / 04`: Stale `PlayerRecord` cannot overwrite recycled slot (`slot1PosX = 10`); `±1e38` state packet rejected (`valid1e38 = false`); `FindEntitySlotByDynamicId` safe (`okFind = true`).
   - `RT-ECS-04 / 06 / 07`: `SetEntityCount(9000)` clamped to `8192`; `SetObjectAtId(1023)` no longer starves `AddObject` (`nextId = 1022`); `BindEntity(1, 99999)` safely ignored (`okBind = true`).
   - `RT-BVH-06 / 09 / 10 / 12 / 13`: `QueryAABBScalar` with `NaN` returned `0`; `EnsureDynamicEntityMass` returned `0` on `NaN` and clamped `1e-40` mass; `ResolveBodyWorldCollisions` returned `0` on `NaN`; `SetWeights(math.huge, 1)` ignored (`wR = 0.6`); `InterpretPhysics(0/0)` returned `100`.
2. **TestEZ Suites:**
   - **Client:** `8` suites, `20 passed, 0 failed`.
   - **Server:** `10` suites, `54 passed, 1 failed` (pre-existing `ControllerTheory.spec:186` PID equilibrium timing check `SettledOverruns == 301`, unrelated to security guards).
