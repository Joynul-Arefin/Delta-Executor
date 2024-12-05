local function noYield(callback)
	for _ in
		function()
			callback()
		end
	do
		break
	end
end

return noYield
