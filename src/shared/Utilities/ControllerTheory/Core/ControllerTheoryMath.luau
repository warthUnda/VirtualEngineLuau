--!strict
--!native
--!optimize 2

--[=[
	@class ControllerTheoryMath
	Pure control-theory equations computing non-managed frame overhead, mandatory 2ms spike
	headroom reservation, normalized weighted budgets, internal plant-model equilibrium targets,
	and exponential-backoff ceiling locks to eliminate adaptation limit-cycle hunting.
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
const DEFAULT_FREE_RESERVE = SystemsConfigs.ControllerFreeTimeReserve :: number
const DOWN_GAIN = SystemsConfigs.ControllerDownGain :: number
const UP_GAIN = SystemsConfigs.ControllerUpGain :: number
const DERIVATIVE_GAIN = SystemsConfigs.ControllerDerivativeGain :: number
const ERROR_DEADBAND = SystemsConfigs.ControllerErrorDeadband :: number
const UPSCALE_DEADBAND = SystemsConfigs.ControllerUpscaleHeadroomDeadband :: number
const MAX_DROP_PER_FRAME = SystemsConfigs.ControllerMaxDropPerFrame :: number
const MAX_RISE_PER_FRAME = SystemsConfigs.ControllerMaxRisePerFrame :: number
const EQUILIBRIUM_BUDGET_RATIO = SystemsConfigs.ControllerEquilibriumBudgetRatio :: number
const BASE_HOLD_FRAMES = SystemsConfigs.ControllerBaseCeilingHoldFrames :: number
const MAX_HOLD_FRAMES = SystemsConfigs.ControllerMaxCeilingHoldFrames :: number
const CEILING_PROBE_STEP = SystemsConfigs.ControllerCeilingProbeStep :: number
const CEILING_UNLOCK_RATIO = SystemsConfigs.ControllerCeilingUnlockRatio :: number
const MIN_RES_SCALE = SystemsConfigs.ControllerMinResolutionScale :: number
const MIN_AREA_FRACTION = MIN_RES_SCALE * MIN_RES_SCALE :: number
const MIN_PHYSICS_DUTY = SystemsConfigs.ControllerMinPhysicsDutyPercent :: number

export type ChannelState = {
	IsPhysics: boolean,
	RawScore: number,
	Score: number,
	PreviousError: number,
	CeilingScore: number,
	CeilingUnitCost: number,
	StableFrames: number,
	HoldTargetFrames: number,
	ProbingCeiling: boolean,
}

-- Tables --
local ControllerTheoryMath = {}

-- Functions --
-- ============================================================================
-- 1. PLANT LOAD MODEL, 2MS SPIKE RESERVE BUDGETS & ANTI-HUNTING CHANNEL STEP
-- ============================================================================

--[=[
	Computes the active work fraction in (0, 1] corresponding to a subsystem's 1..100 score.
	@param RawScore number -- Continuous subsystem score in [1, 100].
	@param IsPhysics boolean -- True for physics duty fraction; false for renderer pixel area fraction.
	@return number -- Active plant load fraction in (0, 1].
]=]
function ControllerTheoryMath.GetResourceLoadFraction(RawScore: number, IsPhysics: boolean): number
	const Clamped = math.clamp(RawScore, MIN_SCORE, MAX_SCORE) :: number
	if IsPhysics then
		return math.clamp(Clamped, MIN_PHYSICS_DUTY, 100) * 0.01
	end
	const Unit = (Clamped - MIN_SCORE) / (MAX_SCORE - MIN_SCORE) :: number
	return MIN_AREA_FRACTION + (1 - MIN_AREA_FRACTION) * Unit
end

--[=[
	Inverts an active work fraction back into the corresponding continuous 1..100 resource score.
	@param LoadFraction number -- Target plant load fraction.
	@param IsPhysics boolean -- True for physics duty fraction; false for renderer pixel area fraction.
	@return number -- Continuous resource score in [1, 100].
]=]
function ControllerTheoryMath.ScoreFromLoadFraction(LoadFraction: number, IsPhysics: boolean): number
	if IsPhysics then
		return math.clamp(LoadFraction * 100, MIN_SCORE, MAX_SCORE)
	end
	const ClampedArea = math.clamp(LoadFraction, MIN_AREA_FRACTION, 1.0) :: number
	const Unit = (ClampedArea - MIN_AREA_FRACTION) / (1 - MIN_AREA_FRACTION) :: number
	return MIN_SCORE + (MAX_SCORE - MIN_SCORE) * Unit
end

--[=[
	Calculates non-managed ("other systems") frame time, reserves mandatory untouched spike
	free time (default 2ms), computes (OtherSystemsFrameTime - UsableTargetTime), and divides
	remaining usable frame time across normalized Renderer and Physics weights.
	@param TotalFrameTime number -- Observed total frame duration in seconds.
	@param PhysicsFrameTime number -- Measured physics execution time in seconds.
	@param RendererFrameTime number -- Measured renderer execution time in seconds.
	@param WhereInFrame number -- Current elapsed time inside the active frame in seconds.
	@param TargetFrameTime number -- Desired frame duration in seconds (1 / 60).
	@param RendererWeight number -- Runtime weight for renderer.
	@param PhysicsWeight number -- Runtime weight for physics.
	@param FreeTimeReserve number? -- Optional unused spike-headroom reserve in seconds (defaults to 2ms).
	@return (number, number, number, number) -- (OtherSystemsTime, OtherMinusTarget, RendererBudget, PhysicsBudget).
]=]
function ControllerTheoryMath.ComputeBudgetAllocation(
	TotalFrameTime: number,
	PhysicsFrameTime: number,
	RendererFrameTime: number,
	WhereInFrame: number,
	TargetFrameTime: number,
	RendererWeight: number,
	PhysicsWeight: number,
	FreeTimeReserve: number?
): (number, number, number, number)
	const SafeTotal = math.max(0, TotalFrameTime) :: number
	const SafePhysics = math.max(0, PhysicsFrameTime) :: number
	const SafeRenderer = math.max(0, RendererFrameTime) :: number
	const SafeWhere = math.max(0, WhereInFrame) :: number
	const SafeReserve = math.max(0, (FreeTimeReserve or DEFAULT_FREE_RESERVE) :: number) :: number
	const UsableTargetTime = math.max(1e-4, TargetFrameTime - SafeReserve) :: number
	const ManagedSum = SafePhysics + SafeRenderer :: number

	const EffectiveFrameSpan = math.max(SafeTotal, SafeWhere) :: number
	const OtherSystemsTime = math.max(0, EffectiveFrameSpan - ManagedSum) :: number
	const OtherMinusTarget = OtherSystemsTime - UsableTargetTime :: number
	const AvailableManagedBudget = -OtherMinusTarget :: number

	const ClampedR = math.max(0, RendererWeight) :: number
	const ClampedP = math.max(0, PhysicsWeight) :: number
	const WeightSum = ClampedR + ClampedP :: number
	const NormRenderer = if WeightSum > 1e-6 then ClampedR / WeightSum else 0.60 :: number
	const NormPhysics = if WeightSum > 1e-6 then ClampedP / WeightSum else 0.40 :: number

	const BaseRendererBudget = NormRenderer * AvailableManagedBudget :: number
	const BasePhysicsBudget = NormPhysics * AvailableManagedBudget :: number

	const PhysicsSlack = math.max(0, BasePhysicsBudget - SafePhysics) :: number
	const RendererSlack = math.max(0, BaseRendererBudget - SafeRenderer) :: number
	const EffectiveRendererBudget = BaseRendererBudget + PhysicsSlack :: number
	const EffectivePhysicsBudget = BasePhysicsBudget + RendererSlack :: number

	return OtherSystemsTime, OtherMinusTarget, EffectiveRendererBudget, EffectivePhysicsBudget
end

--[=[
	Steps a subsystem ChannelState in place using internal plant-cost estimation (preventing
	overshoot past the steady-state equilibrium score) plus an exponential-backoff safe ceiling
	lock so scores never hunt back into lag after adapting.
	@param Channel ChannelState -- Pre-allocated mutable channel state record.
	@param AllocatedBudget number -- Subsystem's effective frame-time budget in seconds.
	@param MeasuredTime number -- Subsystem's measured frame-time feedback in seconds.
	@param TargetFrameTime number -- Target total frame duration (1 / 60).
]=]
function ControllerTheoryMath.StepChannel(
	Channel: ChannelState,
	AllocatedBudget: number,
	MeasuredTime: number,
	TargetFrameTime: number
)
	const SafeTarget = math.max(1e-5, TargetFrameTime) :: number
	const SafeMeasured = math.max(0, MeasuredTime) :: number
	const LoadFraction = ControllerTheoryMath.GetResourceLoadFraction(Channel.RawScore, Channel.IsPhysics) :: number
	const UnitCost = SafeMeasured / math.max(0.05, LoadFraction) :: number
	const NormalizedError = (AllocatedBudget - SafeMeasured) / SafeTarget :: number

	-- Release post-overrun ceiling immediately when per-unit scene cost genuinely drops by >= 35%
	if
		Channel.CeilingScore < MAX_SCORE
		and Channel.CeilingUnitCost > 0
		and UnitCost <= Channel.CeilingUnitCost * CEILING_UNLOCK_RATIO
	then
		Channel.CeilingScore = MAX_SCORE
		Channel.HoldTargetFrames = BASE_HOLD_FRAMES
		Channel.ProbingCeiling = false
	end

	if NormalizedError < -ERROR_DEADBAND then
		const ErrorDrop = math.min(0, NormalizedError - Channel.PreviousError) :: number
		const RawDown = DOWN_GAIN * NormalizedError + DERIVATIVE_GAIN * ErrorDrop :: number
		const Delta = math.clamp(RawDown, -MAX_DROP_PER_FRAME, -0.005) :: number
		const NextRaw = math.clamp(Channel.RawScore + Delta, MIN_SCORE, MAX_SCORE) :: number

		Channel.RawScore = NextRaw
		Channel.CeilingScore = math.clamp(math.min(Channel.CeilingScore, NextRaw), MIN_SCORE, MAX_SCORE)
		Channel.CeilingUnitCost = if Channel.ProbingCeiling then math.max(Channel.CeilingUnitCost, UnitCost) else UnitCost
		if Channel.ProbingCeiling then
			Channel.HoldTargetFrames = math.min(MAX_HOLD_FRAMES, Channel.HoldTargetFrames * 2)
		end
		Channel.ProbingCeiling = false
		Channel.StableFrames = 0
	else
		Channel.StableFrames += 1
		const TargetLoadFraction = if UnitCost > 1e-6 and AllocatedBudget > 0
			then (AllocatedBudget * EQUILIBRIUM_BUDGET_RATIO) / UnitCost
			else 1.0 :: number
		const EquilibriumScore = if UnitCost > 1e-6 and AllocatedBudget > 0
			then ControllerTheoryMath.ScoreFromLoadFraction(TargetLoadFraction, Channel.IsPhysics)
			else MAX_SCORE :: number

		if Channel.CeilingScore < MAX_SCORE and Channel.StableFrames >= Channel.HoldTargetFrames then
			Channel.CeilingScore = math.min(MAX_SCORE, Channel.CeilingScore + CEILING_PROBE_STEP)
			Channel.StableFrames = 0
			Channel.ProbingCeiling = true
		end

		const EffectiveCap = math.min(MAX_SCORE, EquilibriumScore, Channel.CeilingScore) :: number
		if NormalizedError > UPSCALE_DEADBAND and Channel.RawScore < EffectiveCap then
			const ErrorRise = math.max(0, NormalizedError - Channel.PreviousError) :: number
			const RawUp = UP_GAIN * NormalizedError + DERIVATIVE_GAIN * ErrorRise :: number
			const RiseStep = math.clamp(RawUp, 0.0005, MAX_RISE_PER_FRAME) :: number
			Channel.RawScore = math.min(EffectiveCap, Channel.RawScore + RiseStep)
		end
	end

	Channel.PreviousError = NormalizedError
	Channel.Score = math.clamp(math.floor(Channel.RawScore + 0.5), MIN_SCORE, MAX_SCORE)
end

return ControllerTheoryMath
