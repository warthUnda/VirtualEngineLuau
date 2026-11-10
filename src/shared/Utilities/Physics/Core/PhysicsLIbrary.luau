--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs")) :: ModuleScript

-- Configs --
const GRAVITY = SystemsConfigs.PhysicsGravity :: number
const FALL_GRAVITY_MULTIPLIER = SystemsConfigs.PhysicsFallGravityMultiplier :: number

const PLAYER_MASS = SystemsConfigs.PlayerMass :: number
const PLAYER_INV_MASS = 1 / PLAYER_MASS :: number
const PLAYER_MOVE_FORCE = SystemsConfigs.PlayerMoveForce :: number
const PLAYER_MAX_GROUND_SPEED = SystemsConfigs.PlayerMaxGroundSpeed :: number
const PLAYER_GROUND_FRICTION = SystemsConfigs.PlayerGroundFriction :: number
const PLAYER_BRAKE_MULTIPLIER = SystemsConfigs.PlayerBrakeMultiplier :: number
const PLAYER_STOP_SPEED = SystemsConfigs.PlayerStopSpeed :: number
const PLAYER_AIR_CONTROL = SystemsConfigs.PlayerAirControlMultiplier :: number
const PLAYER_AIR_DRAG = SystemsConfigs.PlayerAirDrag :: number
const PLAYER_JUMP_VELOCITY = SystemsConfigs.PlayerJumpImpulse / PLAYER_MASS :: number
const WALKABLE_NORMAL_Y = SystemsConfigs.PlayerWalkableNormalY :: number

const OBJECT_LINEAR_DRAG = SystemsConfigs.ObjectLinearDrag :: number
const OBJECT_SURFACE_FRICTION = SystemsConfigs.ObjectSurfaceFriction :: number
const OBJECT_RESTITUTION = SystemsConfigs.ObjectRestitution :: number

const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number

local PhysicsLibrary = {}

-- ============================================================================
-- 1. VELOCITY & INERTIA INTEGRATION
-- ============================================================================

local function ApplyStopFriction(Vx: number, Vz: number, FrictionRate: number, Dt: number): (number, number)
	const HorizSpeed = math.sqrt(Vx * Vx + Vz * Vz) :: number
	if HorizSpeed <= 1e-5 then
		return 0, 0
	end

	const Control = math.max(HorizSpeed, PLAYER_STOP_SPEED) :: number
	const Drop = Control * FrictionRate * Dt :: number
	const Scale = math.max(0, HorizSpeed - Drop) / HorizSpeed :: number
	return Vx * Scale, Vz * Scale
end

local function IntegrateGroundedDrive(
	Vx: number,
	Vz: number,
	WishX: number,
	WishZ: number,
	WishScale: number,
	Dt: number
): (number, number)
	if WishScale <= 1e-4 then
		return ApplyStopFriction(Vx, Vz, PLAYER_GROUND_FRICTION * PLAYER_BRAKE_MULTIPLIER, Dt)
	end

	local ParallelSpeed = Vx * WishX + Vz * WishZ :: number
	const LateralDecay = math.max(0, 1 - PLAYER_GROUND_FRICTION * Dt) :: number
	const LateralX = (Vx - ParallelSpeed * WishX) * LateralDecay :: number
	const LateralZ = (Vz - ParallelSpeed * WishZ) * LateralDecay :: number

	const TargetSpeed = PLAYER_MAX_GROUND_SPEED * WishScale :: number
	const DriveStep = (PLAYER_MOVE_FORCE * PLAYER_INV_MASS) * WishScale * Dt :: number

	if ParallelSpeed < 0 then
		const BrakeDecay = math.max(0, 1 - PLAYER_GROUND_FRICTION * PLAYER_BRAKE_MULTIPLIER * Dt) :: number
		ParallelSpeed = math.min(TargetSpeed, ParallelSpeed * BrakeDecay + DriveStep)
	elseif ParallelSpeed < TargetSpeed then
		ParallelSpeed = math.min(TargetSpeed, ParallelSpeed + DriveStep)
	else
		ParallelSpeed = math.max(TargetSpeed, ParallelSpeed - ParallelSpeed * PLAYER_GROUND_FRICTION * Dt)
	end

	return LateralX + WishX * ParallelSpeed, LateralZ + WishZ * ParallelSpeed
