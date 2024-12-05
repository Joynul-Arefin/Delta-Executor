local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DataStoreServiceMock = require(ReplicatedStorage.DevPackages.DataStoreServiceMock)
local Internal = require(script.Parent.Internal)
local Promise = require(script.Parent.Parent.Promise)

local function defaultOptions()
	return {
		validate = function(data)
			return typeof(data.apples) == "number", "apples should be a number"
		end,
		defaultData = {
			apples = 20,
		},
	}
end

return function(x)
	local assertEqual = x.assertEqual
	local shouldThrow = x.shouldThrow

	x.beforeEach(function(context)
		local dataStoreService = DataStoreServiceMock.manual()

		context.dataStoreService = dataStoreService

		-- We want requests to overflow the throttle queue so that they result in errors.
		dataStoreService.budget:setMaxThrottleQueueSize(0)

		context.lapis = Internal.new(false)
		context.lapis.setConfig({ dataStoreService = dataStoreService, showRetryWarnings = false })

		context.write = function(name, key, data, lockId, userIds, metadata)
			local dataStore = dataStoreService.dataStores[name]["global"]

			dataStore:write(key, {
				migrationVersion = 0,
				lockId = lockId,
				data = data,
			}, userIds, metadata)
		end

		context.read = function(name, key)
			return dataStoreService.dataStores[name]["global"].data[key]
		end

		context.expectUnlocked = function(name, key)
			local data = dataStoreService.dataStores[name]["global"].data[key]

			if data ~= nil and data.lockId ~= nil then
				error("Document is locked")
			end
		end

		context.expectLocked = function(name, key)
			local data = dataStoreService.dataStores[name]["global"].data[key]

			if data == nil or data.lockId == nil then
				error("Document is not locked")
			end
		end

		context.expectUserIds = function(name, key, targetUserIds)
			local keyInfo = dataStoreService.dataStores[name]["global"].keyInfos[key]

			local currentUserIds = if keyInfo ~= nil then keyInfo:GetUserIds() else {}

			if #currentUserIds ~= #targetUserIds then
				error("Incorrect user ids length")
			end

			for index, value in targetUserIds do
				if currentUserIds[index] ~= value then
					error("Invalid user id")
				end
			end
		end

		context.getKeyInfo = function(name, key)
			return dataStoreService.dataStores[name]["global"].keyInfos[key]
		end
	end)

	x.test("throws when setting invalid config key", function(context)
		shouldThrow(function()
			context.lapis.setConfig({
				foo = true,
			})
		end, 'Invalid config key "foo"')
	end)

	x.test("throws when creating a duplicate collection", function(context)
		context.lapis.createCollection("foo", defaultOptions())

		shouldThrow(function()
			context.lapis.createCollection("foo", defaultOptions())
		end, 'Collection "foo" already exists')
	end)

	x.test("freezes default data", function(context)
		local defaultData = { a = { b = { c = 5 } } }

		context.lapis.createCollection("baz", {
			defaultData = defaultData,
		})

		shouldThrow(function()
			defaultData.a.b.c = 8
		end)
	end)

	x.test("validates default data as a table", function(context)
		shouldThrow(function()
			context.lapis.createCollection("bar", {
				validate = function()
					return false, "data is invalid"
				end,
			})
		end, "data is invalid")
	end)

	x.test("handles default data erroring", function(context)
		local collection = context.lapis.createCollection("collection", {
			defaultData = function()
				error("foo")
			end,
		})

		shouldThrow(function()
			collection:load("document"):expect()
		end, "'defaultData' threw an error", "foo")
	end)

	x.test("validates default data as a function", function(context)
		local collection = context.lapis.createCollection("collection", {
			defaultData = function()
				return {}
			end,
			validate = function()
				return false, "foo"
			end,
		})

		shouldThrow(function()
			collection:load("document"):expect()
		end, "Invalid data:", "foo")
	end)

	x.test("default data function should set default data", function(context)
		local collection = context.lapis.createCollection("collection", {
			defaultData = function()
				return "default"
			end,
		})

		local document = collection:load("document"):expect()

		assertEqual(document:read(), "default")
	end)

	x.test("should pass key to default data", function(context)
		local key
		local collection = context.lapis.createCollection("collection", {
			defaultData = function(passed)
				key = passed
				return {}
			end,
		})

		collection:load("document"):expect()
		assertEqual(key, "document")
	end)

	x.test("default data function should deep copy data", function(context)
		local returned = { {} }
		local collection = context.lapis.createCollection("collection", {
			defaultData = function()
				return returned
			end,
		})

		local document = collection:load("document"):expect()

		assert(document:read() ~= returned, "")
		assert(document:read()[1] ~= returned[1], "")
	end)

	x.test("default data function should freeze data", function(context)
		local collection = context.lapis.createCollection("collection", {
			defaultData = function()
				return {}
			end,
		})

		local document = collection:load("document"):expect()

		shouldThrow(function()
			document:read().foo = true
		end, "readonly")
	end)

	x.test("handles validate erroring", function(context)
		local created = false

		local collection = context.lapis.createCollection("collection", {
			validate = function()
				if created then
					error("foo")
				else
					return true
				end
			end,
		})

		created = true

		context.write("collection", "document", {})

		shouldThrow(function()
			collection:load("document"):expect()
		end, "'validate' threw an error", "foo")
	end)

	x.test("should not override data if validation fails", function(context)
		local collection = context.lapis.createCollection("collection", defaultOptions())

		context.write("collection", "doc", { apples = "string" })

		local old = context.read("collection", "doc")

		shouldThrow(function()
			collection:load("doc"):expect()
		end, "apples should be a number")

		assertEqual(old, context.read("collection", "doc"))
	end)

	x.test("should session lock the document", function(context)
		local collection = context.lapis.createCollection("collection", defaultOptions())
		local document = collection:load("doc"):expect()

		local otherLapis = Internal.new(false)
		otherLapis.setConfig({ dataStoreService = context.dataStoreService, loadAttempts = 1 })

		local otherCollection = otherLapis.createCollection("collection", defaultOptions())

		shouldThrow(function()
			otherCollection:load("doc"):expect()
		end, "Could not acquire lock")

		-- It should keep the session lock when saved.
		document:save():expect()

		shouldThrow(function()
			otherCollection:load("doc"):expect()
		end, "Could not acquire lock")

		-- It should remove the session lock when closed.
		document:close():expect()

		otherCollection:load("doc"):expect()
	end)

	x.test("load should retry when document is session locked", function(context)
		local collection = context.lapis.createCollection("collection", defaultOptions())
		local document = collection:load("doc"):expect()

		local otherLapis = Internal.new(false)
		otherLapis.setConfig({
			dataStoreService = context.dataStoreService,
			loadAttempts = 4,
			loadRetryDelay = 0.5,
			showRetryWarnings = false,
		})

		local otherCollection = otherLapis.createCollection("collection", defaultOptions())
		local promise = otherCollection:load("doc")

		-- Wait for the document to attempt to load once.
		task.wait(0.1)

		-- Remove the sesssion lock.
		document:close():expect()

		promise:expect()
	end)

	x.test("second load should fail because of session lock", function(context)
		local collection = context.lapis.createCollection("collection", defaultOptions())

		context.lapis.setConfig({ loadAttempts = 1 })

		local first = collection:load("document")
		local second = collection:load("document")

		first:expect()

		shouldThrow(function()
			second:expect()
		end, "Could not acquire lock")
	end)

	x.test("load returns a new promise when first load fails", function(context)
		context.lapis.setConfig({ loadAttempts = 1 })
		context.dataStoreService.errors:addSimulatedErrors(1)

		local collection = context.lapis.createCollection("ghi", defaultOptions())

		local promise1 = collection:load("ghi")

		shouldThrow(function()
			promise1:expect()
		end)

		local promise2 = collection:load("ghi")

		assert(promise1 ~= promise2, "load should return new promise")

		promise2:expect()
	end)

	x.nested("migrations", function()
		x.test("migrates the data", function(context)
			local collection = context.lapis.createCollection("migration", {
				validate = function(value)
					return value == "newData", "value does not equal newData"
				end,
				defaultData = "newData",
				migrations = {
					function()
						return "newData"
					end,
				},
			})

			context.write("migration", "migration", "data")

			collection:load("migration"):expect()

			local readData = collection:read("migration"):expect()

			assertEqual(readData, "newData")
		end)

		x.test("error is thrown if a migration returns nil", function(context)
			local collection = context.lapis.createCollection("collection", {
				defaultData = {},
				migrations = {
					function() end,
				},
			})

			context.write("collection", "document", {})

			shouldThrow(function()
				collection:load("document"):expect()
			end, "Migration 1 returned 'nil'")

			shouldThrow(function()
				collection:read("document"):expect()
			end, "Migration 1 returned 'nil'")
		end)

		x.test("migrations should allow mutable updates", function(context)
			local collection = context.lapis.createCollection("collection", {
				validate = function(value)
					return typeof(value.coins) == "number"
				end,
				defaultData = { coins = 0 },
				migrations = {
					function(old)
						old.coins = 0

						return old
					end,
					function(old)
						old.coins = 100

						return old
					end,
				},
			})

			context.write("collection", "document", {})

			local document = collection:load("document"):expect()

			assertEqual(document:read().coins, 100)
		end)

		x.test("data should be frozen after a migration", function(context)
			local collection = context.lapis.createCollection("collection", {
				validate = function(value)
					return typeof(value.coins) == "number"
				end,
				defaultData = { coins = 0 },
				migrations = {
					function(old)
						old.coins = 0
						return old
					end,
				},
			})

			context.write("collection", "document", {})

			local document = collection:load("document"):expect()

			shouldThrow(function()
				document:read().coins = 100
			end, "readonly")
		end)

		x.test("migrations should work with tables and functions", function(context)
			local collection = context.lapis.createCollection("collection", {
				defaultData = "a",
				migrations = {
					{
						backwardsCompatible = false,
						migrate = function(old)
							return old
						end,
					},
					function(old)
						return old
					end,
				},
			})

			local dataStore = context.dataStoreService.dataStores.collection.global
			dataStore:write("document", {
				migrationVersion = 0,
				data = "a",
			})

			collection:load("document"):expect()
		end)

		x.nested("saved version ahead", function()
			x.test(
				"throws when migration version is ahead of latest version and is not backwards compatible",
				function(context)
					local collection = context.lapis.createCollection("collection", {
						defaultData = "a",
						migrations = {
							function(old)
								return old
							end,
						},
					})

					local dataStore = context.dataStoreService.dataStores.collection.global
					dataStore:write("document", {
						migrationVersion = 2,
						data = "b",
					})

					shouldThrow(function()
						collection:load("document"):expect()
					end, "Saved migration version 2 is not backwards compatible with version 1")

					shouldThrow(function()
						collection:read("document"):expect()
					end, "Saved migration version 2 is not backwards compatible with version 1")
				end
			)

			x.test("default data gets lastCompatibleVersion", function(context)
				local migrate = function(old)
					return old
				end

				local collection = context.lapis.createCollection("collection", {
					defaultData = "a",
					migrations = {
						{ migrate = migrate, backwardsCompatible = true },
					},
				})

				collection:load("document"):expect():close():expect()

				local otherLapis = Internal.new(false)
				otherLapis.setConfig({ dataStoreService = context.dataStoreService, loadAttempts = 1 })

				local otherCollection = otherLapis.createCollection("collection", {
					defaultData = "a",
				})

				-- This would error if lastCompatibleVersion = 0 wasn't saved.
				otherCollection:load("document"):expect()
			end)

			x.test("handles lastCompatibleVersion == nil", function(context)
				local collection = context.lapis.createCollection("collection", {
					defaultData = "a",
				})

				local dataStore = context.dataStoreService.dataStores.collection.global
				dataStore:write("document", {
					migrationVersion = 1,
					data = "b",
				})

				shouldThrow(function()
					collection:load("document"):expect()
				end, "Saved migration version 1 is not backwards compatible with version 0")

				shouldThrow(function()
					collection:read("document"):expect()
				end, "Saved migration version 1 is not backwards compatible with version 0")
			end)

			x.test("migration saves lastCompatibleVersion", function(context)
				local function migrate(old)
					return old
				end

				local collection = context.lapis.createCollection("collection", {
					defaultData = "a",
					migrations = {
						{ migrate = migrate, backwardsCompatible = false },
						{ migrate = migrate, backwardsCompatible = true },
						{ migrate = migrate, backwardsCompatible = true },
					},
				})

				local dataStore = context.dataStoreService.dataStores.collection.global
				dataStore:write("document", {
					migrationVersion = 0,
					data = "b",
				})

				collection:load("document"):expect():close():expect()

				local lapisWithV0 = Internal.new(false)
				lapisWithV0.setConfig({ dataStoreService = context.dataStoreService, loadAttempts = 1 })

				local collectionWithV0 = lapisWithV0.createCollection("collection", {
					defaultData = "a",
				})

				shouldThrow(function()
					collectionWithV0:load("document"):expect()
				end, "Saved migration version 3 is not backwards compatible with version 0")

				local lapisWithV1 = Internal.new(false)
				lapisWithV1.setConfig({ dataStoreService = context.dataStoreService, loadAttempts = 1 })

				local collectionWithV1 = lapisWithV1.createCollection("collection", {
					defaultData = "a",
					migrations = {
						{ migrate = migrate, backwardsCompatible = false },
						{ migrate = migrate, backwardsCompatible = true },
					},
				})

				-- This shouldn't error because v3 is backwards compatible with v1.
				collectionWithV1:load("document"):expect()
			end)

			x.test("keeps saved version", function(context)
				local collection = context.lapis.createCollection("collection", {
					defaultData = "a",
				})

				local dataStore = context.dataStoreService.dataStores.collection.global
				dataStore:write("document", {
					lastCompatibleVersion = 0,
					migrationVersion = 1,
					data = "b",
				})

				local document = collection:load("document"):expect()

				assertEqual(context.read("collection", "document").migrationVersion, 1)

				document:save("document"):expect()

				assertEqual(context.read("collection", "document").migrationVersion, 1)

				document:close("document"):expect()

				assertEqual(context.read("collection", "document").migrationVersion, 1)
			end)
		end)
	end)

	x.test("closing and immediately opening should return a new document", function(context)
		local collection = context.lapis.createCollection("ccc", defaultOptions())

		local document = collection:load("doc"):expect()

		local close = document:close()
		local open = collection:load("doc")

		close:expect()

		local newDocument = open:expect()

		assert(newDocument ~= document, "")
	end)

	x.test("closes all document on game:BindToClose", function(context)
		local collection = context.lapis.createCollection("collection", defaultOptions())

		local one = collection:load("one"):expect()
		local two = collection:load("two"):expect()
		local three = collection:load("three"):expect()

		context.dataStoreService.yield:startYield()

		local thread = task.spawn(function()
			context.lapis.autoSave:onGameClose()
		end)

		assert(coroutine.status(thread) == "suspended", "onGameClose didn't wait for the documents to finish closing")

		-- Verify each document has been closed.
		for _, document in { one, two, three } do
			shouldThrow(function()
				document:save():expect()
			end, "Cannot save a closed document")
		end

		context.dataStoreService.yield:stopYield()

		-- Wait for documents to finish saving.
		task.wait(0.1)

		assert(coroutine.status(thread) == "dead", "")
	end)

	x.nested("user ids", function()
		x.test("it uses defaultUserIds on first load", function(context)
			local collection = context.lapis.createCollection("collection", defaultOptions())

			local document = collection:load("document", { 123 }):expect()
			context.expectUserIds("collection", "document", { 123 })
			document:close():expect()
			context.expectUserIds("collection", "document", { 123 })

			-- Since the document has already been created, the defaultUserIds should not override the saved ones.
			document = collection:load("document", { 321 }):expect()
			context.expectUserIds("collection", "document", { 123 })
			document:close():expect()
			context.expectUserIds("collection", "document", { 123 })
		end)

		x.test("adds new user ids", function(context)
			local collection = context.lapis.createCollection("collection", defaultOptions())

			local document = collection:load("document", {}):expect()

			document:addUserId(111)
			document:addUserId(111) -- It should not add this user id twice.
			document:addUserId(222)

			context.expectUserIds("collection", "document", {})

			document:save():expect()

			context.expectUserIds("collection", "document", { 111, 222 })

			document:close():expect()

			context.expectUserIds("collection", "document", { 111, 222 })
		end)

		x.test("removes new user ids", function(context)
			local collection = context.lapis.createCollection("collection", defaultOptions())

			local document = collection:load("document", { 333, 444, 555 }):expect()

			document:removeUserId(111) -- It should do nothing if the user id doesn't exist.
			document:removeUserId(444)

			context.expectUserIds("collection", "document", { 333, 444, 555 })

			document:save():expect()

			context.expectUserIds("collection", "document", { 333, 555 })

			document:close():expect()

			context.expectUserIds("collection", "document", { 333, 555 })
		end)
	end)

	x.nested("load during BindToClose", function()
		x.test("load infinitely yields after BindToClose", function(context)
			local collection = context.lapis.createCollection("collection", defaultOptions())

			task.spawn(function()
				context.lapis.autoSave:onGameClose()
			end)

			shouldThrow(function()
				collection:load("document"):timeout(0.5):expect()
			end, "Timed out")
		end)

		x.test("load just before BindToClose", function(context)
			local collection = context.lapis.createCollection("collection", defaultOptions())

			context.dataStoreService.yield:startYield()

			collection:load("document")

			local waited = false
			local finished = false
			local thread = task.spawn(function()
				RunService.PostSimulation:Wait()
				RunService.PostSimulation:Wait()
				waited = true
				context.lapis.autoSave:onGameClose()
				finished = true
			end)

			while not waited do
				task.wait()
			end

			context.dataStoreService.yield:stopYield()

			context.dataStoreService.yield:startYield()
			assert(
				coroutine.status(thread) == "suspended",
				"onGameClose didn't wait for the documents to finish closing"
			)
			context.dataStoreService.yield:stopYield()

			while not finished do
				task.wait()
			end

			context.expectUnlocked("collection", "document")

			assert(coroutine.status(thread) == "dead", "")
		end)

		x.test("BindToClose should finish if a document fails to load", function(context)
			local collection = context.lapis.createCollection("collection", defaultOptions())

			context.write("collection", "document", "INVALID DATA")
			collection:load("document"):catch(function() end)

			-- Wait to close game so that the save request doesn't get cancelled.
			task.wait(0.1)

			Promise.try(function()
				context.lapis.autoSave:onGameClose()
			end)
				:timeout(1)
				:expect()
		end)
	end)

	x.nested("freezeData = false", function()
		x.test("default data should be deep copied", function(context)
			local defaultData = { foo = {} }

			local collection = context.lapis.createCollection("collection", {
				freezeData = false,
				defaultData = defaultData,
			})

			local document = collection:load("document"):expect()
			local data = document:read()

			assert(data ~= defaultData, "")
			assert(data.foo ~= defaultData.foo, "")
			assert(typeof(data.foo) == "table", "")
		end)

		x.test("data should not be frozen", function(context)
			local collection = context.lapis.createCollection("collection", {
				freezeData = false,
				defaultData = {},
			})
			local document = collection:load("document"):expect()

			-- This would error if the data was frozen.
			document:read().apples = 1

			-- Make sure write doesn't freeze the data.
			document:write(document:read())
			document:read().apples = 1
		end)

		x.test("should validate data in save and close", function(context)
			local valid = true
			local collection = context.lapis.createCollection("collection", {
				freezeData = false,
				validate = function()
					return valid, "data is invalid"
				end,
				defaultData = {},
			})

			local document = collection:load("document"):expect()

			valid = false

			shouldThrow(function()
				document:save():expect()
			end, "data is invalid")

			shouldThrow(function()
				document:close():expect()
			end, "data is invalid")
		end)

		x.test("should handle validate errors data in save and close", function(context)
			local throwError = false
			local collection = context.lapis.createCollection("collection", {
				freezeData = false,
				validate = function()
					if throwError then
						error("foo")
					end

					return true
				end,
				defaultData = {},
			})

			local document = collection:load("document"):expect()

			throwError = true

			shouldThrow(function()
				document:save():expect()
			end, "'validate' threw an error", "foo")

			shouldThrow(function()
				document:close():expect()
			end, "'validate' threw an error", "foo")
		end)
	end)

	x.nested("Collection:read", function()
		x.test("returns nil when there is no data", function(context)
			local collection = context.lapis.createCollection("collection", {
				defaultData = "data",
			})

			local data, keyInfo = collection:read("key"):expect()

			assertEqual(data, nil)
			assertEqual(keyInfo, nil)
		end)

		x.test("returns existing data", function(context)
			local collection = context.lapis.createCollection("collection", {
				defaultData = "data",
			})

			collection:load("key", { 321 }):expect()

			local data, keyInfo = collection:read("key"):expect()

			assertEqual(data, "data")
			assertEqual(keyInfo:GetUserIds()[1], 321)
		end)

		x.test("throws error when data is invalid", function(context)
			local collection = context.lapis.createCollection("collection", {
				defaultData = "data",
				validate = function(data)
					return data == "data", "data was invalid"
				end,
			})

			context.write("collection", "key", "INVALID DATA")

			shouldThrow(function()
				collection:read("key"):expect()
			end, "Invalid data")
		end)

		x.test("throws error when validate throws", function(context)
			local created = false
			local collection = context.lapis.createCollection("collection", {
				defaultData = "data",
				validate = function()
					if created then
						error("validate error")
					else
						return true
					end
				end,
			})
			created = true

			context.write("collection", "key", "data")

			shouldThrow(function()
				collection:read("key"):expect()
			end, "'validate' threw an error")
		end)
	end)

	x.nested("Collection:remove", function()
		x.test("should remove data", function(context)
			local collection = context.lapis.createCollection("collection", defaultOptions())

			collection:load("document"):expect():close():expect()

			collection:remove("document"):expect()

			assertEqual(context.read("collection", "document"), nil)
		end)

		x.test("documents open during remove should fail to save/close", function(context)
			local collection = context.lapis.createCollection("collection", defaultOptions())

			local document = collection:load("document"):expect()

			collection:remove("document"):expect()

			shouldThrow(function()
				document:save():expect()
			end, "The document was removed")

			shouldThrow(function()
				document:close():expect()
			end, "The document was removed")
		end)
	end)

	x.nested("Document:close should still unlock after specific errors", function()
		x.test("shouldn't overwrite stolen lock", function(context)
			local collection = context.lapis.createCollection("collection", defaultOptions())
			local document = collection:load("document"):expect()

			context.write("collection", "document", { apples = 20 }, "stolen lock")

			document:beforeSave(function()
				error("oh no")
			end)

			shouldThrow(function()
				document:close("document"):expect()
			end)

			task.wait(0.1)

			context.expectLocked("collection", "document")
		end)

		x.test("doesn't work for session lock stolen error", function(context)
			local collection = context.lapis.createCollection("collection", defaultOptions())
			local document = collection:load("document"):expect()

			context.write("collection", "document", { apples = 20 }, "another lock id")

			document:write({ apples = 100 })

			shouldThrow(function()
				document:close("document"):expect()
			end)

			task.wait(0.1)

			context.expectLocked("collection", "document")
			assertEqual(context.read("collection", "document").data.apples, 20) -- Only the lock should have changed.
		end)

		x.test("beforeSave error", function(context)
			local collection = context.lapis.createCollection("collection", defaultOptions())

			local document = collection:load("document"):expect()

			document:write({ apples = 100 })

			document:beforeSave(function()
				error("oh no")
			end)

			shouldThrow(function()
				document:close("document"):expect()
			end)

			task.wait(0.1)

			context.expectUnlocked("collection", "document")
			assertEqual(context.read("collection", "document").data.apples, 20) -- Only the lock should have changed.
		end)

		x.test("beforeClose error", function(context)
			local collection = context.lapis.createCollection("collection", defaultOptions())

			local document = collection:load("document"):expect()

			document:write({ apples = 100 })

			document:beforeClose(function()
				error("oh no")
			end)

			shouldThrow(function()
				document:close("document"):expect()
			end)

			task.wait(0.1)

			context.expectUnlocked("collection", "document")
			assertEqual(context.read("collection", "document").data.apples, 20) -- Only the lock should have changed.
		end)

		x.test("validate error", function(context)
			local collection = context.lapis.createCollection("collection", {
				validate = function(data)
					return typeof(data.apples) == "number", "apples should be a number"
				end,
				defaultData = { apples = 20 },
				freezeData = false,
			})

			local document = collection:load("document"):expect()

			document:read().apples = nil

			shouldThrow(function()
				document:close("document"):expect()
			end)

			task.wait(0.1)

			context.expectUnlocked("collection", "document")
			assertEqual(context.read("collection", "document").data.apples, 20) -- Only the lock should have changed.
		end)

		x.test("validate threw error", function(context)
			local loaded = false
			local collection = context.lapis.createCollection("collection", {
				validate = function()
					if loaded then
						error("oh no")
					end
					return true
				end,
				defaultData = { apples = 20 },
				freezeData = false,
			})

			local document = collection:load("document"):expect()

			loaded = true

			shouldThrow(function()
				document:close("document"):expect()
			end)

			task.wait(0.1)

			context.expectUnlocked("collection", "document")
			assertEqual(context.read("collection", "document").data.apples, 20) -- Only the lock should have changed.
		end)

		x.test("onGameClose should wait for the lock to remove", function(context)
			local collection = context.lapis.createCollection("collection", defaultOptions())
			local document = collection:load("document"):expect()

			document:beforeSave(function()
				error("oh no")
			end)

			context.dataStoreService.yield:startYield()

			shouldThrow(function()
				document:close("document"):expect()
			end)

			local thread = task.spawn(function()
				context.lapis.autoSave:onGameClose()
			end)

			assert(coroutine.status(thread) == "suspended", "onGameClose didn't wait for locks to be removed")

			context.dataStoreService.yield:stopYield()

			-- Wait for locks to be removed.
			task.wait(0.1)

			assert(coroutine.status(thread) == "dead", "")
		end)

		x.test("should preserve userids/metadata", function(context)
			local collection = context.lapis.createCollection("collection", defaultOptions())
			local document = collection:load("document"):expect()

			document:beforeSave(function()
				error("oh no")
			end)

			context.write(
				"collection",
				"document",
				document:read(),
				context.read("collection", "document").lockId,
				{ 1234 },
				{ foo = "bar" }
			)

			shouldThrow(function()
				document:close("document"):expect()
			end)

			task.wait(0.1)

			local keyInfo = context.getKeyInfo("collection", "document")

			assertEqual(keyInfo:GetUserIds()[1], 1234)
			assertEqual(keyInfo:GetMetadata().foo, "bar")
		end)
	end)

	x.test("preserves metadata", function(context)
		local collection = context.lapis.createCollection("collection", defaultOptions())

		context.write("collection", "document", { apples = 30 }, nil, nil, { foo = "bar" })

		local function verifyMetadata()
			local keyInfo = context.getKeyInfo("collection", "document")
			assertEqual(keyInfo:GetMetadata().foo, "bar")
		end

		local document = collection:load("document"):expect()
		verifyMetadata()

		document:save():expect()
		verifyMetadata()

		document:close():expect()
		verifyMetadata()
	end)
end
