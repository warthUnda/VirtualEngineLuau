--!strict
--!native
--!optimize 2

-- Libraries --
const BVHMath = require(script.Parent.BVHMath)
const BVHState = require(script.Parent.BVHState)

-- Tables --
local BVHDynamicSweep = {}

-- Functions --
-- ============================================================================
-- 1. DYNAMIC OBJECTS REGISTRY RAYCAST SWEEP
-- ============================================================================

--[=[
	Sweeps registered DynamicObjectsList entries (both ECS-bound and pure OOP instances) against a ray.
	@param DynamicObjectsList any -- Active dynamic objects registry.
	@param EntityCount number -- Active ECS entity count.
	@param CurrentRayGen number -- Generation stamp preventing duplicate entity OBB tests.
	@param OriginX number -- Ray origin X.
	@param OriginY number -- Ray origin Y.
	@param OriginZ number -- Ray origin Z.
	@param DirectionX number -- Unit ray direction X.
	@param DirectionY number -- Unit ray direction Y.
	@param DirectionZ number -- Unit ray direction Z.
	@param ClosestDistance number -- Current closest hit distance.
	@param HitEntityId number -- Current closest hit entity ID.
	@param HitDynamicObject any -- Current closest hit dynamic object.
	@param BestNormalX number -- Current closest hit normal X.
	@param BestNormalY number -- Current closest hit normal Y.
	@param BestNormalZ number -- Current closest hit normal Z.
	@param PositionBuffer buffer -- ECS Position buffer.
	@param SizeBuffer buffer -- ECS Size buffer.
	@param DirectionsBuffer buffer -- ECS Directions buffer.
	@param PropertiesBuffer buffer -- ECS Properties buffer.
	@return (number, number, any, number, number, number) -- Updated ClosestDistance, HitEntityId, HitDynamicObject, NormalX, NormalY, NormalZ.
]=]
function BVHDynamicSweep.SweepDynamicRegistry(
	DynamicObjectsList: any,
	EntityCount: number,
	CurrentRayGen: number,
	OriginX: number,
	OriginY: number,
	OriginZ: number,
	DirectionX: number,
	DirectionY: number,
	DirectionZ: number,
	ClosestDistance: number,
	HitEntityId: number,
	HitDynamicObject: any,
	BestNormalX: number,
	BestNormalY: number,
	BestNormalZ: number,
	PositionBuffer: buffer,
	SizeBuffer: buffer,
	DirectionsBuffer: buffer,
	PropertiesBuffer: buffer
): (number, number, any, number, number, number)
	if not DynamicObjectsList or DynamicObjectsList.Counts.ActiveCount <= 0 then
		return ClosestDistance, HitEntityId, HitDynamicObject, BestNormalX, BestNormalY, BestNormalZ
	end

	const TestedGenBuffer = BVHState.TestedGenBuffer
	const ObjectsTable = DynamicObjectsList.ObjectsTable
	for DynId = 1, DynamicObjectsList.Counts.NextId do
		const DynObject = ObjectsTable[DynId]
		if DynObject == nil then
			continue
		end

		const BoundEntityId = DynamicObjectsList.GetBoundEntityId(DynId) :: number
		if BoundEntityId > 0 and BoundEntityId <= EntityCount then
			if buffer.readu32(TestedGenBuffer, BoundEntityId * 4) == CurrentRayGen then
				continue
			end

			buffer.writeu32(TestedGenBuffer, BoundEntityId * 4, CurrentRayGen)
			const Hit, HitDistance, NormalX, NormalY, NormalZ = BVHMath.TestEntityOBB(
				BoundEntityId,
				OriginX,
				OriginY,
				OriginZ,
				DirectionX,
				DirectionY,
				DirectionZ,
				ClosestDistance,
				PositionBuffer,
				SizeBuffer,
				DirectionsBuffer,
				PropertiesBuffer
			)
			if Hit then
				ClosestDistance, HitEntityId, HitDynamicObject = HitDistance, BoundEntityId, DynObject
				BestNormalX, BestNormalY, BestNormalZ = NormalX, NormalY, NormalZ
			end
			continue
		end

		if type(DynObject) ~= "table" and typeof(DynObject) ~= "Instance" then
			continue
		end

		const AnyObj = DynObject :: any
		if type(DynObject) == "table" and AnyObj.CanCollide == false then
			continue
		end

		const ObjEntityId = if type(DynObject) == "table" and type(AnyObj.EntityId) == "number" then AnyObj.EntityId :: number else 0
		const ObjCFrame: CFrame? = AnyObj.CFrame
		const ObjPos: Vector3? = if typeof(ObjCFrame) == "CFrame" then ObjCFrame.Position else AnyObj.Position
		const ObjSize: Vector3? = AnyObj.Size
		if typeof(ObjPos) ~= "Vector3" or typeof(ObjSize) ~= "Vector3" then
			continue
		end

		local RightX: number, RightY: number, RightZ: number = 1, 0, 0
		local UpX: number, UpY: number, UpZ: number = 0, 1, 0
		local LookX: number, LookY: number, LookZ: number = 0, 0, -1
		if typeof(ObjCFrame) == "CFrame" then
			const Right: Vector3, Up: Vector3, Look: Vector3 = ObjCFrame.RightVector, ObjCFrame.UpVector, ObjCFrame.LookVector
			RightX, RightY, RightZ = Right.X, Right.Y, Right.Z
			UpX, UpY, UpZ = Up.X, Up.Y, Up.Z
			LookX, LookY, LookZ = Look.X, Look.Y, Look.Z
		end

		const Hit, HitDistance, NormalX, NormalY, NormalZ = BVHMath.TestBoxOBB(
			OriginX,
			OriginY,
			OriginZ,
			DirectionX,
			DirectionY,
			DirectionZ,
			ObjPos.X,
			ObjPos.Y,
			ObjPos.Z,
			math.abs(ObjSize.X) * 0.5,
			math.abs(ObjSize.Y) * 0.5,
			math.abs(ObjSize.Z) * 0.5,
			RightX,
			RightY,
			RightZ,
			UpX,
			UpY,
			UpZ,
			LookX,
			LookY,
			LookZ,
			ClosestDistance
		)
		if Hit then
			ClosestDistance, HitEntityId, HitDynamicObject = HitDistance, ObjEntityId, DynObject
			BestNormalX, BestNormalY, BestNormalZ = NormalX, NormalY, NormalZ
		end
	end

	return ClosestDistance, HitEntityId, HitDynamicObject, BestNormalX, BestNormalY, BestNormalZ
end

return BVHDynamicSweep
