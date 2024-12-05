local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Lapis = require(ReplicatedStorage.Packages.Lapis)
local Sift = require(ReplicatedStorage.Packages.Sift)
local t = require(ReplicatedStorage.Packages.t)

local DEFAULT_DATA = { coins = 100, recentPurchases = {} }
local RECENT_PURCHASES_LIMIT = 100
local PRODUCTS = {
	[12345] = function(oldData)
		-- Product callbacks return a new version of the data.
		return Sift.Dictionary.merge(oldData, {
			coins = oldData.coins + 100,
		})
	end,
}

local collection = Lapis.createCollection("PlayerData", {
	defaultData = DEFAULT_DATA,
	validate = t.strictInterface({ coins = t.integer, recentPurchases = t.array(t.string) }),
})

local documents = {}

local function onPlayerAdded(player: Player)
	collection
		:load(`Player{player.UserId}`, { player.UserId })
		:andThen(function(document)
			if player.Parent == nil then
				document:close():catch(warn)
				return
			end

			documents[player] = document
		end)
		:catch(function(message)
			warn(`Player {player.Name}'s data failed to load: {message}`)
			player:Kick("Data failed to load.")
		end)
end

local function onPlayerRemoving(player: Player)
	local document = documents[player]

	if document ~= nil then
		documents[player] = nil
		document:close():catch(warn)
	end
end

local function processReceipt(receiptInfo): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if player == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	while documents[player] == nil and player.Parent ~= nil do
		-- Wait until the document loads or the player leaves.
		task.wait()
	end

	local document = documents[player]
	if document == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local data = document:read()

	if table.find(data.recentPurchases, receiptInfo.PurchaseId) then
		-- The purchase has been added to the player's data, but it might not have saved yet.
		local saveOk = document:save():await()

		if saveOk then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		else
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
	end

	-- The product callback must not yield. Otherwise, it can return outdated data and overwrite new changes.
	local productOk, dataWithProduct = pcall(PRODUCTS[receiptInfo.ProductId], data)
	if not productOk then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local newRecentPurchases = Sift.Array.push(data.recentPurchases, receiptInfo.PurchaseId)
	if #newRecentPurchases > RECENT_PURCHASES_LIMIT then
		newRecentPurchases = Sift.Array.shift(newRecentPurchases, #newRecentPurchases - RECENT_PURCHASES_LIMIT)
	end

	document:write(Sift.Dictionary.merge(dataWithProduct, {
		recentPurchases = newRecentPurchases,
	}))

	local saveOk = document:save():await()
	if not saveOk then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- The ProcessReceipt callback must be set before the Players.PlayerAdded signal is fired, otherwise the player's
-- existing receipts won't be processed when they join.
MarketplaceService.ProcessReceipt = processReceipt

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end
