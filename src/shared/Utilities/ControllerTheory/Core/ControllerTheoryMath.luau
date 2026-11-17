--!strict
--!native
--!optimize 2

--[=[
	@class ControllerTheoryMath
	Pure control-theory equations computing non-managed frame overhead, exact
	(OtherSystemsFrameTime - TargetFrameTime) budget offsets, work-conserving 60/40
	weighted subsystem budgets, and velocity-form PD/PI score updates.
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
const DOWN_GAIN = SystemsConfigs.ControllerDownGain :: number
const UP_GAIN = SystemsConfigs.ControllerUpGain :: number
const DERIVATIVE_GAIN = SystemsConfigs.ControllerDerivativeGain :: number
const ERROR_DEADBAND = SystemsConfigs.ControllerErrorDeadband :: number
const MAX_DROP_PER_FRAME = SystemsConfigs.ControllerMaxDropPerFrame :: number
const MAX_RISE_PER_FRAME = SystemsConfigs.ControllerMaxRisePerFrame :: number

-- Tables --
local ControllerTheoryMath = {}

-- Functions --
-- ============================================================================
-- 1. FRAME OVERHEAD RESIDUAL, 60/40 WEIGHTED BUDGETS & VELOCITY-FORM CONTROL
-- ============================================================================

--[=[
	Calculates non-managed ("other systems") frame time, its signed offset against the 60 FPS
	target (OtherSystemsFrameTime - TargetFrameTime), and work-conserving weighted budgets.
	@param TotalFrameTime number -- Observed total frame duration in seconds.
	@param PhysicsFrameTime number -- Measured physics execution time in seconds.
	@param RendererFrameTime number -- Measured renderer execution time in seconds.
	@param WhereInFrame number -- Current elapsed time inside the active frame in seconds.
	@param TargetFrameTime number -- Desired frame duration in seconds (1 / 60).
	@param RendererWeight number -- Runtime weight for renderer (0.60).
	@param PhysicsWeight number -- Runtime weight for physics (0.40).
	@return (number, number, number, number) -- (OtherSystemsTime, OtherMinusTarget, RendererBudget, PhysicsBudget).
]=]
function ControllerTheoryMath.ComputeBudgetAllocation(
	TotalFrameTime: number,
	PhysicsFrameTime: number,
	RendererFrameTime: number,
	WhereInFrame: number,
	TargetFrameTime: number,
	RendererWeight: number,
	PhysicsWeight: number
): (number, number, number, number)
	const SafeTotal = math.max(0, TotalFrameTime) :: number
	const SafePhysics = math.max(0, PhysicsFrameTime) :: number
	const SafeRenderer = math.max(0, RendererFrameTime) :: number
	const SafeWhere = math.max(0, WhereInFrame) :: number
	const ManagedSum = SafePhysics + SafeRenderer :: number

	-- Account for all frame time consumed outside Physics and Renderer (including live intra-frame spillover)
	const EffectiveFrameSpan = math.max(SafeTotal, SafeWhere) :: number
	const OtherSystemsTime = math.max(0, EffectiveFrameSpan - ManagedSum) :: number

	-- Signed offset: negative means available frame headroom; >= 0 means other systems alone exceeded 60 FPS
	const OtherMinusTarget = OtherSystemsTime - TargetFrameTime :: number
	const AvailableManagedBudget = -OtherMinusTarget :: number

	const BaseRendererBudget = RendererWeight * AvailableManagedBudget :: number
	const BasePhysicsBudget = PhysicsWeight * AvailableManagedBudget :: number

	-- Share unused slack when one subsystem is light while enforcing exact 60/40 split under dual contention
	const PhysicsSlack = math.max(0, BasePhysicsBudget - SafePhysics) :: number
	const RendererSlack = math.max(0, BaseRendererBudget - SafeRenderer) :: number
	const EffectiveRendererBudget = BaseRendererBudget + PhysicsSlack :: number
	const EffectivePhysicsBudget = BasePhysicsBudget + RendererSlack :: number

	return OtherSystemsTime, OtherMinusTarget, EffectiveRendererBudget, EffectivePhysicsBudget
end

--[=[
	Steps a single subsystem's continuous and integer 1..100 resource score using a velocity-form
	PI/PD feedback law with deadband stabilization and bumpless anti-windup clamping.
	@param CurrentRawScore number -- Continuous internal score in [1, 100].
	@param PreviousError number -- Previous frame's normalized budget error.
	@param AllocatedBudget number -- Subsystem's effective frame-time budget in seconds.
	@param MeasuredTime number -- Subsystem's measured frame-time feedback in seconds.
	@param TargetFrameTime number -- Target total frame duration (1 / 60).
	@return (number, number, number) -- (NextRawScore, IntegerScore, NormalizedError).
]=]
function ControllerTheoryMath.StepSystemScore(
	CurrentRawScore: number,
	PreviousError: number,
	AllocatedBudget: number,
	MeasuredTime: number,
	TargetFrameTime: number
): (number, number, number)
	const SafeTarget = math.max(1e-5, TargetFrameTime) :: number
	const NormalizedError = (AllocatedBudget - math.max(0, MeasuredTime)) / SafeTarget :: number

	if math.abs(NormalizedError) <= ERROR_DEADBAND then
		const SteadyInteger = math.clamp(math.floor(CurrentRawScore + 0.5), MIN_SCORE, MAX_SCORE) :: number
		return CurrentRawScore, SteadyInteger, NormalizedError
	end

	const ProportionalGain = if NormalizedError < 0 then DOWN_GAIN else UP_GAIN :: number
	const ErrorDerivative = NormalizedError - PreviousError :: number
	const RawStep = ProportionalGain * NormalizedError + DERIVATIVE_GAIN * ErrorDerivative :: number
	const ClampedStep = math.clamp(RawStep, -MAX_DROP_PER_FRAME, MAX_RISE_PER_FRAME) :: number

	const NextRawScore = math.clamp(CurrentRawScore + ClampedStep, MIN_SCORE, MAX_SCORE) :: number
	const IntegerScore = math.clamp(math.floor(NextRawScore + 0.5), MIN_SCORE, MAX_SCORE) :: number
	return NextRawScore, IntegerScore, NormalizedError
end

return ControllerTheoryMath
