--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))
const BVHMath = require(script.Parent.BVHMath)
const BVHState = require(script.Parent.BVHState)
const BVHDynamicSweep = require(script.Parent.BVHDynamicSweep)

-- Configs --
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const STACK_CAPACITY = SystemsConfigs.BVHStackCapacity :: number
const FLAG_HAS_DYNAMIC_ID = bit32.lshift(1, 4) :: number
const DYNAMIC_ID_SHIFT = 22 :: number

-- Tables --
local BVHRaycast = {}

-- Functions --
-- ============================================================================
-- 1. UNIFIED RAYCAST (STATIC BVH + LIVE DYNAMIC ENTITIES & OOP OBJECTS)
-- ============================================================================

--[=[
	Casts a ray through the BVH hierarchy returning the closest hit entity and OOP object.
	@param ProvidedStorage ECSMain.ECSStorage? -- Optional explicit ECS storage override.
	@param Origin Vector3 -- World-space ray origin.
	@param DirectionVector Vector3 -- World-space ray direction.
	@param MaxDistance number? -- Optional max ray distance override.
	@return (number?, any?, number, Vector3?, Vector3?) -- HitEntityId, HitDynamicObject, Distance, HitPosition, HitNormal.
]=]
function BVHRaycast.Raycast(
	ProvidedStorage: ECSMain.ECSStorage?,
	Origin: Vector3,
	DirectionVector: Vector3,
	MaxDistance: number?
): (number?, any?, number, Vector3?, Vector3?)
	if typeof(Origin) ~= "Vector3" or typeof(DirectionVector) ~= "Vector3" then
		return nil, nil, 0, nil, nil
	end

	const OriginX: number, OriginY: number, OriginZ: number = Origin.X, Origin.Y, Origin.Z
	if OriginX ~= OriginX or OriginY ~= OriginY or OriginZ ~= OriginZ
		or math.abs(OriginX) == math.huge or math.abs(OriginY) == math.huge or math.abs(OriginZ) == math.huge then
		return nil, nil, 0, nil, nil
	end

	const DirectionLength = DirectionVector.Magnitude :: number
	if not (DirectionLength > 1e-8 and DirectionLength < math.huge) then return nil, nil, 0, nil, nil end
	if MaxDistance ~= nil and not (MaxDistance > 0) then return nil, nil, 0, nil, nil end

	const InverseDirectionLength = 1 / DirectionLength :: number
	const DirectionX: number, DirectionY: number, DirectionZ: number =
		DirectionVector.X * InverseDirectionLength,
		DirectionVector.Y * InverseDirectionLength,
		DirectionVector.Z * InverseDirectionLength
	const ResolvedMaxDistance = if MaxDistance then math.min(MaxDistance, 1e15) else DirectionLength :: number

	const Storage, EntityCount = BVHState.EnsureFreshAndResolve(ProvidedStorage, false)
	if not Storage then
		return nil, nil, ResolvedMaxDistance, nil, nil
	end

	const InverseDirectionX = if math.abs(DirectionX) > 1e-8 then 1 / DirectionX else (if DirectionX >= 0 then 1e30 else -1e30) :: number
	const InverseDirectionY = if math.abs(DirectionY) > 1e-8 then 1 / DirectionY else (if DirectionY >= 0 then 1e30 else -1e30) :: number
	const InverseDirectionZ = if math.abs(DirectionZ) > 1e-8 then 1 / DirectionZ else (if DirectionZ >= 0 then 1e30 else -1e30) :: number

	const PositionBuffer = Storage.PositionData.GetData() :: buffer
	const SizeBuffer = Storage.SizeData.GetData() :: buffer
	const DirectionsBuffer = Storage.DirectionsData.GetData() :: buffer
	const PropertiesBuffer = Storage.PropertiesData.GetData() :: buffer
	const DynamicObjectsList = Storage.DynamicObjectsList

	const NodeBuffer = BVHState.NodeBuffer
	const TraversalStackBuffer = BVHState.TraversalStackBuffer
	const TestedGenBuffer = BVHState.TestedGenBuffer
	const DynamicEntitiesBuffer = BVHState.DynamicEntitiesBuffer

	BVHState.RayGeneration += 1
	const CurrentRayGen = BVHState.RayGeneration :: number

	local ClosestDistance = ResolvedMaxDistance :: number
	local HitEntityId = 0 :: number
	local HitDynamicObject: any = nil
	local BestNormalX: number, BestNormalY: number, BestNormalZ: number = 0, 1, 0

	if BVHState.AllocatedNodeBytes > 0 then
		const RootHit, _ = BVHMath.TestNodeAABB(
			NodeBuffer, 0, OriginX, OriginY, OriginZ, InverseDirectionX, InverseDirectionY, InverseDirectionZ, ClosestDistance
		)
		if RootHit then
			local StackTop = 1 :: number
			buffer.writeu32(TraversalStackBuffer, 0, 0)

			while StackTop > 0 do
				StackTop -= 1
				const NodeOffset = buffer.readu32(TraversalStackBuffer, StackTop * 4) :: number
				const RightOffset = buffer.readu32(NodeBuffer, NodeOffset + 28) :: number

				if RightOffset == 0 then
					const EntityId = buffer.readu32(NodeBuffer, NodeOffset + 12) :: number
					if EntityId < 1 or EntityId > EntityCount then
						continue
					end

					buffer.writeu32(TestedGenBuffer, EntityId * 4, CurrentRayGen)
					const Hit, HitDistance, NormalX, NormalY, NormalZ = BVHMath.TestEntityOBB(
						EntityId, OriginX, OriginY, OriginZ, DirectionX, DirectionY, DirectionZ, ClosestDistance,
						PositionBuffer, SizeBuffer, DirectionsBuffer, PropertiesBuffer
					)
					if Hit then
						ClosestDistance, HitEntityId, HitDynamicObject = HitDistance, EntityId, nil
						BestNormalX, BestNormalY, BestNormalZ = NormalX, NormalY, NormalZ
					end
				else
					const LeftOffset = buffer.readu32(NodeBuffer, NodeOffset + 12) :: number
					const HitLeft, DistanceLeft = BVHMath.TestNodeAABB(
						NodeBuffer, LeftOffset, OriginX, OriginY, OriginZ, InverseDirectionX, InverseDirectionY, InverseDirectionZ, ClosestDistance
					)
					const HitRight, DistanceRight = BVHMath.TestNodeAABB(
						NodeBuffer, RightOffset, OriginX, OriginY, OriginZ, InverseDirectionX, InverseDirectionY, InverseDirectionZ, ClosestDistance
					)
					if HitLeft and HitRight and StackTop + 2 <= STACK_CAPACITY then
						if DistanceLeft < DistanceRight then
							buffer.writeu32(TraversalStackBuffer, StackTop * 4, RightOffset)
							buffer.writeu32(TraversalStackBuffer, (StackTop + 1) * 4, LeftOffset)
						else
							buffer.writeu32(TraversalStackBuffer, StackTop * 4, LeftOffset)
							buffer.writeu32(TraversalStackBuffer, (StackTop + 1) * 4, RightOffset)
						end
						StackTop += 2
					elseif HitLeft and StackTop < STACK_CAPACITY then
						buffer.writeu32(TraversalStackBuffer, StackTop * 4, LeftOffset)
						StackTop += 1
					elseif HitRight and StackTop < STACK_CAPACITY then
						buffer.writeu32(TraversalStackBuffer, StackTop * 4, RightOffset)
						StackTop += 1
					end
				end
			end
		end
	end

	for i = 0, BVHState.DynamicEntityCount - 1 do
		const EntityId = buffer.readu32(DynamicEntitiesBuffer, i * 4) :: number
		if EntityId < 1 or EntityId > EntityCount or buffer.readu32(TestedGenBuffer, EntityId * 4) == CurrentRayGen then
			continue
		end

		buffer.writeu32(TestedGenBuffer, EntityId * 4, CurrentRayGen)
		const Hit, HitDistance, NormalX, NormalY, NormalZ = BVHMath.TestEntityOBB(
			EntityId, OriginX, OriginY, OriginZ, DirectionX, DirectionY, DirectionZ, ClosestDistance,
			PositionBuffer, SizeBuffer, DirectionsBuffer, PropertiesBuffer
		)
		if Hit then
			ClosestDistance, HitEntityId, HitDynamicObject = HitDistance, EntityId, nil
			BestNormalX, BestNormalY, BestNormalZ = NormalX, NormalY, NormalZ
		end
	end

	ClosestDistance, HitEntityId, HitDynamicObject, BestNormalX, BestNormalY, BestNormalZ = BVHDynamicSweep.SweepDynamicRegistry(
		DynamicObjectsList, EntityCount, CurrentRayGen, OriginX, OriginY, OriginZ, DirectionX, DirectionY, DirectionZ,
		ClosestDistance, HitEntityId, HitDynamicObject, BestNormalX, BestNormalY, BestNormalZ,
		PositionBuffer, SizeBuffer, DirectionsBuffer, PropertiesBuffer
	)

	if HitEntityId == 0 and HitDynamicObject == nil then
		return nil, nil, ResolvedMaxDistance, nil, nil
	end

	if HitDynamicObject == nil and HitEntityId > 0 and DynamicObjectsList then
		const PropRegister = buffer.readu32(PropertiesBuffer, (HitEntityId - 1) * PROPERTIES_STRIDE) :: number
		if bit32.btest(PropRegister, FLAG_HAS_DYNAMIC_ID) then
			HitDynamicObject = DynamicObjectsList.ObjectsTable[bit32.rshift(PropRegister, DYNAMIC_ID_SHIFT)]
		end
	end

	const HitPosition = Vector3.new(OriginX + DirectionX * ClosestDistance, OriginY + DirectionY * ClosestDistance, OriginZ + DirectionZ * ClosestDistance)
	return if HitEntityId > 0 then HitEntityId else nil, HitDynamicObject, ClosestDistance, HitPosition, Vector3.new(BestNormalX, BestNormalY, BestNormalZ)
end

return BVHRaycast
