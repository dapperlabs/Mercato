import Foundation
import StoreKit

public typealias TransactionUpdate = ((Transaction, String) async -> ())

public class Mercato {
	
	private var purchaseController = PurchaseController()
	private var productService = ProductService()
    
    private var updateListenerTask: Task<(), Never>? = nil

    public init() {}
    
    fileprivate func listenForUnfinishedTransactions(updateBlock: @escaping TransactionUpdate) {
        let task = Task.detached
        {
            for await result in Transaction.unfinished
            {
                do {
                    let transaction = try checkVerified(result)
                    await updateBlock(transaction, result.jwsRepresentation)
                } catch {
                    print("Transaction failed verification")
                }
            }
        }
        
        self.updateListenerTask = task
    }
    
    fileprivate func listenForTransactionUpdates(updateBlock: @escaping TransactionUpdate) {
        let task = Task.detached
        {
            for await result in Transaction.updates
            {
                do {
                    let transaction = try checkVerified(result)
                    await updateBlock(transaction, result.jwsRepresentation)
                } catch {
                    print("Transaction failed verification")
                }
            }
        }
        
        self.updateListenerTask = task
    }
	
    //TODO: throw an error if productId are invalid
    public func retrieveProducts(productIds: Set<String>) async throws -> [Product]
    {
        try await productService.retrieveProducts(productIds: productIds)
    }
    
    public func retrieveProduct(productId: String) async throws -> Product
    {
        if let product = try await productService.retrieveProducts(productIds: Set<String>([productId])).first {
            return product
        } else {
            throw MercatoError.storeKit(error: StoreKitError.notAvailableInStorefront)
        }
    }
	
	@discardableResult
	public func purchase(product: Product, quantity: Int = 1, finishAutomatically: Bool = true, appAccountToken: UUID? = nil, simulatesAskToBuyInSandbox: Bool = false) async throws -> Purchase
	{
		try await purchaseController.makePurchase(product: product, quantity: quantity, finishAutomatically: finishAutomatically, appAccountToken: appAccountToken, simulatesAskToBuyInSandbox: simulatesAskToBuyInSandbox)
	}
	
	@available(watchOS, unavailable)
	@available(tvOS, unavailable)
	func beginRefundProcess(for productID: String, in scene: UIWindowScene) async throws
	{
		guard case .verified(let transaction) = await Transaction.latest(for: productID) else { throw MercatoError.failedVerification }
		
		do {
			let status = try await transaction.beginRefundRequest(in: scene)
			
			switch status
			{
			case .userCancelled:
				throw MercatoError.userCancelledRefundProcess
			case .success:
				break
			@unknown default:
				throw MercatoError.genericError
			}
		} catch {
			//TODO: return a specific error
			throw error
		}
	}
    
    deinit {
        updateListenerTask?.cancel()
    }
}

extension Mercato
{
	fileprivate static let shared: Mercato = .init()
	
    public static func listenForUnfinishedTransactions(updateBlock: @escaping TransactionUpdate)
    {
        shared.listenForUnfinishedTransactions(updateBlock: updateBlock)
    }
    
    /// Any unfinished transactions will be emitted when you first iterate the sequence.
    public static func listenForTransactionUpdates(updateBlock: @escaping TransactionUpdate)
    {
        shared.listenForTransactionUpdates(updateBlock: updateBlock)
    }

	public static func retrieveProducts(productIds: Set<String>) async throws -> [Product]
	{
		try await shared.retrieveProducts(productIds: productIds)
	}

    public static func retrieveProduct(productId: String) async throws -> Product
    {
        try await shared.retrieveProduct(productId: productId)
    }

	@discardableResult
	public static func purchase(product: Product,
								quantity: Int = 1,
								finishAutomatically: Bool = true,
								appAccountToken: UUID? = nil,
								simulatesAskToBuyInSandbox: Bool = false) async throws -> Purchase
	{
		try await shared.purchase(product: product,
								  quantity: quantity,
								  finishAutomatically: finishAutomatically,
								  appAccountToken: appAccountToken,
								  simulatesAskToBuyInSandbox: simulatesAskToBuyInSandbox)
	}
	
	public static func restorePurchases() async throws
	{
		try await AppStore.sync()
	}
	
	@available(watchOS, unavailable)
	@available(tvOS, unavailable)
	public static func beginRefundProcess(for product: Product, in scene: UIWindowScene) async throws
	{
		try await shared.beginRefundProcess(for: product.id, in: scene)
	}
	
	@available(watchOS, unavailable)
	@available(tvOS, unavailable)
	public static func beginRefundProcess(for productID: String, in scene: UIWindowScene) async throws
	{
		try await shared.beginRefundProcess(for: productID, in: scene)
	}
	
	@available(iOS 15.0, *)
	@available(macOS, unavailable)
	@available(watchOS, unavailable)
	@available(tvOS, unavailable)
	public static func showManageSubscriptions(in scene: UIWindowScene) async throws
	{
		try await AppStore.showManageSubscriptions(in: scene)
	}
	
	public static func activeSubscriptions(onlyRenewable: Bool = true) async throws -> [Transaction]
	{
		var txs: [Transaction] = []
		
		for await result in Transaction.currentEntitlements
		{
			do {
				let transaction = try checkVerified(result)
				
				if transaction.productType == .autoRenewable ||
					(!onlyRenewable && transaction.productType == .nonRenewable)
				{
                    txs.append(transaction)
				}
			} catch {
				throw error
			}
		}
		
		return Array(txs)
	}
    
    public static func activeSubscriptionIds(onlyRenewable: Bool = true) async throws -> [String]
    {
        return try await activeSubscriptions(onlyRenewable: onlyRenewable).map { $0.productID}
    }
    
    public static func fetchLatestTransaction(for productId: String) async throws -> (transaction: Transaction, jwsRepresentation: String) {
        let result = await Transaction.latest(for: productId)
        guard let result else {
            throw MercatoError.failedVerification
        }
        switch result {
        case .verified(let verifiedTransaction):
            return (transaction: verifiedTransaction, jwsRepresentation: result.jwsRepresentation)
        case .unverified:
            throw MercatoError.failedVerification
        }
    }
}


func checkVerified<T>(_ result: VerificationResult<T>) throws -> T
{
	switch result
	{
	case .verified(let safe):
		return safe
	case .unverified:
		throw MercatoError.failedVerification
	}
}
