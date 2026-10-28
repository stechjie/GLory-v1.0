import Foundation
import StoreKit

// Runs on the main actor, like the Godot adapter. Proofs stay in memory; StoreKit
// retains unfinished transactions across crashes until the server accepts them.
@MainActor @objc(GloryAppleBillingNative)
final class GloryAppleBillingNative: NSObject {
    @objc static let shared = GloryAppleBillingNative()
    private var nextID = 0
    private var replies: [Int: [String: Any]] = [:]
    private var started: [Int: Date] = [:]
    private var transactions: [String: StoreKit.Transaction] = [:]
    private var proofs: [String: [String: Any]] = [:]
    private var purchasing = false
    private var updates: Task<Void, Never>?

    override init() {
        super.init()
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self else { return }
                _ = self.remember(result)
            }
        }
    }

    private func request() -> Int {
        // Bound abandoned polls (e.g. closing the shop or a client timeout).
        let cutoff = Date().addingTimeInterval(-1800)
        for id in Array(started.keys) where started[id]! < cutoff {
            started.removeValue(forKey: id)
            replies.removeValue(forKey: id)
        }
        nextID += 1
        started[nextID] = Date()
        return nextID
    }

    @objc func poll(_ id: Int) -> String {
        let value = replies.removeValue(forKey: id)
        if value != nil { started.removeValue(forKey: id) }
        let data = try? JSONSerialization.data(withJSONObject: value ?? ["state": "pending"])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"state\":\"error\"}"
    }

    @objc func canMakePayments() -> Bool { AppStore.canMakePayments }

    @objc func beginQueryProducts(_ ids: String) -> Int {
        let id = request()
        Task {
            do {
                let products = try await Product.products(for: ids.split(separator: ",").map(String.init))
                replies[id] = ["state": "ok", "products": products.filter { $0.type == .consumable }.map {
                    ["id": $0.id, "price": $0.displayPrice]
                }]
            } catch {
                replies[id] = ["state": "error", "error": "apple_products_unavailable"]
            }
        }
        return id
    }

    private func remember(_ result: VerificationResult<StoreKit.Transaction>) -> [String: Any]? {
        guard case .verified(let tx) = result, tx.productType == .consumable,
              let order = tx.appAccountToken else { return nil }
        let key = String(tx.id)
        transactions[key] = tx
        let proof: [String: Any] = ["state": "purchased", "product": tx.productID,
            "order_id": order.uuidString.lowercased(), "transaction_id": key,
            "token": result.jwsRepresentation]
        proofs[key] = proof
        return proof
    }

    @objc func beginPurchase(_ productID: String, accountID: String, orderID: String) -> Int {
        let id = request()
        guard !purchasing else { replies[id] = ["state": "busy"]; return id }
        guard let order = UUID(uuidString: orderID), AppStore.canMakePayments else {
            replies[id] = ["state": "error", "error": "apple_purchase_unavailable"]
            return id
        }
        purchasing = true
        Task {
            defer { purchasing = false }
            do {
                guard let product = try await Product.products(for: [productID]).first,
                      product.type == .consumable else {
                    replies[id] = ["state": "error", "error": "apple_product_unavailable"]
                    return
                }
                switch try await product.purchase(options: [.appAccountToken(order)]) {
                case .success(let result):
                    if let proof = remember(result) {
                        replies[id] = ["state": "ok", "purchases": [proof]]
                    } else {
                        // Payment may have succeeded: keep it unfinished for recovery.
                        replies[id] = ["state": "timeout"]
                    }
                case .pending: replies[id] = ["state": "pending_payment"]
                case .userCancelled: replies[id] = ["state": "cancelled"]
                @unknown default: replies[id] = ["state": "timeout"]
                }
            } catch {
                // A network error after presenting payment is an uncertain result.
                replies[id] = ["state": "timeout"]
            }
        }
        return id
    }

    @objc func beginQueryPurchases() -> Int {
        let id = request()
        Task {
            for await result in StoreKit.Transaction.unfinished { _ = remember(result) }
            replies[id] = ["state": "ok", "purchases": Array(proofs.values)]
        }
        return id
    }

    // Call only after a successful authenticated server response for this order.
    @objc func beginFinishTransaction(_ transactionID: String) -> Int {
        let id = request()
        Task {
            guard let tx = transactions[transactionID] else {
                replies[id] = ["state": "error", "error": "apple_transaction_unknown"]
                return
            }
            await tx.finish()
            transactions.removeValue(forKey: transactionID)
            proofs.removeValue(forKey: transactionID)
            replies[id] = ["state": "ok"]
        }
        return id
    }

    @objc func shutdown() {
        updates?.cancel()
        updates = nil
        proofs.removeAll()
        transactions.removeAll()
        replies.removeAll()
        started.removeAll()
    }
}
