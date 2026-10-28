#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface GloryAppleBillingNative : NSObject
+ (GloryAppleBillingNative *)shared;
- (BOOL)canMakePayments;
- (NSInteger)beginQueryProducts:(NSString *)ids;
- (NSInteger)beginPurchase:(NSString *)productID accountID:(NSString *)accountID orderID:(NSString *)orderID;
- (NSInteger)beginQueryPurchases;
- (NSInteger)beginFinishTransaction:(NSString *)transactionID;
- (NSString *)poll:(NSInteger)requestID;
- (void)shutdown;
@end
NS_ASSUME_NONNULL_END
