--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const BVHModule = script.Parent :: Instance
const SpecModule = BVHModule:WaitForChild("BVH.spec") :: ModuleScript
const DevPackages = ReplicatedStorage:FindFirstChild("DevPackages")

-- ============================================================================
-- 1. RUN WITH OFFICIAL TESTEZ (IF PRESENT) OR BUILT-IN TESTEZ RUNNER
-- ============================================================================

if DevPackages and DevPackages:FindFirstChild("TestEZ") then
	const TestEZ = require(DevPackages.TestEZ) :: any
	TestEZ.TestBootstrap:run({ BVHModule })
	return
end

const SpecFn = require(SpecModule) :: () -> ()

local PassedCount = 0 :: number
local FailedCount = 0 :: number
local IndentLevel = 0 :: number
local OutputLines = { "Test results:" } :: { string }

local function CreateExpect(ActualValue: any)
	local Inverted = false :: boolean

	local Matcher = {}
	Matcher.to = Matcher

	local BuiltinNever = {}
	Matcher.never = BuiltinNever

	local function EvaluateEqual(ExpectedValue: any)
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
				2
			)
		end
	end

	local function EvaluateBeOk()
		const IsOk = (ActualValue ~= nil) :: boolean
		const Success = if Inverted then not IsOk else IsOk
		if not Success then
			error(string.format("Expected value to %sbe non-nil", if Inverted then "not " else ""), 2)
		end
	end

	function Matcher.equal(ExpectedValue: any)
		EvaluateEqual(ExpectedValue)
	end

	function Matcher.be(ExpectedValue: any)
		EvaluateEqual(ExpectedValue)
	end

	function Matcher.ok()
		EvaluateBeOk()
	end

	BuiltinNever.to = {
		equal = function(ExpectedValue: any)
			Inverted = true
			EvaluateEqual(ExpectedValue)
		end,
		be = function(ExpectedValue: any)
			Inverted = true
			EvaluateEqual(ExpectedValue)
		end,
		ok = function()
			Inverted = true
			EvaluateBeOk()
		end,
	}
	BuiltinNever.equal = BuiltinNever.to.equal
	BuiltinNever.be = BuiltinNever.to.be
	BuiltinNever.ok = BuiltinNever.to.ok

	return Matcher
end

local Env = getfenv(SpecFn)
Env.describe = function(Phrase: string, Callback: () -> ())
	const Prefix = string.rep("   ", IndentLevel)
	table.insert(OutputLines, string.format("%s[+] %s", Prefix, Phrase))
	IndentLevel += 1
	Callback()
	IndentLevel -= 1
end

Env.it = function(Phrase: string, Callback: () -> ())
	const Prefix = string.rep("   ", IndentLevel)
	const Ok, Err = pcall(Callback)
	if Ok then
		PassedCount += 1
		table.insert(OutputLines, string.format("%s[+] %s", Prefix, Phrase))
	else
		FailedCount += 1
		table.insert(OutputLines, string.format("%s[-] %s", Prefix, Phrase))
		table.insert(OutputLines, string.format("%s      %s", Prefix, tostring(Err)))
	end
end

Env.expect = CreateExpect
setfenv(SpecFn, Env)

SpecFn()

table.insert(
	OutputLines,
	string.format("%d passed, %d failed, 0 skipped", PassedCount, FailedCount)
)

print(table.concat(OutputLines, "\n"))
if FailedCount > 0 then
	warn(string.format("[BVH TestEZ] %d test(s) failed!", FailedCount))
end
