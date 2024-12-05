local Error = require(script.Parent.Error)
local Promise = require(script.Parent.Parent.Promise)
local Throttle = require(script.Throttle)

local Data = {}
Data.__index = Data

function Data.new(config)
	local throttle = Throttle.new(config)

	throttle:start()

	return setmetatable({
		config = config,
		throttle = throttle,
		ongoingSaves = {},
	}, Data)
end

function Data:waitForOngoingSave(dataStore, key)
	if self.ongoingSaves[dataStore] == nil or self.ongoingSaves[dataStore][key] == nil then
		return Promise.resolve()
	end

	local ongoingSave = self.ongoingSaves[dataStore][key]

	return Promise.allSettled({
		ongoingSave.promise,
		if ongoingSave.pendingSave ~= nil then ongoingSave.pendingSave.promise else nil,
	})
end

function Data:waitForOngoingSaves()
	local promises = {}

	for _, ongoingSaves in self.ongoingSaves do
		for _, ongoingSave in ongoingSaves do
			if ongoingSave.pendingSave ~= nil then
				table.insert(promises, ongoingSave.pendingSave.promise)
			end

			table.insert(promises, ongoingSave.promise)
		end
	end

	return Promise.allSettled(promises)
end

function Data:read(dataStore, key)
	return self.throttle:getAsync(dataStore, key)
end

function Data:load(dataStore, key, transform)
	return self:waitForOngoingSave(dataStore, key):andThen(function()
		local attempts = self.config:get("loadAttempts")
		local retryDelay = self.config:get("loadRetryDelay")

		return self.throttle:updateAsync(dataStore, key, transform, true, attempts, retryDelay)
	end)
end

function Data:save(dataStore, key, transform)
	if self.ongoingSaves[dataStore] == nil then
		self.ongoingSaves[dataStore] = {}
	end

	local ongoingSave = self.ongoingSaves[dataStore][key]

	if ongoingSave == nil then
		local attempts = self.config:get("saveAttempts")
		local promise = self.throttle:updateAsync(dataStore, key, transform, false, attempts):finally(function()
			self.ongoingSaves[dataStore][key] = nil

			if next(self.ongoingSaves[dataStore]) == nil then
				self.ongoingSaves[dataStore] = nil
			end
		end)

		if promise:getStatus() == Promise.Status.Started then
			self.ongoingSaves[dataStore][key] = { promise = promise }
		end

		return promise
	elseif ongoingSave.pendingSave == nil then
		local pendingSave = { transform = transform }

		local function save()
			return self:save(dataStore, key, pendingSave.transform)
		end

		-- promise:finally(save) can't be used because if the ongoingSave promise rejects, so will the promise returned from finally.
		pendingSave.promise = ongoingSave.promise:andThen(save, save)

		ongoingSave.pendingSave = pendingSave

		return pendingSave.promise
	else
		ongoingSave.pendingSave.transform = transform

		return ongoingSave.pendingSave.promise
	end
end

function Data:removeLock(dataStore, key, lockIdToRemove)
	local function transform(value, keyInfo)
		if value == nil then
			return "fail", Error.new("DocumentRemoved", "The document was removed")
		end

		if value.lockId ~= lockIdToRemove then
			return "fail", Error.new("SessionLockStolen", "The session lock was stolen")
		end

		value.lockId = nil

		return "succeed", value, keyInfo:GetUserIds(), keyInfo:GetMetadata()
	end

	local attempts = self.config:get("saveAttempts")

	return self.throttle:updateAsync(dataStore, key, transform, false, attempts)
end

function Data:remove(dataStore, key)
	return self.throttle:removeAsync(dataStore, key)
end

return Data
