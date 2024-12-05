local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)

local function defaultOptions()
	return {
		validate = function(data)
			return typeof(data.foo) == "string", "foo must be a string"
		end,
		defaultData = { foo = "bar" },
	}
end

return function(x)
	local assertEqual = x.assertEqual
	local shouldThrow = x.shouldThrow

	x.test("it should not merge close into save when save is running", function(context)
		local document = context.lapis.createCollection("collection", defaultOptions()):load("doc"):expect()

		-- It's not safe to merge saves when UpdateAsync is running.
		-- This will yield the UpdateAsync call until stopYield is called.
		context.dataStoreService.yield:startYield()

		local save = document:save()
		document:write({ foo = "new" })
		local close = document:close()

		context.dataStoreService.yield:stopYield()

		Promise.all({ save, close }):expect()

		local saved = context.read("collection", "doc")

		-- If data.foo == "bar", that means the close was merged with the save when it wasn't safe to.
		assert(saved.data.foo == "new", "")
	end)

	x.test("it should merge pending saves", function(context)
		local document = context.lapis.createCollection("collection", defaultOptions()):load("doc"):expect()

		context.dataStoreService.yield:startYield()

		local ongoingSave = document:save()

		local pendingSave = document:save()
		local pendingClose = document:close() -- This should override the pending save.

		context.dataStoreService.yield:stopYield()

		local values = Promise.all({ ongoingSave, pendingSave }):expect()

		-- This stops the close if it wasn't merged.
		context.dataStoreService.yield:startYield()

		-- Since the following code is resumed by the save promise, we need to wait for the close promise to resolve.
		task.wait()

		pendingClose:now("save and close didn't merge"):expect()

		-- save and close should never resolve with a value.
		-- It's checked in this test to make sure it works with save merging.
		assert(#values == 0, "")

		local saved = context.read("collection", "doc")

		assert(saved.lockId == nil, "")
	end)

	x.test("saves data", function(context)
		local document = context.lapis.createCollection("12345", defaultOptions()):load("doc"):expect()

		document:write({
			foo = "new value",
		})

		document:save():expect()

		local saved = context.read("12345", "doc")

		assert(typeof(saved) == "table", "")
		assert(typeof(saved.lockId) == "string", "")
		assert(saved.data.foo == "new value", "")
	end)

	x.test("writes the data", function(context)
		local document = context.lapis.createCollection("1", defaultOptions()):load("doc"):expect()

		document:write({
			foo = "baz",
		})

		assert(document:read().foo == "baz", "")
	end)

	x.test("write throws if data doesn't validate", function(context)
		local document = context.lapis.createCollection("2", defaultOptions()):load("doc"):expect()

		shouldThrow(function()
			document:write({
				foo = 5,
			})
		end, "foo must be a string")
	end)

	x.test("methods throw when called on a closed document", function(context)
		local document = context.lapis.createCollection("5", defaultOptions()):load("doc"):expect()

		local promise = document:close()

		shouldThrow(function()
			document:write({})
		end, "Cannot write to a closed document")

		shouldThrow(function()
			document:save()
		end, "Cannot save a closed document")

		shouldThrow(function()
			document:addUserId(1234)
		end, "Cannot add user id to a closed document")

		shouldThrow(function()
			document:removeUserId(1234)
		end, "Cannot remove user id from a closed document")

		promise:expect()
	end)

	x.test("close returns first promise when called again", function(context)
		local document = context.lapis.createCollection("col", defaultOptions()):load("doc"):expect()

		local promise = document:close()

		assertEqual(promise, document:close())
	end)

	x.test("loads with default data", function(context)
		local document = context.lapis.createCollection("o", defaultOptions()):load("a"):expect()

		assert(document:read().foo == "bar", "")
	end)

	x.test("loads with existing data", function(context)
		local collection = context.lapis.createCollection("xyz", defaultOptions())

		context.write("xyz", "xyz", {
			foo = "existing",
		})

		local document = collection:load("xyz"):expect()

		assert(document:read().foo == "existing", "")
	end)

	x.test("freezes document data", function(context)
		local collection = context.lapis.createCollection("collection", {
			defaultData = {},
		})

		context.write("collection", "document", { a = { b = 1 } })

		local document = collection:load("document"):expect()

		shouldThrow(function()
			document:read().a.b = 2
		end)

		document:write({ a = { b = 2 } })

		shouldThrow(function()
			document:read().a.b = 3
		end)
	end)

	x.test("doesn't save data when the lock was stolen", function(context)
		local collection = context.lapis.createCollection("hi", defaultOptions())

		local document = collection:load("hi"):expect()

		context.write("hi", "hi", {
			foo = "stolen",
		}, "stolenLockId")

		document:write({
			foo = "qux",
		})

		shouldThrow(function()
			document:save():expect()
		end, "The session lock was stolen")

		assert(context.read("hi", "hi").data.foo == "stolen", "")

		shouldThrow(function()
			document:close():expect()
		end, "The session lock was stolen")

		assert(context.read("hi", "hi").data.foo == "stolen", "")
	end)

	x.test("doesn't throw when the budget is exhausted", function(context)
		-- This makes sure the test doesn't pass by retyring after budget is added.
		context.lapis.setConfig({ loadAttempts = 1 })

		local document = context.lapis.createCollection("bye", defaultOptions()):load("bye"):expect()

		context.dataStoreService.budget.budgets[Enum.DataStoreRequestType.GetAsync] = 0
		context.dataStoreService.budget.budgets[Enum.DataStoreRequestType.SetIncrementAsync] = 0
		context.dataStoreService.budget.budgets[Enum.DataStoreRequestType.UpdateAsync] = 0

		local promise = document:save()

		-- This wait is necessary so that the request is run by Throttle.
		task.wait(0.1)

		context.dataStoreService.budget:update()

		promise:expect()
	end)

	x.test(":save doesn't resolve with any value", function(context)
		local document = context.lapis.createCollection("12345", defaultOptions()):load("doc"):expect()

		local a, b = document:save():expect()

		assert(a == nil, "")
		assert(b == nil, "")
	end)

	x.test(":close doesn't resolve with any value", function(context)
		local document = context.lapis.createCollection("12345", defaultOptions()):load("doc"):expect()

		local a, b = document:close():expect()

		assert(a == nil, "")
		assert(b == nil, "")
	end)

	x.nested("Document:beforeSave", function()
		x.test("throws when yielding", function(context)
			local document = context.lapis.createCollection("collection", defaultOptions()):load("document"):expect()

			document:beforeSave(function()
				task.wait()
			end)

			shouldThrow(function()
				document:save():expect()
			end, "beforeSave callback threw error: thread is not yieldable")
		end)

		x.test("throws when setting twice", function(context)
			local document = context.lapis.createCollection("collection", defaultOptions()):load("document"):expect()

			document:beforeSave(function() end)

			shouldThrow(function()
				document:beforeSave(function() end)
			end, "Document:beforeSave can only be called once")
		end)

		x.test("throws when calling close in callback", function(context)
			local document = context.lapis.createCollection("collection", defaultOptions()):load("document"):expect()

			document:beforeSave(function()
				document:close()
			end)

			shouldThrow(function()
				document:close():expect()
			end, "beforeSave callback threw error")
		end)

		x.test("throws when calling save in callback", function(context)
			local document = context.lapis.createCollection("collection", defaultOptions()):load("document"):expect()

			document:beforeSave(function()
				document:save()
			end)

			shouldThrow(function()
				document:close():expect()
			end, "beforeSave callback threw error")
		end)

		x.test("saves new data in document:save", function(context)
			local document = context.lapis.createCollection("collection", defaultOptions()):load("document"):expect()

			document:beforeSave(function()
				document:read() -- This checks that read doesn't error in the callback.
				document:write({ foo = "new" })
			end)

			document:save():expect()

			assertEqual(context.read("collection", "document").data.foo, "new")
		end)

		x.test("saves new data in document:close", function(context)
			local document = context.lapis.createCollection("collection", defaultOptions()):load("document"):expect()

			document:beforeSave(function()
				document:write({ foo = "new" })
			end)

			document:close():expect()

			assertEqual(context.read("collection", "document").data.foo, "new")
		end)
	end)

	x.nested("Document:beforeClose", function()
		x.test("throws when yielding", function(context)
			local document = context.lapis.createCollection("collection", defaultOptions()):load("document"):expect()

			document:beforeClose(function()
				task.wait()
			end)

			shouldThrow(function()
				document:close():expect()
			end, "beforeClose callback threw error: thread is not yieldable")
		end)

		x.test("throws when setting twice", function(context)
			local document = context.lapis.createCollection("collection", defaultOptions()):load("document"):expect()

			document:beforeClose(function() end)

			shouldThrow(function()
				document:beforeClose(function() end)
			end, "Document:beforeClose can only be called once")
		end)

		x.test("throws when calling close in callback", function(context)
			local document = context.lapis.createCollection("collection", defaultOptions()):load("document"):expect()

			document:beforeClose(function()
				document:close()
			end)

			shouldThrow(function()
				document:close():expect()
			end, "beforeClose callback threw error")
		end)

		x.test("throws when calling save in callback", function(context)
			local document = context.lapis.createCollection("collection", defaultOptions()):load("document"):expect()

			document:beforeClose(function()
				document:save()
			end)

			shouldThrow(function()
				document:close():expect()
			end, "beforeClose callback threw error")
		end)

		x.test("closes document even if beforeClose errors", function(context)
			local collection = context.lapis.createCollection("collection", defaultOptions())

			local promise = collection:load("document")
			local document = promise:expect()

			document:beforeClose(function()
				error("error")
			end)

			shouldThrow(function()
				document:close():expect()
			end)

			local secondPromise = collection:load("document")

			assert(secondPromise ~= promise, "collection:load should return a new promise")

			shouldThrow(function()
				document:write({ foo = "baz" })
			end, "Cannot write to a closed document")

			-- Ignore the could not acquire lock error.
			secondPromise:catch(function() end)
		end)

		x.test("saves new data", function(context)
			local document = context.lapis.createCollection("collection", defaultOptions()):load("document"):expect()

			document:beforeClose(function()
				document:read() -- This checks that read doesn't error in the callback.

				document:write({ foo = "new" })
			end)

			document:close():expect()

			assertEqual(context.read("collection", "document").data.foo, "new")
		end)

		x.test("beforeSave runs before beforeClose", function(context)
			local document = context.lapis.createCollection("collection", defaultOptions()):load("document"):expect()

			local order = ""

			document:beforeSave(function()
				order ..= "s"
			end)

			document:beforeClose(function()
				order ..= "c"
			end)

			document:close():expect()

			assertEqual(order, "sc")
		end)

		x.nested("keyInfo", function()
			x.test("gets load key info", function(context)
				local collection = context.lapis.createCollection("collection", defaultOptions())

				local before = context.getKeyInfo("collection", "document")
				local document = collection:load("document"):expect()
				local keyInfo = document:keyInfo()

				assert(before ~= keyInfo, "")
				assert(typeof(keyInfo) == "table", "")
				assert(keyInfo.Version == "0", "")
			end)

			x.test("updating user ids shouldn't affect key info", function(context)
				local collection = context.lapis.createCollection("collection", defaultOptions())

				local document = collection:load("document"):expect()
				local keyInfo = document:keyInfo()

				document:addUserId(123)

				assertEqual(#keyInfo:GetUserIds(), 0)
			end)

			x.test("key info is updated after :save", function(context)
				local document =
					context.lapis.createCollection("collection", defaultOptions()):load("document"):expect()
				local keyInfo = document:keyInfo()

				document:save():expect()

				local newKeyInfo = document:keyInfo()

				assert(keyInfo ~= newKeyInfo, "")
				assert(newKeyInfo.Version == "1", "")
			end)

			x.test("key info is updated after :close", function(context)
				local document =
					context.lapis.createCollection("collection", defaultOptions()):load("document"):expect()
				local keyInfo = document:keyInfo()

				document:close():expect()

				local newKeyInfo = document:keyInfo()

				assert(keyInfo ~= newKeyInfo, "")
				assert(newKeyInfo.Version == "1", "")
			end)
		end)
	end)
end
