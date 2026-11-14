--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const BVH = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("BVH"))
const PhysicsMathHelper = require(script.Parent.PhysicsMathHelper)

-- Configs --
const GRAVITY = SystemsConfigs.PhysicsGravity :: number
const WALKABLE_NORMAL_Y = SystemsConfigs.PlayerWalkableNormalY :: number

const OBJECT_LINEAR_DRAG = SystemsConfigs.ObjectLinearDrag :: number
const OBJECT_SURFACE_FRICTION = SystemsConfigs.ObjectSurfaceFriction :: number

const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const MAX_ENTITIES = SystemsConfigs.ECSMaxEntities :: number
const BROADPHASE_PADDING = SystemsConfigs.PhysicsBroadphasePadding :: number

-- Buffers --
const BroadphaseCandidatesBuffer = buffer.create(MAX_ENTITIES * 4) :: buffer

-- Callbacks --
local WakeEntityCallback: ((EntityId: number) -> ())? = nil

local PhysicsMath = {}

--[=[
	Registers a callback invoked when collision resolution wakes a sleeping dynamic entity.
	@param Callback ((EntityId: number) -> ())? -- Optional callback receiving the woken EntityId.
]=]
function PhysicsMath.SetWakeEntityCallback(Callback: ((EntityId: number) -> ())?)
	WakeEntityCallback = Callback
end

-- ============================================================================
-- 1. VELOCITY & INERTIA INTEGRATION
-- ============================================================================

--[=[
	Integrates external forces, gravity, and drag onto a dynamic object's linear velocity.
	@param VelocityX number -- Current velocity X.
	@param VelocityY number -- Current velocity Y.
	@param VelocityZ number -- Current velocity Z.
	@param ForceX number -- Net force X in Newtons.
	@param ForceY number -- Net force Y in Newtons.
	@param ForceZ number -- Net force Z in Newtons.
	@param InverseMass number -- 1 / mass in kg.
	@param IsGrounded boolean -- Whether resting on a surface.
	@param DeltaTime number -- Elapsed frame time in seconds.
	@return (number, number, number) -- NextVelocityX, NextVelocityY, NextVelocityZ.
]=]
function PhysicsMath.StepObjectVelocity(
	VelocityX: number,
	VelocityY: number,
	VelocityZ: number,
	ForceX: number,
	ForceY: number,
	ForceZ: number,
	InverseMass: number,
	IsGrounded: boolean,
	DeltaTime: number
): (number, number, number)
	const AccelerationScale = InverseMass * DeltaTime :: number
	local NextVelocityX = VelocityX + ForceX * AccelerationScale :: number
	local NextVelocityY = VelocityY + ForceY * AccelerationScale - GRAVITY * DeltaTime :: number
	local NextVelocityZ = VelocityZ + ForceZ * AccelerationScale :: number

	const LinearDecay = math.max(0, 1 - OBJECT_LINEAR_DRAG * DeltaTime) :: number
	NextVelocityX *= LinearDecay
	NextVelocityY *= LinearDecay
	NextVelocityZ *= LinearDecay

	if IsGrounded then
		const SurfaceDecay = math.max(0, 1 - OBJECT_SURFACE_FRICTION * DeltaTime) :: number
		NextVelocityX *= SurfaceDecay
		NextVelocityZ *= SurfaceDecay
	end

	return NextVelocityX, NextVelocityY, NextVelocityZ
end

-- ============================================================================
-- 2. COLLISION DETECTION & IMPULSE RESOLUTION (BOX VS ECS OBB)
-- ============================================================================

