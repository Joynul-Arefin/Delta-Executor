local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Midori = require(ReplicatedStorage.Packages.Midori)

Midori.runTests(script.Parent, {
	showTimeoutWarning = true,
	timeoutWarningDelay = 3,
	concurrent = true,
})
