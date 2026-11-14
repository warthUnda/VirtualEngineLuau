--!strict
--!native
--!optimize 2

local PhysicsConfig = {}

PhysicsConfig.PhysicsGravity = 98.0 :: number
-- Downward gravitational acceleration in studs per second squared.

PhysicsConfig.PhysicsFallGravityMultiplier = 1.2 :: number
-- Multiplier applied to downward gravity when falling so jump arcs feel grounded rather than floaty.

PhysicsConfig.PhysicsMaxDeltaTime = 0.05 :: number
-- Maximum clamped frame delta time in seconds to prevent tunneling during frame spikes.

PhysicsConfig.PhysicsSubsteps = 2 :: number
-- Number of physics integration and collision substeps executed per frame.

PhysicsConfig.PlayerDefaultSpawnPosition = Vector3.new(0, 12, 0) :: Vector3
-- Fallback world spawn position for the player physics body when no character root part is present.

PhysicsConfig.PlayerVoidResetY = -500.0 :: number
-- World Y threshold below which the player physics body resets back to its spawn position.

PhysicsConfig.PlayerMass = 80.0 :: number
-- Mass of the player physics body in kilograms used for force acceleration and collision impulses.

PhysicsConfig.PlayerHalfExtents = Vector3.new(1.0, 2.5, 1.0) :: Vector3
-- Collision box half-extents (X, Y, Z) in studs for the player physics body.

PhysicsConfig.PlayerMoveForce = 4400.0 :: number
-- Horizontal driving force in Newtons applied to accelerate the player on grounded surfaces.

PhysicsConfig.PlayerMaxGroundSpeed = 60 :: number
-- Target maximum horizontal ground speed in studs per second.

PhysicsConfig.PlayerGroundFriction = 10.0 :: number
-- Ground traction damping rate per second applied to lateral drift and coasting velocity.

PhysicsConfig.PlayerBrakeMultiplier = 1.65 :: number
-- Extra braking multiplier applied when releasing movement input or counter-steering against momentum.

PhysicsConfig.PlayerStopSpeed = 4.0 :: number
-- Minimum speed reference in studs per second used to bring low-speed coasting cleanly to rest.

PhysicsConfig.PlayerAirControlMultiplier = 0.2 :: number
-- Fraction of ground driving force available while airborne so jumps preserve takeoff inertia.

PhysicsConfig.PlayerAirDrag = 0.45 :: number
-- Linear aerodynamic drag per second applied while the player is airborne.

PhysicsConfig.PlayerJumpImpulse = 2600.0 :: number
-- Upward impulse in Newton-seconds applied when jumping from grounded contact.

PhysicsConfig.PlayerWalkableNormalY = 0.65 :: number
-- Minimum surface normal Y component required for a contact to count as walkable ground.

PhysicsConfig.ObjectDefaultDensity = 1.2 :: number
-- Default mass per cubic stud used to derive dynamic ECS entity mass from bounding volume.

PhysicsConfig.ObjectLinearDrag = 0.6 :: number
-- Linear air damping per second applied to dynamic ECS object velocities.

PhysicsConfig.ObjectSurfaceFriction = 6.5 :: number
-- Tangential surface friction rate per second applied to dynamic ECS objects in contact.

PhysicsConfig.ObjectRestitution = 0.15 :: number
-- Normal impact restitution (0-1) for dynamic ECS object collisions.

PhysicsConfig.ObjectDefaultLaunchAngle = Vector3.new(0.7, 0.2, 0.7).Unit :: Vector3
-- Default unit launch direction vector applied when SimulateInstance is called with a nil Angle parameter.

PhysicsConfig.ObjectDefaultImpulse = 30.0 :: number
-- Default instantaneous impulse magnitude (kg*m/s) applied when SimulateInstance is called with a nil Impulse parameter.

PhysicsConfig.ObjectDefaultSpeed = 16.0 :: number
-- Default initial linear speed (studs/s) applied when SimulateInstance is called with a nil Speed parameter.

PhysicsConfig.ObjectAngularDrag = 0.35 :: number
-- Rotational velocity damping rate per second applied to airborne dynamic ECS objects.

PhysicsConfig.ObjectRollCoupling = 14.0 :: number
-- Coupling rate converting tangential contact velocity into rolling and tumbling angular velocity.

PhysicsConfig.ObjectSleepSpeedThreshold = 0.08 :: number
-- Velocity magnitude threshold in studs per second below which grounded dynamic objects settle to sleep.

PhysicsConfig.PhysicsBroadphasePadding = 4.0 :: number
-- World-space AABB padding in studs around a moving body when querying the BVH for collision candidates.

PhysicsConfig.PlayerMaxWishScale = 2.5 :: number
-- Maximum movement speed multiplier allowed when combining directional player movement inputs.

return PhysicsConfig
