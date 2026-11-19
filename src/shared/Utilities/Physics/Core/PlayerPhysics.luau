--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const GRAVITY = SystemsConfigs.PhysicsGravity :: number
const FALL_GRAVITY = GRAVITY * SystemsConfigs.PhysicsFallGravityMultiplier :: number

const PLAYER_MASS = SystemsConfigs.PlayerMass :: number
const PLAYER_INV_MASS = 1 / PLAYER_MASS :: number
const PLAYER_JUMP_VELOCITY = SystemsConfigs.PlayerJumpImpulse / PLAYER_MASS :: number
const PLAYER_MOVE_ACCEL = SystemsConfigs.PlayerMoveForce * PLAYER_INV_MASS :: number
const PLAYER_AIR_ACCEL = PLAYER_MOVE_ACCEL * SystemsConfigs.PlayerAirControlMultiplier :: number
const PLAYER_MAX_GROUND_SPEED = SystemsConfigs.PlayerMaxGroundSpeed :: number
const PLAYER_GROUND_FRICTION = SystemsConfigs.PlayerGroundFriction :: number
const PLAYER_BRAKE_FRICTION = PLAYER_GROUND_FRICTION * SystemsConfigs.PlayerBrakeMultiplier :: number
const PLAYER_STOP_SPEED = SystemsConfigs.PlayerStopSpeed :: number
const PLAYER_AIR_DRAG = SystemsConfigs.PlayerAirDrag :: number
const STOP_SPEED_SQ = 1e-10 :: number
const DENORMAL_EPSILON = 1e-12 :: number

-- Tables --
local PlayerPhysics = {}

-- Functions --

-- ============================================================================
-- 1. PLAYER KINEMATICS - FRICTION, DRIVE INTEGRATION & VELOCITY STEP
-- ============================================================================

--[=[
	Applies ground stopping friction to bring horizontal velocity smoothly to rest.
	@param VelocityX number -- Current horizontal velocity X.
	@param VelocityZ number -- Current horizontal velocity Z.
	@param FrictionRate number -- Rate of ground friction decay.
	@param DeltaTime number -- Elapsed frame time in seconds.
	@return (number, number) -- Decelerated (VelocityX, VelocityZ).
]=]
function PlayerPhysics.ApplyStopFriction(
	VelocityX: number,
	VelocityZ: number,
	FrictionRate: number,
	DeltaTime: number
): (number, number)
	const SpeedSq = VelocityX * VelocityX + VelocityZ * VelocityZ :: number
	if SpeedSq <= STOP_SPEED_SQ then
		return 0, 0
	end

	const HorizontalSpeed = math.sqrt(SpeedSq) :: number
	const ControlSpeed = math.max(HorizontalSpeed, PLAYER_STOP_SPEED) :: number
	const SpeedDrop = ControlSpeed * FrictionRate * DeltaTime :: number
	if SpeedDrop >= HorizontalSpeed then
		return 0, 0
	end

	const RetainedScale = (HorizontalSpeed - SpeedDrop) / HorizontalSpeed :: number
	return VelocityX * RetainedScale, VelocityZ * RetainedScale
end

--[=[
	Integrates player horizontal ground acceleration and directional braking against wish intent.
	@param VelocityX number -- Current horizontal velocity X.
	@param VelocityZ number -- Current horizontal velocity Z.
	@param WishX number -- Desired unit wish direction X.
	@param WishZ number -- Desired unit wish direction Z.
	@param WishScale number -- Wish speed multiplier.
	@param DeltaTime number -- Elapsed frame time in seconds.
	@return (number, number) -- Next (VelocityX, VelocityZ).
]=]
function PlayerPhysics.IntegrateGroundedDrive(
	VelocityX: number,
	VelocityZ: number,
	WishX: number,
	WishZ: number,
	WishScale: number,
	DeltaTime: number
): (number, number)
	if WishScale <= 1e-4 then
		return PlayerPhysics.ApplyStopFriction(
			VelocityX,
			VelocityZ,
			PLAYER_BRAKE_FRICTION,
			DeltaTime
		)
	end

	local ParallelSpeed = VelocityX * WishX + VelocityZ * WishZ :: number
	const LateralDecay = math.max(0, 1 - PLAYER_GROUND_FRICTION * DeltaTime) :: number
	const LateralVelocityX = (VelocityX - ParallelSpeed * WishX) * LateralDecay :: number
	const LateralVelocityZ = (VelocityZ - ParallelSpeed * WishZ) * LateralDecay :: number

	const TargetSpeed = PLAYER_MAX_GROUND_SPEED * WishScale :: number
	const DriveStep = PLAYER_MOVE_ACCEL * WishScale * DeltaTime :: number

	if ParallelSpeed < 0 then
		const BrakeDecay = math.max(0, 1 - PLAYER_BRAKE_FRICTION * DeltaTime) :: number
		ParallelSpeed = math.min(TargetSpeed, ParallelSpeed * BrakeDecay + DriveStep)
	elseif ParallelSpeed < TargetSpeed then
		ParallelSpeed = math.min(TargetSpeed, ParallelSpeed + DriveStep)
	else
		ParallelSpeed = math.max(TargetSpeed, ParallelSpeed * LateralDecay)
	end

	const NextVelocityX = LateralVelocityX + WishX * ParallelSpeed :: number
	const NextVelocityZ = LateralVelocityZ + WishZ * ParallelSpeed :: number
	return if math.abs(NextVelocityX) < DENORMAL_EPSILON then 0 else NextVelocityX,
		if math.abs(NextVelocityZ) < DENORMAL_EPSILON then 0 else NextVelocityZ