end

local function IntegrateAirborneDrive(
	Vx: number,
	Vz: number,
	WishX: number,
	WishZ: number,
	WishScale: number,
	Dt: number
): (number, number)
	const AirDecay = math.max(0, 1 - PLAYER_AIR_DRAG * Dt) :: number
	local NextVx = Vx * AirDecay :: number
	local NextVz = Vz * AirDecay :: number

	if WishScale <= 1e-4 then
		return NextVx, NextVz
	end

	const ProjectedSpeed = NextVx * WishX + NextVz * WishZ :: number
	const TargetSpeed = PLAYER_MAX_GROUND_SPEED * WishScale :: number
	const MaxAirStep = (PLAYER_MOVE_FORCE * PLAYER_INV_MASS * PLAYER_AIR_CONTROL) * WishScale * Dt :: number
	const AirAdd = math.clamp(TargetSpeed - ProjectedSpeed, 0, MaxAirStep) :: number

	return NextVx + WishX * AirAdd, NextVz + WishZ * AirAdd
end

function PhysicsLibrary.StepPlayerVelocity(
	Vx: number,
	Vy: number,
	Vz: number,
	WishX: number,
	WishZ: number,
	WishScale: number,
	JumpRequested: boolean,
	IsGrounded: boolean,
	Dt: number
): (number, number, number, boolean)
	local NextVx = Vx :: number
	local NextVy = Vy :: number
	local NextVz = Vz :: number
	local NextGrounded = IsGrounded :: boolean

	if NextGrounded then
		NextVx, NextVz = IntegrateGroundedDrive(NextVx, NextVz, WishX, WishZ, WishScale, Dt)
		if JumpRequested then
			NextVy = math.max(NextVy, PLAYER_JUMP_VELOCITY)
			NextGrounded = false
		end
	else
		NextVx, NextVz = IntegrateAirborneDrive(NextVx, NextVz, WishX, WishZ, WishScale, Dt)
	end

	const GravityScale = if NextVy < 0 then FALL_GRAVITY_MULTIPLIER else 1.0 :: number
	NextVy -= GRAVITY * GravityScale * Dt

	return NextVx, NextVy, NextVz, NextGrounded
end

function PhysicsLibrary.StepObjectVelocity(
	Vx: number,
	Vy: number,
	Vz: number,
	ForceX: number,
	ForceY: number,
	ForceZ: number,
	InvMass: number,
	IsGrounded: boolean,
	Dt: number
): (number, number, number)
	const AccelScale = InvMass * Dt :: number
	local NextVx = Vx + ForceX * AccelScale :: number
	local NextVy = Vy + ForceY * AccelScale - GRAVITY * Dt :: number
	local NextVz = Vz + ForceZ * AccelScale :: number

	const LinearDecay = math.max(0, 1 - OBJECT_LINEAR_DRAG * Dt) :: number
	NextVx *= LinearDecay
	NextVy *= LinearDecay
	NextVz *= LinearDecay

	if IsGrounded then
		const SurfaceDecay = math.max(0, 1 - OBJECT_SURFACE_FRICTION * Dt) :: number
		NextVx *= SurfaceDecay
		NextVz *= SurfaceDecay
	end

	return NextVx, NextVy, NextVz
end

-- ============================================================================
-- 2. COLLISION DETECTION & IMPULSE RESOLUTION (BOX VS ECS OBB)
-- ============================================================================

