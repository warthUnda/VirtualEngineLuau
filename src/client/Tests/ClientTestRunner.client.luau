--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")

-- Static References --
const LocalPlayer = Players.LocalPlayer :: Player
const PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts")
const TestsFolder = PlayerScripts:WaitForChild("Client"):WaitForChild("Tests")
const SpecsFolder = TestsFolder:WaitForChild("Specs")

-- Modules --
const TestHarness = require(script.Parent:WaitForChild("TestHarness"))

-- ============================================================================
-- 1. CLIENT MASTER TEST SUITE RUNNER
-- ============================================================================

task.spawn(function()
	task.wait(1.5) -- Allow client setup and controller actors to initialize

	print("\n========================================================")
	print("       ANTIGRAVITY CLIENT TEST SUITE RUNNER             ")
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
	print(string.format(" [Client] TOTAL SUITES RUN: %d", #SpecInstances))
	print(string.format(" [Client] PASSED TESTS:    %d", TotalPassed))
	print(string.format(" [Client] FAILED TESTS:    %d", TotalFailed))
	print(string.format(" [Client] TIME ELAPSED:    %.2f ms", TotalDurationMs))
	print("========================================================\n")

	if TotalFailed > 0 then
		warn(string.format("[ClientTestRunner] %d test(s) failed in client suite!", TotalFailed))
	else
		print("[ClientTestRunner] All client test suites completed successfully!")
	end
end)
