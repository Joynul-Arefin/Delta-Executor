local MarketplaceServiceMock = {}
MarketplaceServiceMock.__index = MarketplaceServiceMock

function MarketplaceServiceMock.new()
	return setmetatable({
		nextPurchaseId = 1,
	}, MarketplaceServiceMock)
end

function MarketplaceServiceMock:onProductPurchased(userId, productId, existingPurchaseId: string?)
	if self.ProcessReceipt == nil then
		error("ProcessReceipt callback wasn't set")
	end

	local purchaseId = existingPurchaseId

	if purchaseId == nil then
		purchaseId = tostring(self.nextPurchaseId)
		self.nextPurchaseId += 1
	end

	local productPurchaseDecision = self.ProcessReceipt({
		PurchaseId = purchaseId,
		PlayerId = userId,
		ProductId = productId,
	})

	return productPurchaseDecision, purchaseId
end

return MarketplaceServiceMock