function PhysicsLibrary.TestBoxVsOBB(
	BodyX: number,
	BodyY: number,
	BodyZ: number,
	BodyHx: number,
	BodyHy: number,
	BodyHz: number,
	CompOffset: number,
	DirOffset: number,
	PositionBuffer: buffer,
	SizeBuffer: buffer,
	DirectionsBuffer: buffer
): (boolean, number, number, number, number)
	const SizeX = buffer.readf32(SizeBuffer, CompOffset) :: number
	const SizeY = buffer.readf32(SizeBuffer, CompOffset + 4) :: number
	const SizeZ = buffer.readf32(SizeBuffer, CompOffset + 8) :: number
	if SizeX <= 0 or SizeY <= 0 or SizeZ <= 0 then
		return false, 0, 0, 0, 0
	end

	const Dx = BodyX - buffer.readf32(PositionBuffer, CompOffset) :: number
	const Dy = BodyY - buffer.readf32(PositionBuffer, CompOffset + 4) :: number
	const Dz = BodyZ - buffer.readf32(PositionBuffer, CompOffset + 8) :: number

	-- Broadphase rejection before reading the 36-byte orientation basis
	const BroadRadius = (SizeX + SizeY + SizeZ) * 0.5 :: number
	if
		math.abs(Dx) > BodyHx + BroadRadius
		or math.abs(Dy) > BodyHy + BroadRadius
		or math.abs(Dz) > BodyHz + BroadRadius
	then
		return false, 0, 0, 0, 0
	end

	local LookX = buffer.readf32(DirectionsBuffer, DirOffset) :: number
	local LookY = buffer.readf32(DirectionsBuffer, DirOffset + 4) :: number
	local LookZ = buffer.readf32(DirectionsBuffer, DirOffset + 8) :: number

	local UpX = buffer.readf32(DirectionsBuffer, DirOffset + 12) :: number
	local UpY = buffer.readf32(DirectionsBuffer, DirOffset + 16) :: number
	local UpZ = buffer.readf32(DirectionsBuffer, DirOffset + 20) :: number

	local RightX = buffer.readf32(DirectionsBuffer, DirOffset + 24) :: number
	local RightY = buffer.readf32(DirectionsBuffer, DirOffset + 28) :: number
	local RightZ = buffer.readf32(DirectionsBuffer, DirOffset + 32) :: number

	if RightX * RightX + RightY * RightY + RightZ * RightZ < 0.5 then
		LookX, LookY, LookZ = 0, 0, -1
		UpX, UpY, UpZ = 0, 1, 0
		RightX, RightY, RightZ = 1, 0, 0
	end

	const Hx: number, Hy: number, Hz: number = SizeX * 0.5, SizeY * 0.5, SizeZ * 0.5

	const WorldHx = math.abs(RightX) * Hx + math.abs(UpX) * Hy + math.abs(LookX) * Hz :: number
	const OverlapX = (BodyHx + WorldHx) - math.abs(Dx) :: number
	if OverlapX <= 0 then
		return false, 0, 0, 0, 0
	end

	const WorldHy = math.abs(RightY) * Hx + math.abs(UpY) * Hy + math.abs(LookY) * Hz :: number
	const OverlapY = (BodyHy + WorldHy) - math.abs(Dy) :: number
	if OverlapY <= 0 then
		return false, 0, 0, 0, 0
	end

	const WorldHz = math.abs(RightZ) * Hx + math.abs(UpZ) * Hy + math.abs(LookZ) * Hz :: number
	const OverlapZ = (BodyHz + WorldHz) - math.abs(Dz) :: number
	if OverlapZ <= 0 then
		return false, 0, 0, 0, 0
	end

	local MinOverlap = OverlapY :: number
	local BestNx = 0 :: number
	local BestNy = if Dy >= 0 then 1 else -1 :: number
	local BestNz = 0 :: number

	if OverlapX < MinOverlap then
		MinOverlap = OverlapX
		BestNx = if Dx >= 0 then 1 else -1
		BestNy = 0
		BestNz = 0
	end

	if OverlapZ < MinOverlap then
		MinOverlap = OverlapZ
		BestNx = 0
		BestNy = 0
		BestNz = if Dz >= 0 then 1 else -1
	end

	const DistU = Dx * UpX + Dy * UpY + Dz * UpZ :: number
	const BodyProjU = math.abs(UpX) * BodyHx + math.abs(UpY) * BodyHy + math.abs(UpZ) * BodyHz :: number
	const OverlapU = (BodyProjU + Hy) - math.abs(DistU) :: number
	if OverlapU <= 0 then
		return false, 0, 0, 0, 0
	end

	if OverlapU < MinOverlap then
		const SignU = if DistU >= 0 then 1 else -1 :: number
		MinOverlap = OverlapU
		BestNx, BestNy, BestNz = UpX * SignU, UpY * SignU, UpZ * SignU
	end

	const DistR = Dx * RightX + Dy * RightY + Dz * RightZ :: number
	const BodyProjR = math.abs(RightX) * BodyHx + math.abs(RightY) * BodyHy + math.abs(RightZ) * BodyHz :: number
	const OverlapR = (BodyProjR + Hx) - math.abs(DistR) :: number
	if OverlapR <= 0 then
		return false, 0, 0, 0, 0
	end

	if OverlapR < MinOverlap then
		const SignR = if DistR >= 0 then 1 else -1 :: number
		MinOverlap = OverlapR
		BestNx, BestNy, BestNz = RightX * SignR, RightY * SignR, RightZ * SignR
	end

	const DistL = Dx * LookX + Dy * LookY + Dz * LookZ :: number
	const BodyProjL = math.abs(LookX) * BodyHx + math.abs(LookY) * BodyHy + math.abs(LookZ) * BodyHz :: number
	const OverlapL = (BodyProjL + Hz) - math.abs(DistL) :: number
	if OverlapL <= 0 then
		return false, 0, 0, 0, 0
	end

	if OverlapL < MinOverlap then
		const SignL = if DistL >= 0 then 1 else -1 :: number
		MinOverlap = OverlapL
		BestNx, BestNy, BestNz = LookX * SignL, LookY * SignL, LookZ * SignL
	end

	return true, BestNx, BestNy, BestNz, MinOverlap
