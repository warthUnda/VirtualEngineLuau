--!strict
--!native
--!optimize 2

--[=[
	@class ControllerInterpreter
	Stateless mathematical interpreter converting 1..100 resource allocation scores from
	ResourceController into deterministic physics entity frame-striding (zero math.random)
	and area-proportional software renderer viewport resolutions.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))

-- Configs --
const MIN_SCORE = SystemsConfigs.ControllerMinScore :: number
const MAX_SCORE = SystemsConfigs.ControllerMaxScore :: number
const MIN_RES_SCALE = SystemsConfigs.ControllerMinResolutionScale :: number
const MIN_AREA_FRACTION = MIN_RES_SCALE * MIN_RES_SCALE :: number
const RES_STEP = math.max(1, SystemsConfigs.ControllerResolutionStep :: number) :: number
const MIN_VIEWPORT_DIM = SystemsConfigs.ControllerMinViewportDim :: number
const MIN_PHYSICS_DUTY = SystemsConfigs.ControllerMinPhysicsDutyPercent :: number
const MAX_PHYSICS_DT_SCALE = SystemsConfigs.ControllerMaxPhysicsDtScale :: number
const COPRIME_PHASE_STRIDE = 51 :: number

-- Tables --
local ControllerInterpreter = {}

-- Functions --
-- ============================================================================
-- 1. SCORE CLAMPING, DETERMINISTIC PHYSICS STRIDING & RENDERER RESOLUTION MATH
-- ============================================================================

--[=[
	Clamps and rounds an arbitrary numeric resource value into an integer score in [1, 100].
	@param Score number -- Raw resource score.
	@return number -- Clamped integer score in [1, 100].
]=]
function ControllerInterpreter.ClampScore(Score: number): number
	if Score ~= Score then
		return MAX_SCORE
	end
	return math.clamp(math.floor(Score + 0.5), MIN_SCORE, MAX_SCORE)
end

--[=[
	Converts a 1..100 physics resource score into a deterministic per-frame active duty percentage,
	effective frame stride (e.g., 1.0 = every frame, 2.0 = every 2 frames), and clamped dt scale.
	@param Score number -- Physics resource allocation score (1..100).
	@return (number, number, number) -- (ActiveDutyPercent, EffectiveFrameStride, DtCompensationScale).
]=]
function ControllerInterpreter.InterpretPhysics(Score: number): (number, number, number)
	const ClampedScore = ControllerInterpreter.ClampScore(Score) :: number
	const ActiveDutyPercent = math.clamp(ClampedScore, MIN_PHYSICS_DUTY, 100) :: number
	const EffectiveFrameStride = 100 / ActiveDutyPercent :: number
	const DtCompensationScale = math.min(MAX_PHYSICS_DT_SCALE, EffectiveFrameStride) :: number
	return ActiveDutyPercent, EffectiveFrameStride, DtCompensationScale
end

--[=[
	Deterministically decides whether a dynamic physics entity steps on the given frame tick
	using a coprime Bresenham modular accumulator (zero math.random). At score 100 every entity
	steps every frame; at score 50 every entity steps strictly every 2 frames with 50/50 phase split.
	@param EntityId number -- 1-based ECS EntityId.
	@param FrameTick number -- Monotonic physics frame counter.
	@param Score number -- Physics resource score (1..100) or duty percentage.
	@return boolean -- True if the entity should simulate on this frame.
]=]
function ControllerInterpreter.ShouldStepPhysicsEntity(
	EntityId: number,
	FrameTick: number,
	Score: number
): boolean
	const DutyPercent = math.clamp(math.floor(Score + 0.5), MIN_PHYSICS_DUTY, 100) :: number
	if DutyPercent >= 100 then
		return true
	end

	const SafeEntityIndex = if EntityId >= 1 then EntityId - 1 else 0 :: number
	const SafeTick = if FrameTick >= 0 then FrameTick else 0 :: number
	const EntityPhase = (SafeEntityIndex * COPRIME_PHASE_STRIDE) % 100 :: number
	return ((SafeTick * DutyPercent + EntityPhase) % 100) < DutyPercent
end

--[=[
	Converts a 1..100 renderer resource score into area-proportional scaled viewport dimensions
	so total rasterized pixel count scales linearly with the controller's score.
	@param Score number -- Renderer resource allocation score (1..100).
	@param BaseWidth number -- Native 100% viewport width in pixels.
	@param BaseHeight number -- Native 100% viewport height in pixels.
	@return (number, number, number) -- (ScaledWidth, ScaledHeight, LinearScale).
]=]
function ControllerInterpreter.InterpretRenderer(
	Score: number,
	BaseWidth: number,
	BaseHeight: number
): (number, number, number)
	const ClampedScore = math.clamp(math.floor(Score + 0.5), MIN_SCORE, MAX_SCORE) :: number
	if ClampedScore >= 100 then
		return BaseWidth, BaseHeight, 1.0
	end

	const NormalizedUnit = (ClampedScore - MIN_SCORE) / (MAX_SCORE - MIN_SCORE) :: number
	const AreaFraction = MIN_AREA_FRACTION + (1 - MIN_AREA_FRACTION) * NormalizedUnit :: number
	const LinearScale = math.sqrt(AreaFraction) :: number

	const FloorWidth = math.min(BaseWidth, MIN_VIEWPORT_DIM) :: number
	const FloorHeight = math.min(BaseHeight, MIN_VIEWPORT_DIM) :: number
	const QuantizedWidth = math.floor((BaseWidth * LinearScale) / RES_STEP + 0.5) * RES_STEP :: number
	const QuantizedHeight = math.floor((BaseHeight * LinearScale) / RES_STEP + 0.5) * RES_STEP :: number

	const ScaledWidth = math.clamp(QuantizedWidth, FloorWidth, BaseWidth) :: number
	const ScaledHeight = math.clamp(QuantizedHeight, FloorHeight, BaseHeight) :: number
	return ScaledWidth, ScaledHeight, LinearScale
end

return ControllerInterpreter