--[=[
	Performs a Separating Axis Theorem (SAT) collision test between an axis-aligned box body and an oriented ECS box.
	@param BodyX number -- Center position X of the testing body.
	@param BodyY number -- Center position Y of the testing body.
	@param BodyZ number -- Center position Z of the testing body.
	@param BodyHalfSizeX number -- Half size X of the testing body.
	@param BodyHalfSizeY number -- Half size Y of the testing body.
	@param BodyHalfSizeZ number -- Half size Z of the testing body.
	@param CompOffset number -- Byte offset in position/size buffers for the target entity.
	@param DirOffset number -- Byte offset in directions buffer for the target entity.
	@param PositionBuffer buffer -- ECS positions buffer.
	@param SizeBuffer buffer -- ECS sizes buffer.
	@param DirectionsBuffer buffer -- ECS directions buffer.
	@return (boolean, number, number, number, number) -- Overlaps, NormalX, NormalY, NormalZ, Penetration.
]=]
function PhysicsMath.TestBoxVsOBB(
	BodyX: number,
	BodyY: number,
	BodyZ: number,
	BodyHalfSizeX: number,
	BodyHalfSizeY: number,
	BodyHalfSizeZ: number,
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

	const DeltaX = BodyX - buffer.readf32(PositionBuffer, CompOffset) :: number
	const DeltaY = BodyY - buffer.readf32(PositionBuffer, CompOffset + 4) :: number
	const DeltaZ = BodyZ - buffer.readf32(PositionBuffer, CompOffset + 8) :: number

	-- Broadphase rejection before reading the 36-byte orientation basis
	const BroadphaseRadius = (SizeX + SizeY + SizeZ) * 0.5 :: number
	if
		math.abs(DeltaX) > BodyHalfSizeX + BroadphaseRadius
		or math.abs(DeltaY) > BodyHalfSizeY + BroadphaseRadius
		or math.abs(DeltaZ) > BodyHalfSizeZ + BroadphaseRadius
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

	const HalfSizeX: number, HalfSizeY: number, HalfSizeZ: number = SizeX * 0.5, SizeY * 0.5, SizeZ * 0.5

	const WorldExtentX =
		math.abs(RightX) * HalfSizeX + math.abs(UpX) * HalfSizeY + math.abs(LookX) * HalfSizeZ :: number
	const OverlapX = (BodyHalfSizeX + WorldExtentX) - math.abs(DeltaX) :: number
	if OverlapX <= 0 then
		return false, 0, 0, 0, 0
	end

	const WorldExtentY =
		math.abs(RightY) * HalfSizeX + math.abs(UpY) * HalfSizeY + math.abs(LookY) * HalfSizeZ :: number
	const OverlapY = (BodyHalfSizeY + WorldExtentY) - math.abs(DeltaY) :: number
	if OverlapY <= 0 then
		return false, 0, 0, 0, 0
	end

	const WorldExtentZ =
		math.abs(RightZ) * HalfSizeX + math.abs(UpZ) * HalfSizeY + math.abs(LookZ) * HalfSizeZ :: number
	const OverlapZ = (BodyHalfSizeZ + WorldExtentZ) - math.abs(DeltaZ) :: number
	if OverlapZ <= 0 then
		return false, 0, 0, 0, 0
	end

	local MinOverlap = OverlapY :: number
	local BestNormalX = 0 :: number
	local BestNormalY = if DeltaY >= 0 then 1 else -1 :: number
	local BestNormalZ = 0 :: number

	if OverlapX < MinOverlap then
		MinOverlap = OverlapX
		BestNormalX = if DeltaX >= 0 then 1 else -1
		BestNormalY = 0
		BestNormalZ = 0
	end

	if OverlapZ < MinOverlap then
		MinOverlap = OverlapZ
		BestNormalX = 0
		BestNormalY = 0
		BestNormalZ = if DeltaZ >= 0 then 1 else -1
	end

	const UpAxisDistance = DeltaX * UpX + DeltaY * UpY + DeltaZ * UpZ :: number
	const BodyProjectedUp =
		math.abs(UpX) * BodyHalfSizeX + math.abs(UpY) * BodyHalfSizeY + math.abs(UpZ) * BodyHalfSizeZ :: number
	const OverlapUp = (BodyProjectedUp + HalfSizeY) - math.abs(UpAxisDistance) :: number
	if OverlapUp <= 0 then
		return false, 0, 0, 0, 0
	end

	if OverlapUp < MinOverlap then
		const UpAxisSign = if UpAxisDistance >= 0 then 1 else -1 :: number
		MinOverlap = OverlapUp
		BestNormalX, BestNormalY, BestNormalZ = UpX * UpAxisSign, UpY * UpAxisSign, UpZ * UpAxisSign
	end

	const RightAxisDistance = DeltaX * RightX + DeltaY * RightY + DeltaZ * RightZ :: number
	const BodyProjectedRight =
		math.abs(RightX) * BodyHalfSizeX + math.abs(RightY) * BodyHalfSizeY + math.abs(RightZ) * BodyHalfSizeZ :: number
	const OverlapRight = (BodyProjectedRight + HalfSizeX) - math.abs(RightAxisDistance) :: number
	if OverlapRight <= 0 then
		return false, 0, 0, 0, 0
	end

	if OverlapRight < MinOverlap then
		const RightAxisSign = if RightAxisDistance >= 0 then 1 else -1 :: number
		MinOverlap = OverlapRight
		BestNormalX, BestNormalY, BestNormalZ = RightX * RightAxisSign, RightY * RightAxisSign, RightZ * RightAxisSign
	end

	const LookAxisDistance = DeltaX * LookX + DeltaY * LookY + DeltaZ * LookZ :: number
	const BodyProjectedLook =
		math.abs(LookX) * BodyHalfSizeX + math.abs(LookY) * BodyHalfSizeY + math.abs(LookZ) * BodyHalfSizeZ :: number
	const OverlapLook = (BodyProjectedLook + HalfSizeZ) - math.abs(LookAxisDistance) :: number
	if OverlapLook <= 0 then
		return false, 0, 0, 0, 0
	end

	if OverlapLook < MinOverlap then
		const LookAxisSign = if LookAxisDistance >= 0 then 1 else -1 :: number
		MinOverlap = OverlapLook
		BestNormalX, BestNormalY, BestNormalZ = LookX * LookAxisSign, LookY * LookAxisSign, LookZ * LookAxisSign
	end

	return true, BestNormalX, BestNormalY, BestNormalZ, MinOverlap
end

--[=[
	Resolves broadphase and narrowphase collisions between a dynamic body and the world using BVH and SAT.
	@param BodyX number -- Body center position X.
	@param BodyY number -- Body center position Y.
	@param BodyZ number -- Body center position Z.
	@param BodyHalfSizeX number -- Body half extent X.
	@param BodyHalfSizeY number -- Body half extent Y.
	@param BodyHalfSizeZ number -- Body half extent Z.
	@param VelocityX number -- Body linear velocity X.
	@param VelocityY number -- Body linear velocity Y.
	@param VelocityZ number -- Body linear velocity Z.
	@param BodyInverseMass number -- 1 / mass in kg.
	@param Restitution number -- Coefficient of restitution.
	@param IgnoreEntityId number -- Entity ID to ignore during collision.
	@param EntityCount number -- Total active ECS entity count.
	@param PositionBuffer buffer -- ECS positions buffer.
	@param SizeBuffer buffer -- ECS sizes buffer.
	@param DirectionsBuffer buffer -- ECS directions buffer.
	@param DynamicFlags buffer -- ECS dynamic flags buffer.
	@param ObjectVelocityBuffer buffer -- Dynamic objects velocity buffer.
	@param ObjectInvMassBuffer buffer -- Dynamic objects inverse mass buffer.
	@return (number, number, number, number, number, number, boolean) -- NextX, NextY, NextZ, NextVelX, NextVelY, NextVelZ, Grounded.
]=]
function PhysicsMath.ResolveBodyWorldCollisions(
	BodyX: number,
	BodyY: number,
	BodyZ: number,
	BodyHalfSizeX: number,
	BodyHalfSizeY: number,
	BodyHalfSizeZ: number,
	VelocityX: number,
	VelocityY: number,
	VelocityZ: number,
	BodyInverseMass: number,
	Restitution: number,
	IgnoreEntityId: number,
	EntityCount: number,
	PositionBuffer: buffer,
	SizeBuffer: buffer,
	DirectionsBuffer: buffer,
	DynamicFlags: buffer,
	ObjectVelocityBuffer: buffer,
	ObjectInvMassBuffer: buffer,
	SkipBVHNeedsRebuild: boolean?
): (number, number, number, number, number, number, boolean)
	local NextX = BodyX :: number
	local NextY = BodyY :: number
	local NextZ = BodyZ :: number
	local NextVelocityX = VelocityX :: number
	local NextVelocityY = VelocityY :: number
	local NextVelocityZ = VelocityZ :: number
	local Grounded = false :: boolean

	const QueryPadX = BodyHalfSizeX + BROADPHASE_PADDING :: number
	const QueryPadY = BodyHalfSizeY + BROADPHASE_PADDING :: number
	const QueryPadZ = BodyHalfSizeZ + BROADPHASE_PADDING :: number
	const CandidateCount = BVH.QueryAABBScalar(
		NextX - QueryPadX,
		NextY - QueryPadY,
		NextZ - QueryPadZ,
		NextX + QueryPadX,
		NextY + QueryPadY,
		NextZ + QueryPadZ,
		BroadphaseCandidatesBuffer,
		MAX_ENTITIES,
		nil,
		SkipBVHNeedsRebuild
	) :: number

	for CandidateIdx = 0, CandidateCount - 1 do
		const EntityId = buffer.readu32(BroadphaseCandidatesBuffer, CandidateIdx * 4) :: number
		if EntityId == IgnoreEntityId or EntityId < 1 or EntityId > EntityCount then
			continue
		end

		const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
		const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number

		const Hit: boolean, NormalX: number, NormalY: number, NormalZ: number, Penetration: number =
			PhysicsMath.TestBoxVsOBB(
				NextX,
				NextY,
				NextZ,
				BodyHalfSizeX,
				BodyHalfSizeY,
				BodyHalfSizeZ,
				CompOffset,
				DirOffset,
				PositionBuffer,
				SizeBuffer,
				DirectionsBuffer
			)

		if not Hit then
			continue
		end

		if NormalY >= WALKABLE_NORMAL_Y then
			Grounded = true
		end

		const OtherDynamicState = buffer.readu8(DynamicFlags, EntityId - 1) :: number
		if OtherDynamicState > 0 then
			NextX, NextY, NextZ, NextVelocityX, NextVelocityY, NextVelocityZ =
				PhysicsMathHelper.ResolveDynamicPairContact(
					NextX,
					NextY,
					NextZ,
					NextVelocityX,
					NextVelocityY,
					NextVelocityZ,
					BodyInverseMass,
					EntityId,
					NormalX,
					NormalY,
					NormalZ,
					Penetration,
					PositionBuffer,
					DynamicFlags,
					ObjectVelocityBuffer,
					ObjectInvMassBuffer
				)
			if OtherDynamicState == 2 and WakeEntityCallback and buffer.readu8(DynamicFlags, EntityId - 1) == 1 then
				WakeEntityCallback(EntityId)
			end
			continue
		end

		NextX += NormalX * Penetration
		NextY += NormalY * Penetration
		NextZ += NormalZ * Penetration

		const NormalVelocity = NextVelocityX * NormalX + NextVelocityY * NormalY + NextVelocityZ * NormalZ :: number
		if NormalVelocity < 0 then
			const BounceScale = -(1 + Restitution) * NormalVelocity :: number
			NextVelocityX += NormalX * BounceScale
			NextVelocityY += NormalY * BounceScale
			NextVelocityZ += NormalZ * BounceScale
		end
	end

	return NextX, NextY, NextZ, NextVelocityX, NextVelocityY, NextVelocityZ, Grounded
end

return PhysicsMath