end

local function ResolveDynamicPairContact(
	BodyX: number,
	BodyY: number,
	BodyZ: number,
	Vx: number,
	Vy: number,
	Vz: number,
	BodyInvMass: number,
	OtherEntityIndex: number,
	Nx: number,
	Ny: number,
	Nz: number,
	Penetration: number,
	PositionBuffer: buffer,
	DynamicFlags: buffer,
	ObjectVelocityBuffer: buffer,
	ObjectInvMassBuffer: buffer
): (number, number, number, number, number, number)
	const FlagIndex = OtherEntityIndex - 1 :: number
	const OtherCompOffset = FlagIndex * COMPONENT_STRIDE :: number
	const OtherInvMass = buffer.readf32(ObjectInvMassBuffer, FlagIndex * 4) :: number
	const TotalInvMass = BodyInvMass + OtherInvMass :: number

	if TotalInvMass <= 1e-6 then
		return BodyX + Nx * Penetration, BodyY + Ny * Penetration, BodyZ + Nz * Penetration, Vx, Vy, Vz
	end

	buffer.writeu8(DynamicFlags, FlagIndex, 1)

	const BodyShare = BodyInvMass / TotalInvMass :: number
	const OtherShare = OtherInvMass / TotalInvMass :: number

	const NextBodyX = BodyX + Nx * (Penetration * BodyShare) :: number
	const NextBodyY = BodyY + Ny * (Penetration * BodyShare) :: number
	const NextBodyZ = BodyZ + Nz * (Penetration * BodyShare) :: number

	buffer.writef32(
		PositionBuffer,
		OtherCompOffset,
		buffer.readf32(PositionBuffer, OtherCompOffset) - Nx * (Penetration * OtherShare)
	)
	buffer.writef32(
		PositionBuffer,
		OtherCompOffset + 4,
		buffer.readf32(PositionBuffer, OtherCompOffset + 4) - Ny * (Penetration * OtherShare)
	)
	buffer.writef32(
		PositionBuffer,
		OtherCompOffset + 8,
		buffer.readf32(PositionBuffer, OtherCompOffset + 8) - Nz * (Penetration * OtherShare)
	)

	const OtherVx = buffer.readf32(ObjectVelocityBuffer, OtherCompOffset) :: number
	const OtherVy = buffer.readf32(ObjectVelocityBuffer, OtherCompOffset + 4) :: number
	const OtherVz = buffer.readf32(ObjectVelocityBuffer, OtherCompOffset + 8) :: number

	const RelVn = (Vx - OtherVx) * Nx + (Vy - OtherVy) * Ny + (Vz - OtherVz) * Nz :: number
	if RelVn >= 0 then
		return NextBodyX, NextBodyY, NextBodyZ, Vx, Vy, Vz
	end

	const ImpulseScalar = -(1 + OBJECT_RESTITUTION) * RelVn / TotalInvMass :: number
	const BodyImpulse = ImpulseScalar * BodyInvMass :: number
	const OtherImpulse = ImpulseScalar * OtherInvMass :: number

	buffer.writef32(ObjectVelocityBuffer, OtherCompOffset, OtherVx - Nx * OtherImpulse)
	buffer.writef32(ObjectVelocityBuffer, OtherCompOffset + 4, OtherVy - Ny * OtherImpulse)
	buffer.writef32(ObjectVelocityBuffer, OtherCompOffset + 8, OtherVz - Nz * OtherImpulse)

	return NextBodyX, NextBodyY, NextBodyZ, Vx + Nx * BodyImpulse, Vy + Ny * BodyImpulse, Vz + Nz * BodyImpulse
