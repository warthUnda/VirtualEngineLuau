--!strict
--!native
--!optimize 2

-- Services --
const ServerScriptService = game:GetService("ServerScriptService")

-- Static References --
const TestsFolder = ServerScriptService:WaitForChild("Server"):WaitForChild("Tests")
const SpecsFolder = TestsFolder:WaitForChild("Specs")

-- Modules --
const TestHarness = require(TestsFolder:WaitForChild("TestHarness"))

-- ============================================================================
-- 1. MASTER TEST SUITE RUNNER
-- ============================================================================

task.spawn(function()
	task.wait(1) -- Allow server environment and storage to settle

	print("\n========================================================")
	print("       ANTIGRAVITY ENGINE TEST SUITE RUNNER            ")
	print("========================================================\n")

	local TotalPassed = 0 :: number
	local TotalFailed = 0 :: number
	const OverallStartTime = os.clock()

	const SpecInstances = SpecsFolder:GetChildren() :: { Instance }
	table.sort(SpecInstances, function(A, B)
		return A.Name < B.Name
	end)

	for _, ChildInstance in ipairs(SpecInstances) do
		if ChildInstance:IsA("ModuleScript") and ChildInstance.Name:match("%.spec$") then
			const SuiteName = ChildInstance.Name:gsub("%.spec$", "")
			const Passed, Failed = TestHarness.RunSpec(SuiteName, ChildInstance)
			TotalPassed += Passed
			TotalFailed += Failed
		end
	end

	const TotalDurationMs = (os.clock() - OverallStartTime) * 1000

	print("\n========================================================")
	print(string.format(" TOTAL SUITES RUN: %d", #SpecInstances))
	print(string.format(" PASSED TESTS:    %d", TotalPassed))
	print(string.format(" FAILED TESTS:    %d", TotalFailed))
	print(string.format(" TIME ELAPSED:    %.2f ms", TotalDurationMs))
	print("========================================================\n")

	if TotalFailed > 0 then
		warn(string.format("[TestRunner] %d test(s) failed in the test suite!", TotalFailed))
	else
		print("[TestRunner] All test suites completed successfully!")
	end
end)
