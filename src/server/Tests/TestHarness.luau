--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const DevPackages = ReplicatedStorage:FindFirstChild("DevPackages")

export type Expectation = {
	to: any,
	never: any,
}

local TestHarness = {}

-- ============================================================================
-- 1. ASSERTION & MATCHER IMPLEMENTATION
-- ============================================================================

function TestHarness.EvaluateEqual(ActualValue: any, ExpectedValue: any, Inverted: boolean)
	const IsMatch = (ActualValue == ExpectedValue) :: boolean
	const Success = if Inverted then not IsMatch else IsMatch
	if not Success then
		error(
			string.format(
				"Expected %s%s, got %s",
				if Inverted then "not " else "",
				tostring(ExpectedValue),
				tostring(ActualValue)
			),
			3
		)
	end
end

function TestHarness.EvaluateBeOk(ActualValue: any, Inverted: boolean)
	const IsOk = (ActualValue ~= nil and ActualValue ~= false) :: boolean
	const Success = if Inverted then not IsOk else IsOk
	if not Success then
		error(string.format("Expected value to %sbe truthy / non-nil", if Inverted then "not " else ""), 3)
	end
end

function TestHarness.EvaluateNear(ActualValue: any, ExpectedValue: any, Epsilon: number?, Inverted: boolean)
	const Tolerance = (Epsilon or 1e-4) :: number
	local Difference = 0 :: number
	if typeof(ActualValue) == "number" and typeof(ExpectedValue) == "number" then
		Difference = math.abs(ActualValue - ExpectedValue)
	elseif typeof(ActualValue) == "Vector3" and typeof(ExpectedValue) == "Vector3" then
		Difference = (ActualValue - ExpectedValue).Magnitude
	else
		error("expect.to.be.near requires numbers or Vector3 values", 3)
	end

	const IsNear = (Difference <= Tolerance) :: boolean
	const Success = if Inverted then not IsNear else IsNear
	if not Success then
		error(
			string.format(
				"Expected %sapproximately %s (within %s), difference was %s",
				if Inverted then "not " else "",
				tostring(ExpectedValue),
				tostring(Tolerance),
				tostring(Difference)
			),
			3
		)
	end
end

--[=[
	Creates a fluent expectation matcher object for test assertions.
	@param ActualValue any -- Value being verified.
	@return any -- Assertion matcher table supporting .to.equal, .to.be.ok, .to.be.near.
]=]
function TestHarness.CreateExpect(ActualValue: any): any
	local Matcher = {}
	Matcher.to = Matcher

	local BuiltinNever = {}
	Matcher.never = BuiltinNever

	function Matcher.equal(ExpectedValue: any)
		TestHarness.EvaluateEqual(ActualValue, ExpectedValue, false)
	end

	function Matcher.be(ExpectedValue: any)
		TestHarness.EvaluateEqual(ActualValue, ExpectedValue, false)
	end

	function Matcher.ok()
		TestHarness.EvaluateBeOk(ActualValue, false)
	end

	function Matcher.near(ExpectedValue: any, Epsilon: number?)
		TestHarness.EvaluateNear(ActualValue, ExpectedValue, Epsilon, false)
	end

	BuiltinNever.to = {
		equal = function(ExpectedValue: any)
			TestHarness.EvaluateEqual(ActualValue, ExpectedValue, true)
		end,
		be = function(ExpectedValue: any)
			TestHarness.EvaluateEqual(ActualValue, ExpectedValue, true)
		end,
		ok = function()
			TestHarness.EvaluateBeOk(ActualValue, true)
		end,
		near = function(ExpectedValue: any, Epsilon: number?)
			TestHarness.EvaluateNear(ActualValue, ExpectedValue, Epsilon, true)
		end,
	}

	BuiltinNever.equal = BuiltinNever.to.equal
	BuiltinNever.be = BuiltinNever.to.be
	BuiltinNever.ok = BuiltinNever.to.ok
	BuiltinNever.near = BuiltinNever.to.near

	return Matcher
end

-- ============================================================================
-- 2. SUITE EXECUTION & REPORTING
-- ============================================================================

--[=[
	Runs a single specification module function using either TestEZ or the built-in runner.
	@param SuiteName string -- Descriptive name of the test suite.
	@param SpecModule ModuleScript -- ModuleScript returning the spec function.
	@return (number, number) -- Passed count, Failed count.
]=]
function TestHarness.RunSpec(SuiteName: string, SpecModule: ModuleScript): (number, number)
	if DevPackages and DevPackages:FindFirstChild("TestEZ") then
		const TestEZ = (require :: any)(DevPackages:FindFirstChild("TestEZ"))
		print(string.format("[TestEZ] Running suite: %s", SuiteName))
		const Results = TestEZ.TestBootstrap:run({ SpecModule })
		if type(Results) == "table" then
			return (Results.successCount or 0) :: number, (Results.failureCount or 0) :: number
		end
		return 0, 0
	end

	const SpecFn = (require :: any)(SpecModule)
	if type(SpecFn) ~= "function" then
		warn(string.format("[TestHarness] Spec module %s did not return a function!", SuiteName))
		return 0, 1
	end

	local PassedCount = 0 :: number
	local FailedCount = 0 :: number
	local IndentLevel = 1 :: number
	local OutputLines = { string.format("--- Running Suite: %s ---", SuiteName) } :: { string }

	local Env = getfenv(SpecFn) :: { [string]: any }

	Env.describe = function(Phrase: string, Callback: () -> ())
		const Prefix = string.rep("  ", IndentLevel)
		table.insert(OutputLines, string.format("%s• %s", Prefix, Phrase))
		IndentLevel += 1
		Callback()
		IndentLevel -= 1
	end

	Env.it = function(Phrase: string, Callback: () -> ())
		const Prefix = string.rep("  ", IndentLevel)
		const Ok, Err = pcall(Callback :: any)
		if Ok then
			PassedCount += 1
			table.insert(OutputLines, string.format("%s  [PASS] %s", Prefix, Phrase))
		else
			FailedCount += 1
			table.insert(OutputLines, string.format("%s  [FAIL] %s", Prefix, Phrase))
			table.insert(OutputLines, string.format("%s         Error: %s", Prefix, tostring(Err)))
		end
	end

	Env.expect = TestHarness.CreateExpect
	setfenv(SpecFn, Env)

	const StartTime = os.clock()
	SpecFn()
	const DurationMs = (os.clock() - StartTime) * 1000

	table.insert(
		OutputLines,
		string.format(
			"[%s Results] %d passed, %d failed (%.2f ms)",
			SuiteName,
			PassedCount,
			FailedCount,
			DurationMs
		)
	)

	print(table.concat(OutputLines, "\n"))
	return PassedCount, FailedCount
end

return TestHarness
