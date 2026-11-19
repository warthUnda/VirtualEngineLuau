--!strict
--!native
--!optimize 2

--[=[
	@class ControllerTheory
	Public subsystem facade exposing the singleton ResourceController, ControllerTheoryMath,
	and system ControllerReps (PhysicsRep, RenderingRep) for Server and Client environments.
]=]

-- Static References --
const CoreFolder = script:WaitForChild("Core")
const ControllerFolder = script:WaitForChild("Controller")
const ControllerRepsFolder = script:WaitForChild("ControllerReps")

-- Libraries --
const ControllerTheoryMath = require(CoreFolder:WaitForChild("ControllerTheoryMath"))
const ResourceController = require(ControllerFolder:WaitForChild("ResourceController"))
const PhysicsRep = require(ControllerRepsFolder:WaitForChild("PhysicsRep"))
const RenderingRep = require(ControllerRepsFolder:WaitForChild("RenderingRep"))

-- Tables --
local ControllerTheory = {
	State = ResourceController.State,
	ResourceController = ResourceController,
	ControllerTheoryMath = ControllerTheoryMath,
	PhysicsRep = PhysicsRep,
	RenderingRep = RenderingRep,
	ControllerReps = {
		PhysicsRep = PhysicsRep,
		RenderingRep = RenderingRep,
	},
	Initialize = ResourceController.Initialize,
	IsEnabled = ResourceController.IsEnabled,
	SetEnabled = ResourceController.SetEnabled,
	BeginFrame = ResourceController.BeginFrame,
	EndFrame = ResourceController.EndFrame,
	StepController = ResourceController.StepController,
	UpdateWhereInFrame = ResourceController.UpdateWhereInFrame,
	SetWeights = ResourceController.SetWeights,
	Reset = ResourceController.Reset,
}

return ControllerTheory
