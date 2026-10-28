"""Exercise production StoreKit task logic with deterministic SDK doubles.

No Apple account, network, or payment is used. The production file also compiles
against the real iPhoneOS SDK through native/glory_voice_ios/build.py.
"""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
STUBS = r'''
import Foundation
struct FakeError: Error {}
enum VerificationResult<T> {
    case verified(T), unverified(T)
    var jwsRepresentation: String { "signed-proof" }
}
enum AppStore { static var canMakePayments = true }
enum StoreKit {
    struct Transaction {
        let id: UInt64
        var productID = "diamond_pack_1"
        var productType = Product.Kind.consumable
        var appAccountToken: UUID? = UUID(uuidString: "33333333-3333-3333-3333-333333333333")
        static var finished: [UInt64] = []
        static var pending: [VerificationResult<Transaction>] = []
        static var listener: AsyncStream<VerificationResult<Transaction>>.Continuation?
        static var updates: AsyncStream<VerificationResult<Transaction>> {
            AsyncStream { listener = $0 }
        }
        static var unfinished: AsyncStream<VerificationResult<Transaction>> {
            AsyncStream { stream in
                for item in pending { stream.yield(item) }
                stream.finish()
            }
        }
        func finish() async { Self.finished.append(id) }
    }
}
struct Product {
    enum Kind { case consumable, nonConsumable }
    enum PurchaseOption: Hashable { case appAccountToken(UUID) }
    enum PurchaseResult { case success(VerificationResult<StoreKit.Transaction>), pending, userCancelled }
    var id = "diamond_pack_1"
    var displayPrice = "RM 5.00"
    var type = Kind.consumable
    static var offered = [Product()]
    static var failProducts = false
    static var failPurchase = false
    static var result = PurchaseResult.success(.verified(StoreKit.Transaction(id: 42)))
    static var options: Set<PurchaseOption> = []
    static func products(for ids: [String]) async throws -> [Product] {
        if failProducts { throw FakeError() }
        return offered.filter { ids.contains($0.id) }
    }
    func purchase(options: Set<PurchaseOption>) async throws -> PurchaseResult {
        Self.options = options
        if Self.failPurchase { throw FakeError() }
        return Self.result
    }
}
'''
TESTS = r'''
@main struct BillingTests {
    @MainActor static func reply(_ bridge: GloryAppleBillingNative, _ id: Int) async -> [String: Any] {
        for _ in 0..<10000 {
            let raw = bridge.poll(id).data(using: .utf8)!
            let result = try! JSONSerialization.jsonObject(with: raw) as! [String: Any]
            if result["state"] as? String != "pending" { return result }
            await Task.yield()
        }
        fatalError("poll never completed")
    }
    @MainActor static func main() async {
        let bridge = GloryAppleBillingNative.shared
        let order = "33333333-3333-3333-3333-333333333333"
        var result = await reply(bridge, bridge.beginQueryProducts("diamond_pack_1"))
        let products = result["products"] as! [[String: String]]
        assert(products.first?["price"] == "RM 5.00")
        Product.offered[0].type = .nonConsumable
        result = await reply(bridge, bridge.beginQueryProducts("diamond_pack_1"))
        assert((result["products"] as! [[String: String]]).isEmpty)
        Product.offered[0].type = .consumable
        Product.failProducts = true
        result = await reply(bridge, bridge.beginQueryProducts("diamond_pack_1"))
        assert(result["state"] as? String == "error")
        Product.failProducts = false
        AppStore.canMakePayments = false
        result = await reply(bridge, bridge.beginPurchase("diamond_pack_1", accountID: "", orderID: order))
        assert(result["state"] as? String == "error")
        AppStore.canMakePayments = true
        result = await reply(bridge, bridge.beginPurchase("diamond_pack_1", accountID: "", orderID: "bad-order"))
        assert(result["state"] as? String == "error")
        let purchaseID = bridge.beginPurchase("diamond_pack_1", accountID: "", orderID: order)
        let busyID = bridge.beginPurchase("diamond_pack_1", accountID: "", orderID: order)
        result = await reply(bridge, busyID)
        assert(result["state"] as? String == "busy")
        result = await reply(bridge, purchaseID)
        assert(Product.options == [.appAccountToken(UUID(uuidString: order)!)])
        let proof = (result["purchases"] as! [[String: Any]])[0]
        assert(proof["order_id"] as? String == order)
        assert(proof["transaction_id"] as? String == "42")
        assert(proof["token"] as? String == "signed-proof")
        assert(StoreKit.Transaction.finished.isEmpty, "Purchase must not finish before server credit")
        StoreKit.Transaction.pending = [.verified(StoreKit.Transaction(id: 42)),
            .unverified(StoreKit.Transaction(id: 43)), .verified(StoreKit.Transaction(id: 44, appAccountToken: nil))]
        result = await reply(bridge, bridge.beginQueryPurchases())
        assert((result["purchases"] as! [[String: Any]]).count == 1)
        assert(StoreKit.Transaction.finished.isEmpty)
        Product.result = .pending
        result = await reply(bridge, bridge.beginPurchase("diamond_pack_1", accountID: "", orderID: order))
        assert(result["state"] as? String == "pending_payment")
        Product.result = .userCancelled
        result = await reply(bridge, bridge.beginPurchase("diamond_pack_1", accountID: "", orderID: order))
        assert(result["state"] as? String == "cancelled")
        Product.result = .success(.unverified(StoreKit.Transaction(id: 45)))
        result = await reply(bridge, bridge.beginPurchase("diamond_pack_1", accountID: "", orderID: order))
        assert(result["state"] as? String == "timeout")
        Product.failPurchase = true
        result = await reply(bridge, bridge.beginPurchase("diamond_pack_1", accountID: "", orderID: order))
        assert(result["state"] as? String == "timeout", "Unknown payment outcome must remain processing")
        Product.failPurchase = false
        StoreKit.Transaction.listener!.yield(.verified(StoreKit.Transaction(id: 46)))
        for _ in 0..<100 { await Task.yield() }
        StoreKit.Transaction.pending = []
        result = await reply(bridge, bridge.beginQueryPurchases())
        assert((result["purchases"] as! [[String: Any]]).count == 2, "Foreground updates must be available for recovery")
        result = await reply(bridge, bridge.beginFinishTransaction("42"))
        assert(result["state"] as? String == "ok" && StoreKit.Transaction.finished == [42])
        result = await reply(bridge, bridge.beginQueryPurchases())
        assert((result["purchases"] as! [[String: Any]]).count == 1)
        result = await reply(bridge, bridge.beginFinishTransaction("unknown"))
        assert(result["state"] as? String == "error" && StoreKit.Transaction.finished == [42])
        bridge.shutdown()
        print("PASS StoreKit production tasks: prices, restrictions, order token, busy, pending, cancellation, unverified, network uncertainty, unfinished recovery, foreground updates, finish")
    }
}
'''

class IOSBillingTests(unittest.TestCase):
    def test_production_storekit_tasks(self):
        source = (ROOT / 'native/glory_voice_ios/GloryAppleBilling.swift').read_text()
        source = source.replace('import StoreKit', '')
        source = source.replace('@objc(GloryAppleBillingNative)', '').replace('@objc ', '')
        with tempfile.TemporaryDirectory(prefix='glory-ios-billing-tests-') as directory:
            swift = pathlib.Path(directory) / 'BillingTests.swift'
            binary = pathlib.Path(directory) / 'tests'
            swift.write_text(STUBS + source + TESTS)
            subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', str(swift), '-o', str(binary)], check=True, timeout=120)
            subprocess.run([str(binary)], check=True, timeout=20)

if __name__ == '__main__':
    unittest.main()
