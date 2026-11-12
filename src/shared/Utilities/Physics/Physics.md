# Physics Simulation & Kinematics System

## Classification & Domain Terminology
- **Domain:** Continuous & Discrete Rigid-Body Kinematics / Character Dynamics
- **Subsystem:** Custom Deterministic Sub-Stepped Physics Solver
- **Contact Model:** Separating Axis Theorem (SAT) OBB-vs-OBB and Box-vs-OBB Contact Resolution
- **Integration Scheme:** Semi-Implicit Euler with Multi-Substep Time Discretization

---

## Architectural Mechanisms

### 1. Kinematic Velocity & Ground Interaction
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

### 4. PhysicsLibrary & Dynamic Entity Management
- Exposes high-level state APIs: `SetPlayerPosition`, `GetPlayerPosition`, `SetPlayerVelocity`, and `GetPlayerVelocity`.
- Manages wake/sleep states for dynamic ECS bodies (`DynamicFlags`: 0 = static, 1 = awake, 2 = sleeping).
