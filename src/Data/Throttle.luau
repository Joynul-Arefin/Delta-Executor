local RunService = game:GetService("RunService")

local Error = require(script.Parent.Parent.Error)
local Promise = require(script.Parent.Parent.Parent.Promise)

local GET_ASYNC_RETRY_ATTEMPTS = 5
local GET_ASYNC_RETRY_DELAY = 1

local REMOVE_ASYNC_RETRY_ATTEMPTS = 5
local REMOVE_ASYNC_RETRY_DELAY = 1

local getAsyncOptions = Instance.new("DataStoreGetOptions")
getAsyncOptions.UseCache = false

local function updateAsync(throttle, request)
	return Promise.new(function(resolve)
		local resultOutside, transformedOutside, keyInfo
		local ok, err = pcall(function()
			_, keyInfo = request.dataStore:UpdateAsync(request.key, function(...)
				if request.cancelOnGameClose and throttle.gameClosed then
					resultOutside = "cancelled"
					return nil
				end

				local result, transformed, userIds, metadata = request.transform(...)

				resultOutside = result
				transformedOutside = transformed

				if result == "succeed" then
					return transformed, userIds, metadata
				else
					return nil
				end
			end)
		end)

		if resultOutside == "cancelled" then
			resolve("cancelled")
		elseif not ok then
			resolve("retry", Error.new("RobloxApiError", err))
		else
			resolve(resultOutside, transformedOutside, keyInfo)
		end
	end)
end

local function getAsync(request)
	return Promise.new(function(resolve)
		local ok, value, keyInfo = pcall(function()
			return request.dataStore:GetAsync(request.key, getAsyncOptions)
		end)

		resolve(ok, value, keyInfo)
	end)
end

local function removeAsync(request)
	return Promise.new(function(resolve)
		local ok, message = pcall(function()
			request.dataStore:RemoveAsync(request.key)
		end)

		resolve(ok, message)
	end)
end

local Throttle = {}
Throttle.__index = Throttle

function Throttle.new(config)
	return setmetatable({
		config = config,
		updateAsyncQueue = {},
		getAsyncQueue = {},
		removeAsyncQueue = {},
		gameClosed = false,
	}, Throttle)
end

function Throttle:getUpdateAsyncBudget()
	return self.config:get("dataStoreService"):GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
end

function Throttle:getGetAsyncBudget()
	return self.config:get("dataStoreService"):GetRequestBudgetForRequestType(Enum.DataStoreRequestType.GetAsync)
end

function Throttle:getRemoveAsyncBudget()
	return self.config
		:get("dataStoreService")
		:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.SetIncrementAsync)
end

function Throttle:start()
	local function retryRequest(request, err)
		request.attempts -= 1

		if request.attempts == 0 then
			request.reject(err)
		else
			if self.config:get("showRetryWarnings") then
				warn(`DataStore operation failed. Retrying...\nError: {err.message}`)
			end

			task.wait(request.retryDelay)
		end
	end

	local function updateUpdateAsync()
		for index = #self.updateAsyncQueue, 1, -1 do
			local request = self.updateAsyncQueue[index]

			if request.attempts == 0 then
				table.remove(self.updateAsyncQueue, index)
			elseif request.promise == nil and request.cancelOnGameClose and self.gameClosed then
				request.resolve("cancelled")
				table.remove(self.updateAsyncQueue, index)
			end
		end

		for _, request in self.updateAsyncQueue do
			if self:getUpdateAsyncBudget() == 0 then
				break
			end

			if request.promise ~= nil then
				continue
			end

			local promise = updateAsync(self, request):andThen(function(result, value, keyInfo)
				if result == "cancelled" then
					request.attempts = 0
					request.resolve("cancelled")
				elseif result == "succeed" then
					request.attempts = 0
					request.resolve(value, keyInfo)
				elseif result == "fail" then
					request.attempts = 0
					request.reject(value)
				elseif result == "retry" then
					retryRequest(request, value)
				else
					error("unreachable")
				end

				request.promise = nil
			end)

			if promise:getStatus() == Promise.Status.Started then
				request.promise = promise
			end
		end
	end

	local function updateGetAsync()
		for index = #self.getAsyncQueue, 1, -1 do
			local request = self.getAsyncQueue[index]

			if request.attempts == 0 then
				table.remove(self.getAsyncQueue, index)
			end
		end

		for _, request in self.getAsyncQueue do
			if self:getGetAsyncBudget() == 0 then
				break
			end

			if request.promise ~= nil then
				continue
			end

			local promise = getAsync(request):andThen(function(ok, value, keyInfo)
				if ok then
					request.attempts = 0
					request.resolve(value, keyInfo)
				else
					retryRequest(request, value)
				end

				request.promise = nil
			end)

			if promise:getStatus() == Promise.Status.Started then
				request.promise = promise
			end
		end
	end

	local function updateRemoveAsync()
		for index = #self.removeAsyncQueue, 1, -1 do
			local request = self.removeAsyncQueue[index]

			if request.attempts == 0 then
				table.remove(self.removeAsyncQueue, index)
			end
		end

		for _, request in self.removeAsyncQueue do
			if self:getRemoveAsyncBudget() == 0 then
				break
			end

			if request.promise ~= nil then
				continue
			end

			local promise = removeAsync(request):andThen(function(ok, message)
				if ok then
					request.attempts = 0
					request.resolve()
				else
					retryRequest(request, message)
				end

				request.promise = nil
			end)

			if promise:getStatus() == Promise.Status.Started then
				request.promise = promise
			end
		end
	end

	RunService.PostSimulation:Connect(function()
		updateUpdateAsync()
		updateGetAsync()
		updateRemoveAsync()
	end)
end

function Throttle:updateAsync(dataStore, key, transform, cancelOnGameClose, retryAttempts, retryDelay)
	return Promise.new(function(resolve, reject)
		table.insert(self.updateAsyncQueue, {
			dataStore = dataStore,
			key = key,
			transform = transform,
			attempts = retryAttempts,
			retryDelay = retryDelay,
			cancelOnGameClose = cancelOnGameClose,
			resolve = resolve,
			reject = reject,
		})
	end)
end

function Throttle:getAsync(dataStore, key)
	return Promise.new(function(resolve, reject)
		table.insert(self.getAsyncQueue, {
			dataStore = dataStore,
			key = key,
			attempts = GET_ASYNC_RETRY_ATTEMPTS,
			retryDelay = GET_ASYNC_RETRY_DELAY,
			resolve = resolve,
			reject = reject,
		})
	end)
end

function Throttle:removeAsync(dataStore, key)
	return Promise.new(function(resolve, reject)
		table.insert(self.removeAsyncQueue, {
			dataStore = dataStore,
			key = key,
			attempts = REMOVE_ASYNC_RETRY_ATTEMPTS,
			retryDelay = REMOVE_ASYNC_RETRY_DELAY,
			resolve = resolve,
			reject = reject,
		})
	end)
end

return Throttle