end

function PhysicsLibrary.ResolveBodyWorldCollisions(
	BodyX: number,
	BodyY: number,
	BodyZ: number,
	BodyHx: number,
	BodyHy: number,
	BodyHz: number,
	Vx: number,
	Vy: number,
	Vz: number,
	BodyInvMass: number,
	Restitution: number,
	IgnoreEntityId: number,
	EntityCount: number,
	PositionBuffer: buffer,
	SizeBuffer: buffer,
	DirectionsBuffer: buffer,
	DynamicFlags: buffer,
	ObjectVelocityBuffer: buffer,
	ObjectInvMassBuffer: buffer
): (number, number, number, number, number, number, boolean)
	local NextX = BodyX :: number
	local NextY = BodyY :: number
	local NextZ = BodyZ :: number
	local NextVx = Vx :: number
	local NextVy = Vy :: number
	local NextVz = Vz :: number
	local Grounded = false :: boolean

	for i = 1, EntityCount do
		if i == IgnoreEntityId then
			continue
		end

		const CompOffset = (i - 1) * COMPONENT_STRIDE :: number
		const DirOffset = (i - 1) * DIRECTION_STRIDE :: number

		const Hit: boolean, Nx: number, Ny: number, Nz: number, Penetration: number = PhysicsLibrary.TestBoxVsOBB(
			NextX,
			NextY,
			NextZ,
			BodyHx,
			BodyHy,
			BodyHz,
			CompOffset,
			DirOffset,
			PositionBuffer,
			SizeBuffer,
			DirectionsBuffer
		)

		if not Hit then
			continue
		end

		if Ny >= WALKABLE_NORMAL_Y then
			Grounded = true
		end

		const OtherDynamicState = buffer.readu8(DynamicFlags, i - 1) :: number
		if OtherDynamicState > 0 then
			NextX, NextY, NextZ, NextVx, NextVy, NextVz = ResolveDynamicPairContact(
				NextX,
				NextY,
				NextZ,
				NextVx,
				NextVy,
				NextVz,
				BodyInvMass,
				i,
				Nx,
				Ny,
				Nz,
				Penetration,
				PositionBuffer,
				DynamicFlags,
				ObjectVelocityBuffer,
				ObjectInvMassBuffer
			)
			continue
		end

		NextX += Nx * Penetration
		NextY += Ny * Penetration
		NextZ += Nz * Penetration

		const Vn = NextVx * Nx + NextVy * Ny + NextVz * Nz :: number
		if Vn < 0 then
			const BounceScale = -(1 + Restitution) * Vn :: number
			NextVx += Nx * BounceScale
			NextVy += Ny * BounceScale
			NextVz += Nz * BounceScale
		end
	end

	return NextX, NextY, NextZ, NextVx, NextVy, NextVz, Grounded
end

return PhysicsLibrary
