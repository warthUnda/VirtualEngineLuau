--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const BVH = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("BVH"))
const PhysicsMathHelper = require(script.Parent.PhysicsMathHelper)
const PhysicsSATMath = require(script.Parent.PhysicsSATMath)

-- Configs --
const GRAVITY = SystemsConfigs.PhysicsGravity :: number
const WALKABLE_NORMAL_Y = SystemsConfigs.PlayerWalkableNormalY :: number
const OBJECT_LINEAR_DRAG = SystemsConfigs.ObjectLinearDrag :: number
const OBJECT_SURFACE_FRICTION = SystemsConfigs.ObjectSurfaceFriction :: number
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const MAX_ENTITIES = SystemsConfigs.ECSMaxEntities :: number
const BROADPHASE_PADDING = SystemsConfigs.PhysicsBroadphasePadding :: number
const DENORMAL_EPSILON = 1e-12 :: number

-- Variables --
local WakeEntityCallback: ((EntityId: number) -> ())? = nil

-- Tables --
local PhysicsMath = {
	TestBoxVsOBB = PhysicsSATMath.TestBoxVsOBB,
}

-- Buffers
const BroadphaseCandidatesBuffer = buffer.create(MAX_ENTITIES * 4) :: buffer

-- Functions --

-- ============================================================================
-- 1. VELOCITY INTEGRATION & BROADPHASE/SAT COLLISION RESOLUTION FACADE
-- ============================================================================

--[=[
	Registers a callback invoked when collision resolution wakes a sleeping dynamic entity.
]=]
function PhysicsMath.SetWakeEntityCallback(Callback: ((EntityId: number) -> ())?)
	WakeEntityCallback = Callback
end

--[=[
	Integrates external forces, gravity, and drag onto a dynamic object's linear velocity.
]=]
function PhysicsMath.StepObjectVelocity(
	VelocityX: number, VelocityY: number, VelocityZ: number,
	ForceX: number, ForceY: number, ForceZ: number,
	InverseMass: number,
	IsGrounded: boolean,
	DeltaTime: number
): (number, number, number)
	const AccelerationScale = InverseMass * DeltaTime :: number
	const LinearDecay = math.max(0, 1 - OBJECT_LINEAR_DRAG * DeltaTime) :: number
	const HorizontalDecay = if IsGrounded
		then LinearDecay * math.max(0, 1 - OBJECT_SURFACE_FRICTION * DeltaTime)
		else LinearDecay :: number

	const RawVelocityX = (VelocityX + ForceX * AccelerationScale) * HorizontalDecay :: number
	const RawVelocityY = (VelocityY + ForceY * AccelerationScale - GRAVITY * DeltaTime) * LinearDecay :: number
	const RawVelocityZ = (VelocityZ + ForceZ * AccelerationScale) * HorizontalDecay :: number

	return if math.abs(RawVelocityX) < DENORMAL_EPSILON then 0 else RawVelocityX,
		if math.abs(RawVelocityY) < DENORMAL_EPSILON then 0 else RawVelocityY,
		if math.abs(RawVelocityZ) < DENORMAL_EPSILON then 0 else RawVelocityZ
end

--[=[
	Resolves broadphase and narrowphase collisions between a dynamic body and the world using BVH and SAT.
]=]
function PhysicsMath.ResolveBodyWorldCollisions(
	BodyX: number, BodyY: number, BodyZ: number,
	BodyHalfSizeX: number, BodyHalfSizeY: number, BodyHalfSizeZ: number,
	VelocityX: number, VelocityY: number, VelocityZ: number,
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
	if (BodyX - BodyX) + (BodyY - BodyY) + (BodyZ - BodyZ) ~= 0 then
		return 0, 0, 0, 0, 0, 0, false
	end

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
		NextX - QueryPadX, NextY - QueryPadY, NextZ - QueryPadZ,
		NextX + QueryPadX, NextY + QueryPadY, NextZ + QueryPadZ,
		BroadphaseCandidatesBuffer, MAX_ENTITIES, nil, SkipBVHNeedsRebuild
	) :: number

	const TestOBB = PhysicsSATMath.TestBoxVsOBB
	const ResolveDynamic = PhysicsMathHelper.ResolveDynamicPairContact
	const WakeCallback = WakeEntityCallback
	const NegOnePlusRestitution = -(1 + Restitution) :: number
	for CandidateIdx = 0, CandidateCount - 1 do
		const EntityId = buffer.readu32(BroadphaseCandidatesBuffer, CandidateIdx * 4) :: number
		if EntityId == IgnoreEntityId or EntityId < 1 or EntityId > EntityCount then
			continue
		end

		const OtherCompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
		const OtherDirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
		const Hit: boolean, NormalX: number, NormalY: number, NormalZ: number, Penetration: number = TestOBB(
			NextX, NextY, NextZ, BodyHalfSizeX, BodyHalfSizeY, BodyHalfSizeZ,
			OtherCompOffset, OtherDirOffset,
			PositionBuffer, SizeBuffer, DirectionsBuffer
		)
		if not Hit then
			continue
		end

		Grounded = Grounded or (NormalY >= WALKABLE_NORMAL_Y)

		const OtherDynamicState = buffer.readu8(DynamicFlags, EntityId - 1) :: number
		if OtherDynamicState > 0 then
			NextX, NextY, NextZ, NextVelocityX, NextVelocityY, NextVelocityZ = ResolveDynamic(
				NextX, NextY, NextZ, NextVelocityX, NextVelocityY, NextVelocityZ,
				BodyInverseMass, EntityId, NormalX, NormalY, NormalZ, Penetration,
				PositionBuffer, DynamicFlags, ObjectVelocityBuffer, ObjectInvMassBuffer
			)
			if OtherDynamicState == 2 and WakeCallback and buffer.readu8(DynamicFlags, EntityId - 1) == 1 then
				WakeCallback(EntityId)
			end
			continue
		end

		NextX += NormalX * Penetration
		NextY += NormalY * Penetration
		NextZ += NormalZ * Penetration

		const NormalVelocity = NextVelocityX * NormalX + NextVelocityY * NormalY + NextVelocityZ * NormalZ :: number
		if NormalVelocity < 0 then
			const BounceScale = NegOnePlusRestitution * NormalVelocity :: number
			NextVelocityX += NormalX * BounceScale
			NextVelocityY += NormalY * BounceScale
			NextVelocityZ += NormalZ * BounceScale
		end
	end

	return NextX, NextY, NextZ, NextVelocityX, NextVelocityY, NextVelocityZ, Grounded
end

return PhysicsMath
