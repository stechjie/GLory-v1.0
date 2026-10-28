#import "GloryAppleBillingNative.h"
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/core/class_db.hpp>

using namespace godot;
static NSString *native_string(const String &s) {
    return [NSString stringWithUTF8String:s.utf8().get_data()];
}
static void on_main(void (^operation)(void)) {
    if ([NSThread isMainThread]) operation();
    else dispatch_sync(dispatch_get_main_queue(), operation);
}

class GloryAppleBillingIOS : public Object {
    GDCLASS(GloryAppleBillingIOS, Object)
protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("canMakePayments"), &GloryAppleBillingIOS::canMakePayments);
        ClassDB::bind_method(D_METHOD("beginQueryProducts", "ids"), &GloryAppleBillingIOS::beginQueryProducts);
        ClassDB::bind_method(D_METHOD("beginPurchase", "product", "account", "order"), &GloryAppleBillingIOS::beginPurchase);
        ClassDB::bind_method(D_METHOD("beginQueryPurchases"), &GloryAppleBillingIOS::beginQueryPurchases);
        ClassDB::bind_method(D_METHOD("beginFinishTransaction", "transaction"), &GloryAppleBillingIOS::beginFinishTransaction);
        ClassDB::bind_method(D_METHOD("poll", "request_id"), &GloryAppleBillingIOS::poll);
    }
public:
    bool canMakePayments() {
        __block bool value = false;
        on_main(^{ value = [[GloryAppleBillingNative shared] canMakePayments]; });
        return value;
    }
    int64_t beginQueryProducts(const String &ids) {
        NSString *value = native_string(ids);
        __block NSInteger request;
        on_main(^{ request = [[GloryAppleBillingNative shared] beginQueryProducts:value]; });
        return request;
    }
    int64_t beginPurchase(const String &product, const String &account, const String &order) {
        NSString *p = native_string(product), *a = native_string(account), *o = native_string(order);
        __block NSInteger request;
        on_main(^{ request = [[GloryAppleBillingNative shared] beginPurchase:p accountID:a orderID:o]; });
        return request;
    }
    int64_t beginQueryPurchases() {
        __block NSInteger request;
        on_main(^{ request = [[GloryAppleBillingNative shared] beginQueryPurchases]; });
        return request;
    }
    int64_t beginFinishTransaction(const String &transaction) {
        NSString *value = native_string(transaction);
        __block NSInteger request;
        on_main(^{ request = [[GloryAppleBillingNative shared] beginFinishTransaction:value]; });
        return request;
    }
    String poll(int64_t request_id) {
        __block NSString *value;
        on_main(^{ value = [[GloryAppleBillingNative shared] poll:request_id]; });
        return String::utf8(value.UTF8String);
    }
};

static GloryAppleBillingIOS *billing = nullptr;
void initialize_apple_billing() {
    GDREGISTER_ABSTRACT_CLASS(GloryAppleBillingIOS);
    billing = memnew(GloryAppleBillingIOS);
    Engine::get_singleton()->register_singleton("GloryAppleBilling", billing);
    on_main(^{ [GloryAppleBillingNative shared]; });
}
void terminate_apple_billing() {
    if (!billing) return;
    Engine::get_singleton()->unregister_singleton("GloryAppleBilling");
    on_main(^{ [[GloryAppleBillingNative shared] shutdown]; });
    memdelete(billing);
    billing = nullptr;
}
