local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)
local t = require(ReplicatedStorage.Packages.t)
local DataStoreServiceMock = require(ServerScriptService.ServerPackages.DataStoreServiceMock)
local LapisInternal = require(ReplicatedStorage.Packages.Lapis.Internal)
local MarketplaceServiceMock = require(script.Parent.MarketplaceServiceMock)
local PlayerMock = require(script.Parent.PlayerMock)

local USER_ID = 999
local PRODUCT_ID = 12345
local FAILS_PRODUCT_ID = 54321
local RECENT_PURCHASES_LIMIT = 3

return function(x)
	local assertEqual = x.assertEqual

	local function setup(context)
		local dataStoreService = DataStoreServiceMock.manual()
		context.dataStoreService = dataStoreService

		context.lapis = LapisInternal.new(false)
		context.lapis.setConfig({ dataStoreService = dataStoreService, showRetryWarnings = false, loadAttempts = 1 })

		context.write = function(name, key, data)
			local dataStore = dataStoreService.dataStores[name]["global"]

			dataStore:write(key, {
				migrationVersion = 0,
				data = data,
			})
		end

		context.marketplaceService = MarketplaceServiceMock.new()

		local players = {}

		context.addPlayer = function(userId)
			local player = PlayerMock.new(userId)
			table.insert(players, player)
			context.onPlayerAdded(player)

			return player
		end

		context.removePlayer = function(player)
			table.remove(players, table.find(players, player))
			player.Parent = nil
			context.onPlayerRemoving(player)
		end

		context.getPlayerByUserId = function(userId)
			for _, player in players do
				if userId == player.UserId then
					return player
				end
			end

			return nil
		end

		context.waitForDocument = function(player)
			while context.documents[player] == nil do
				task.wait()
			end

			return context.documents[player]
		end
	end

	x.beforeEach(function(context)
		setup(context)

		local DEFAULT_DATA = { coins = 100, recentPurchases = {} }
		local PRODUCTS = {
			[PRODUCT_ID] = function(data)
				return Sift.Dictionary.merge(data, {
					coins = data.coins + 100,
				})
			end,
			[FAILS_PRODUCT_ID] = function()
				error("product failed to grant")
			end,
		}

		local collection = context.lapis.createCollection("PlayerData", {
			defaultData = DEFAULT_DATA,
			validate = t.strictInterface({ coins = t.integer, recentPurchases = t.array(t.string) }),
		})

		local documents = {}
		context.documents = documents

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
				end)
		end

		local function onPlayerRemoving(player)
			local document = documents[player]

			if document ~= nil then
				documents[player] = nil
				document:close():catch(warn)
			end
		end

		context.marketplaceService.ProcessReceipt = function(receiptInfo)
			local player = context.getPlayerByUserId(receiptInfo.PlayerId)
			if player == nil then
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end

			while documents[player] == nil and player.Parent ~= nil do
				task.wait()
			end

			local document = documents[player]
			if document == nil then
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end

			local data = document:read()

			if table.find(data.recentPurchases, receiptInfo.PurchaseId) then
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

		context.onPlayerAdded = onPlayerAdded
		context.onPlayerRemoving = onPlayerRemoving
	end)

	x.test("happy path", function(context)
		local player = context.addPlayer(USER_ID)
		local purchaseDecision, purchaseId = context.marketplaceService:onProductPurchased(USER_ID, PRODUCT_ID)

		local data = context.documents[player]:read()

		assertEqual(purchaseDecision, Enum.ProductPurchaseDecision.PurchaseGranted)
		assertEqual(Sift.Dictionary.equalsDeep(data, { coins = 200, recentPurchases = { purchaseId } }), true)
	end)

	x.test("handles player leaving before ProcessReceipt", function(context)
		local player = context.addPlayer(USER_ID)

		context.removePlayer(player)

		local purchaseDecision = context.marketplaceService:onProductPurchased(USER_ID, PRODUCT_ID)

		assertEqual(purchaseDecision, Enum.ProductPurchaseDecision.NotProcessedYet)
	end)

	x.test("handles player leaving before document finishes loading", function(context)
		context.dataStoreService.yield:startYield()

		local player = context.addPlayer(USER_ID)

		local promise = Promise.try(function()
			return context.marketplaceService:onProductPurchased(USER_ID, PRODUCT_ID)
		end)

		context.removePlayer(player)

		local purchaseDecision = promise:expect()

		assertEqual(purchaseDecision, Enum.ProductPurchaseDecision.NotProcessedYet)

		context.dataStoreService.yield:stopYield()
	end)

	x.test("handles document load promise rejecting", function(context)
		context.dataStoreService.errors:addSimulatedErrors(1000)

		local player = context.addPlayer(USER_ID)

		local promise = Promise.try(function()
			return context.marketplaceService:onProductPurchased(USER_ID, PRODUCT_ID)
		end)

		task.wait(1)

		context.removePlayer(player)

		assertEqual(promise:expect(), Enum.ProductPurchaseDecision.NotProcessedYet)
	end)

	x.nested("handles product already existing in data", function()
		x.test("when receipt is already saved to datastore", function(context)
			context.write("PlayerData", `Player{USER_ID}`, {
				coins = 200,
				recentPurchases = { "abc" },
			})

			local player = context.addPlayer(USER_ID)

			local document = context.waitForDocument(player)
			local data = document:read()

			local purchaseDecision = context.marketplaceService:onProductPurchased(USER_ID, PRODUCT_ID, "abc")

			assertEqual(data, document:read()) -- Assert that data hasn't changed.
			assertEqual(purchaseDecision, Enum.ProductPurchaseDecision.PurchaseGranted)
		end)

		x.test("when receipt is not yet saved to datastore", function(context)
			local player = context.addPlayer(USER_ID)
			local document = context.waitForDocument(player)

			document:write({
				coins = 200,
				recentPurchases = { "abc" },
			})

			local data = document:read()

			local purchaseDecision = context.marketplaceService:onProductPurchased(USER_ID, PRODUCT_ID, "abc")

			assertEqual(data, document:read()) -- Assert that data hasn't changed.
			assertEqual(purchaseDecision, Enum.ProductPurchaseDecision.PurchaseGranted)
		end)

		x.test("when datastores fail", function(context)
			local player = context.addPlayer(USER_ID)
			local document = context.waitForDocument(player)

			document:write({ coins = 200, recentPurchases = { "abc" } })

			local data = document:read()

			context.dataStoreService.errors:addSimulatedErrors(1000)

			local purchaseDecision = context.marketplaceService:onProductPurchased(USER_ID, PRODUCT_ID, "abc")

			assertEqual(data, document:read()) -- Assert that data hasn't changed.
			assertEqual(purchaseDecision, Enum.ProductPurchaseDecision.NotProcessedYet)
		end)
	end)

	x.nested("granting product failures", function()
		x.test("handles product not existing", function(context)
			local player = context.addPlayer(USER_ID)
			local document = context.waitForDocument(player)
			local data = document:read()

			local purchaseDecision = context.marketplaceService:onProductPurchased(USER_ID, -1)

			assertEqual(data, document:read()) -- Assert that data hasn't changed.
			assertEqual(purchaseDecision, Enum.ProductPurchaseDecision.NotProcessedYet)
		end)

		x.test("handles product function failing", function(context)
			local player = context.addPlayer(USER_ID)
			local document = context.waitForDocument(player)
			local data = document:read()

			local purchaseDecision = context.marketplaceService:onProductPurchased(USER_ID, FAILS_PRODUCT_ID)

			assertEqual(data, document:read()) -- Assert that data hasn't changed.
			assertEqual(purchaseDecision, Enum.ProductPurchaseDecision.NotProcessedYet)
		end)
	end)

	x.nested("recent purchases", function()
		x.test("purchases are added to the end of the list", function(context)
			local player = context.addPlayer(USER_ID)
			local document = context.waitForDocument(player)

			local _, purchaseId1 = context.marketplaceService:onProductPurchased(USER_ID, PRODUCT_ID)
			local _, purchaseId2 = context.marketplaceService:onProductPurchased(USER_ID, PRODUCT_ID)

			local expected = { coins = 300, recentPurchases = { purchaseId1, purchaseId2 } }

			assertEqual(Sift.Dictionary.equalsDeep(document:read(), expected), true)
		end)

		x.test("purchases are removed from the start of the list", function(context)
			context.write("PlayerData", `Player{USER_ID}`, {
				coins = 100,
				recentPurchases = { "a", "b", "c", "d", "e" },
			})

			local player = context.addPlayer(USER_ID)

			local purchaseDecision, purchaseId = context.marketplaceService:onProductPurchased(USER_ID, PRODUCT_ID)

			local expected = { coins = 200, recentPurchases = { "d", "e", purchaseId } }

			assertEqual(purchaseDecision, Enum.ProductPurchaseDecision.PurchaseGranted)
			assertEqual(Sift.Dictionary.equalsDeep(context.documents[player]:read(), expected), true)
		end)
	end)

	x.test("handles product granted but save failing", function(context)
		local player = context.addPlayer(USER_ID)
		local document = context.waitForDocument(player)

		context.dataStoreService.errors:addSimulatedErrors(1000)

		local purchaseDecision, purchaseId = context.marketplaceService:onProductPurchased(USER_ID, PRODUCT_ID)

		local expected = { coins = 200, recentPurchases = { purchaseId } }

		assertEqual(purchaseDecision, Enum.ProductPurchaseDecision.NotProcessedYet)
		assertEqual(Sift.Dictionary.equalsDeep(document:read(), expected), true)
	end)
end
