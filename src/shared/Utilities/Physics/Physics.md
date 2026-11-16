# Physics Simulation & Kinematics System

## Classification & Domain Terminology
- **Domain:** Continuous & Discrete Rigid-Body Kinematics / Character Dynamics
- **Subsystem:** Custom Deterministic Sub-Stepped Physics Solver
- **Contact Model:** Separating Axis Theorem (SAT) OBB-vs-OBB and Box-vs-OBB Contact Resolution
- **Integration Scheme:** Semi-Implicit Euler with Multi-Substep Time Discretization

---

## Modular Decomposition & File Layout

### Controller Modules (`src/shared/Utilities/Physics/Controller/`)
- **`PhysicsController.luau`**: Thin frame and substep loop orchestrator executing player and active dynamic rigid body steps.
- **`PhysicsControllerHelper.luau`**: Helper for dynamic mass calculation, launch direction resolution, per-entity dynamic substep integration, and force clearing.
- **`PhysicsInputGateway.luau`**: Isolates Roblox actor storage resolution, character spawn binding, and keyboard input sampling.
- **`PhysicsInstanceManager.luau`**: Dynamic entity launching (`StartSimulatingEntity`), continuous/impulse movement (`ApplyObjectMovement`), and simulation stopping (`StopSimulatingEntity`).
- **`PhysicsAwakeState.luau`**: Dense awake entity tracking (`AwakeEntitiesBuffer`, `AwakeEntitySlotBuffer`), velocity/force buffers, and `SetSwapPopCallback` synchronization.

### Core Modules (`src/shared/Utilities/Physics/Core/`)
- **`PhysicsMath.luau`**: Core physics facade for linear velocity integration, broadphase candidate filtering, and world collision resolution.
- **`PhysicsSATMath.luau`**: Pure Separating Axis Theorem (SAT) narrowphase collision kernel between an axis-aligned box body and an oriented ECS box.
- **`PhysicsRotationMath.luau`**: Rodrigues' axis-angle formula, angular velocity integration, contact roll coupling, and orthonormal basis updates.
- **`PhysicsMathHelper.luau`**: Pairwise dynamic collision impulse resolution and contact restitution.
- **`PlayerPhysics.luau`**: Dedicated player kinematic velocity stepping, grounded driving, stopping friction, and airborne steering.

### Public Facade (`src/shared/Utilities/Physics/PhysicsLibrary/`)
- **`init.luau`**: Public consumer API for moving players, launching instances, teleportation, and querying velocities.

---

## Architectural Mechanisms

### 1. Kinematic Velocity, Ground Interaction & Character Independence
- **`PlayerPhysics` (`Core/PlayerPhysics`)**: Houses player-specific kinematics (`StepPlayerVelocity`, `IntegrateGroundedDrive`, `IntegrateAirborneDrive`, `ApplyStopFriction`), separating character drive/friction/jump math from general rigid-body physics in `PhysicsMath`.
- **One-Time Spawn Seeding (`PhysicsController.BindCharacter`)**: Optionally seeds the initial player spawn position once from an initial `Character` model (without requiring a `Humanoid` or `HumanoidRootPart`, falling back to `PrimaryPart`, any `BasePart`, `GetPivot()`, or `PlayerDefaultSpawnPosition`) and continues simulating player kinematics completely standalone even after the `Character` or `Humanoid` is destroyed.
- **Wish-Direction Projection:** Character and dynamic bodies project horizontal intent vectors (`WishX`, `WishZ`) scaled by maximum speed caps.
- **Dynamic Friction & Air Drag:** Velocity decays under surface friction when grounded, or gentle quadratic aerodynamic drag when airborne.
- **Ground Snapping & Normal Alignment:** Checks vertical penetration and restores contact states without jitter.

### 2. Multi-Substepping Simulation Pipeline
- Evaluates discrete micro-steps per frame (`SystemsConfigs.PhysicsSubsteps`).
- Caps delta time via `SystemsConfigs.PhysicsMaxDeltaTime` to prevent tunneling and stability breakdowns under lag spikes.
- Accumulates external impulses and continuous forces into dedicated single-precision buffers (`ObjectForceBuffer`, `ObjectVelocityBuffer`).

### 3. Contact Detection & SAT Penetration Resolution
- **`PhysicsMath.TestBoxVsOBB`**: Implements separating axis projection tests between character bounding volumes and environment OBBs.
- Computes minimum translation distance (`MinOverlap`) and the surface normal (`BestNormal`) along the principal axis of least penetration.
- **Position & Momentum Transfer:** Displaces intersecting bodies out of geometry and updates momentum according to inverse mass ratios (`PLAYER_INV_MASS`, `ObjectInvMassBuffer`).

### 4. Modular Controller Decomposition & Awake-List Entity Management (`PhysicsController`, `PhysicsInstanceManager`, `PhysicsAwakeState`, `PhysicsInputGateway`, `PhysicsControllerHelper`, `PhysicsLibrary`)
- **`PhysicsController` & `PhysicsInstanceManager`**: `PhysicsController` acts as the thin simulation facade while `PhysicsInstanceManager` handles `ApplyObjectMovement`, `StartSimulatingEntity`, and `StopSimulatingEntity` (checking `FLAG_ANCHORED` and falling back to prepackaged `PhysicsConfig` defaults `ObjectDefaultLaunchAngle`, `ObjectDefaultImpulse`, and `ObjectDefaultSpeed`). `PhysicsInputGateway` isolates Actor storage resolution, character binding, and keyboard sampling.
- Exposes high-level player state APIs: `SetPlayerPosition`, `GetPlayerPosition`, `SetPlayerVelocity`, and `GetPlayerVelocity`.
- Manages wake/sleep states and tumbling angular velocity via a dense `AwakeEntitiesBuffer` / `AwakeEntitySlotBuffer` (`O(AwakeCount)` iteration instead of scanning all entities), calls `BVH.EnsureFresh()` once per substep, wakes sleeping entities collided in `PhysicsMath`, marks mutated bodies via `ECSData.MarkDirty`, and stays synchronized across `DeleteEntity` swap-pops via `SetSwapPopCallback`.
