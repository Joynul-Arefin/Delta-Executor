local function copyDeep(value)
	if typeof(value) ~= "table" then
		return value
	end

	local new = table.clone(value)

	for k, v in value do
		if type(v) == "table" then
			new[k] = copyDeep(v)
		end
	end

	return new
end

return copyDeep
