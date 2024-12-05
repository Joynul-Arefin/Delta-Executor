local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Midori = require(ReplicatedStorage.DevPackages.Midori)

Midori.runTests(ReplicatedStorage.Packages.Lapis, {
	timeoutWarningDelay = 3,
	concurrent = true,
})