end

--[=[
	Integrates player airborne velocity, applying air resistance and responsive air-control steering.
	@param VelocityX number -- Current horizontal velocity X.
	@param VelocityZ number -- Current horizontal velocity Z.
	@param WishX number -- Desired unit wish direction X.
	@param WishZ number -- Desired unit wish direction Z.
	@param WishScale number -- Wish speed multiplier.
	@param DeltaTime number -- Elapsed frame time in seconds.
	@return (number, number) -- Next (VelocityX, VelocityZ).
]=]
function PlayerPhysics.IntegrateAirborneDrive(
	VelocityX: number,
	VelocityZ: number,
	WishX: number,
	WishZ: number,
	WishScale: number,
	DeltaTime: number
): (number, number)
	const AirDecay = math.max(0, 1 - PLAYER_AIR_DRAG * DeltaTime) :: number
	const RawVelocityX = VelocityX * AirDecay :: number
	const RawVelocityZ = VelocityZ * AirDecay :: number
	const NextVelocityX = if math.abs(RawVelocityX) < DENORMAL_EPSILON then 0 else RawVelocityX :: number
	const NextVelocityZ = if math.abs(RawVelocityZ) < DENORMAL_EPSILON then 0 else RawVelocityZ :: number

	if WishScale <= 1e-4 then
		return NextVelocityX, NextVelocityZ
	end

	const ProjectedSpeed = NextVelocityX * WishX + NextVelocityZ * WishZ :: number
	const TargetSpeed = PLAYER_MAX_GROUND_SPEED * WishScale :: number
	const MaxAirStep = PLAYER_AIR_ACCEL * WishScale * DeltaTime :: number
	const AirAddedSpeed = math.clamp(TargetSpeed - ProjectedSpeed, 0, MaxAirStep) :: number

	return NextVelocityX + WishX * AirAddedSpeed, NextVelocityZ + WishZ * AirAddedSpeed
end

--[=[
	Steps player linear velocity forward by DeltaTime, applying ground or airborne wish drive, friction, jump, and gravity.
	@param VelocityX number -- Current velocity X.
	@param VelocityY number -- Current velocity Y.
	@param VelocityZ number -- Current velocity Z.
	@param WishX number -- Normalized horizontal wish direction X.
	@param WishZ number -- Normalized horizontal wish direction Z.
	@param WishScale number -- Desired movement speed scalar.
	@param JumpRequested boolean -- True if jump button is active.
	@param IsGrounded boolean -- True if resting on a walkable surface.
	@param DeltaTime number -- Elapsed frame time in seconds.
	@return (number, number, number, boolean) -- NextVelocityX, NextVelocityY, NextVelocityZ, NextGrounded.
]=]
function PlayerPhysics.StepPlayerVelocity(
	VelocityX: number,
	VelocityY: number,
	VelocityZ: number,
	WishX: number,
	WishZ: number,
	WishScale: number,
	JumpRequested: boolean,
	IsGrounded: boolean,
	DeltaTime: number
): (number, number, number, boolean)
	local NextVelocityX = VelocityX :: number
	local NextVelocityY = VelocityY :: number
	local NextVelocityZ = VelocityZ :: number
	local NextGrounded = IsGrounded :: boolean

	if NextGrounded then
		NextVelocityX, NextVelocityZ = PlayerPhysics.IntegrateGroundedDrive(
			NextVelocityX,
			NextVelocityZ,
			WishX,
			WishZ,
			WishScale,
			DeltaTime
		)
		if JumpRequested then
			NextVelocityY = math.max(NextVelocityY, PLAYER_JUMP_VELOCITY)
			NextGrounded = false
		end
	else
		NextVelocityX, NextVelocityZ = PlayerPhysics.IntegrateAirborneDrive(
			NextVelocityX,
			NextVelocityZ,
			WishX,
			WishZ,
			WishScale,
			DeltaTime
		)
	end

	NextVelocityY -= (if NextVelocityY < 0 then FALL_GRAVITY else GRAVITY) * DeltaTime

	return NextVelocityX, NextVelocityY, NextVelocityZ, NextGrounded
end

return PlayerPhysics
