local RunService = game:GetService("RunService")

local Promise = require(script.Parent.Parent.Promise)

local UPDATE_INTERVAL = 5 * 60

local AutoSave = {}
AutoSave.__index = AutoSave

function AutoSave.new(data)
	return setmetatable({
		documents = {},
		data = data,
		gameClosed = false,
		ongoingLoads = 0,
		ongoingRemoveLocks = 0,
	}, AutoSave)
end

function AutoSave:addDocument(document)
	table.insert(self.documents, document)
end

function AutoSave:removeDocument(document)
	local index = table.find(self.documents, document)

	table.remove(self.documents, index)
end

function AutoSave:finishLoad(document)
	if self.gameClosed then
		document:close()
	end

	self.ongoingLoads -= 1
end

function AutoSave:onGameClose()
	self.gameClosed = true
	self.data.throttle.gameClosed = true

	while #self.documents > 0 do
		self.documents[#self.documents]:close()
	end

	Promise.try(function()
		while self.ongoingLoads > 0 do
			task.wait()
		end
	end)
		:andThen(function()
			return Promise.allSettled({
				self.data:waitForOngoingSaves(),
				Promise.try(function()
					while self.ongoingRemoveLocks > 0 do
						task.wait()
					end
				end),
			})
		end)
		:await()
end

function AutoSave:start()
	local nextUpdateAt = os.clock() + UPDATE_INTERVAL
	RunService.Heartbeat:Connect(function()
		if os.clock() >= nextUpdateAt then
			for _, document in self.documents do
				document:save():catch(warn)
			end

			nextUpdateAt += UPDATE_INTERVAL
		end
	end)

	game:BindToClose(function()
		self:onGameClose()
	end)
end

return AutoSave
