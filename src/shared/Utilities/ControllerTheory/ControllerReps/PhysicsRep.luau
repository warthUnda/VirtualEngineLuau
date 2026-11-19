--!strict
--!native
--!optimize 2

--[=[
	@class PhysicsRep
	System representative for Physics inside ControllerTheory.
	Owns Physics score/feedback binding, plant load-curve mapping, and deterministic
	Bresenham part striding & duty-cycle interpretation (zero math.random).
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const ControllerTheoryRoot = script.Parent.Parent

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ControllerTheoryMath = require(ControllerTheoryRoot:WaitForChild("Core"):WaitForChild("ControllerTheoryMath"))
const ResourceController = require(ControllerTheoryRoot:WaitForChild("Controller"):WaitForChild("ResourceController"))

-- Configs --
const CHANNEL_NAME = "Physics" :: string
const MIN_SCORE = SystemsConfigs.ControllerMinScore :: number
const MAX_SCORE = SystemsConfigs.ControllerMaxScore :: number
const MIN_PHYSICS_DUTY = SystemsConfigs.ControllerMinPhysicsDutyPercent :: number
const MAX_PHYSICS_DT_SCALE = SystemsConfigs.ControllerMaxPhysicsDtScale :: number
const COPRIME_PHASE_STRIDE = 51 :: number

-- Tables --
local PhysicsRep = {}

-- Functions --
-- ============================================================================
-- 1. PHYSICS CHANNEL CURVES, CONTROLLER FEEDBACK & DETERMINISTIC INTERPRETER
-- ============================================================================

--[=[
	Maps a 1..100 Physics score to its active plant duty fraction in [MIN_PHYSICS_DUTY/100, 1.0].
	@param RawScore number -- Continuous Physics score in [1, 100].
	@return number -- Active Physics load fraction in (0, 1].
]=]
function PhysicsRep.GetLoadFraction(RawScore: number): number
	const Clamped = math.clamp(RawScore, MIN_SCORE, MAX_SCORE) :: number
	return math.clamp(Clamped, MIN_PHYSICS_DUTY, 100) * 0.01
end

--[=[
	Inverts a target Physics duty fraction back into a continuous 1..100 Physics score.
	@param LoadFraction number -- Target Physics duty fraction.
	@return number -- Continuous Physics score in [1, 100].
]=]
function PhysicsRep.ScoreFromLoadFraction(LoadFraction: number): number
	return math.clamp(LoadFraction * 100, MIN_SCORE, MAX_SCORE)
end

--[=[
	Returns the current 1..100 ControllerTheory allocation score for Physics.
	@return number -- Integer score in [1, 100].
]=]
function PhysicsRep.GetScore(): number
	return ResourceController.GetChannelScore(CHANNEL_NAME)
end

--[=[
	Returns the current normalized runtime weight assigned to the Physics channel.
	@return number -- Runtime Physics weight in [0, 1].
]=]
function PhysicsRep.GetWeight(): number
	return ResourceController.State.Weights.Physics
end

--[=[
	Reports measured physics frame execution duration back into ResourceController.
	@param ElapsedSeconds number -- Measured physics frame duration in seconds.
]=]
function PhysicsRep.ReportFeedback(ElapsedSeconds: number)
	ResourceController.ReportChannelFeedback(CHANNEL_NAME, ElapsedSeconds)
end

--[=[
	Converts the current (or overridden) 1..100 physics score into a deterministic per-frame
	active duty percentage, effective frame stride, and clamped delta-time compensation scale.
	@param ScoreOverride number? -- Optional explicit 1..100 score (defaults to PhysicsRep.GetScore()).
	@return (number, number, number) -- (ActiveDutyPercent, EffectiveFrameStride, DtCompensationScale).
]=]
function PhysicsRep.Interpret(ScoreOverride: number?): (number, number, number)
	const ActiveScore = if ScoreOverride ~= nil then ScoreOverride else ResourceController.GetChannelScore(CHANNEL_NAME) :: number
	const ClampedScore = ControllerTheoryMath.ClampScore(ActiveScore) :: number
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
	@param ScoreOverride number? -- Optional explicit score/duty percentage (defaults to PhysicsRep.GetScore()).
	@return boolean -- True if the entity should simulate on this frame.
]=]
function PhysicsRep.ShouldStepEntity(
	EntityId: number,
	FrameTick: number,
	ScoreOverride: number?
): boolean
	const TargetScore = if ScoreOverride ~= nil then ScoreOverride else ResourceController.GetChannelScore(CHANNEL_NAME) :: number
	const DutyPercent = math.clamp(math.floor(TargetScore + 0.5), MIN_PHYSICS_DUTY, 100) :: number
	if DutyPercent >= 100 then
		return true
	end

	const SafeEntityIndex = if EntityId >= 1 then EntityId - 1 else 0 :: number
	const SafeTick = if FrameTick >= 0 then FrameTick else 0 :: number
	const EntityPhase = (SafeEntityIndex * COPRIME_PHASE_STRIDE) % 100 :: number
	return ((SafeTick * DutyPercent + EntityPhase) % 100) < DutyPercent
end

ResourceController.BindChannelCurves(CHANNEL_NAME, PhysicsRep.GetLoadFraction, PhysicsRep.ScoreFromLoadFraction)

return PhysicsRep
