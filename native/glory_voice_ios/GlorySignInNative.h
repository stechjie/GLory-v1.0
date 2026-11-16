#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface GlorySignInNative : NSObject
+ (GlorySignInNative *)shared;
- (BOOL)isGoogleAvailable;
- (BOOL)isAppleAvailable;
- (NSInteger)beginGoogleSignIn:(NSString *)webClientID nonce:(NSString *)nonce;
- (NSInteger)beginAppleSignIn:(NSString *)nonce;
- (NSString *)pollSignIn:(NSInteger)requestID;
- (void)cancelSignIn:(NSInteger)requestID;
- (BOOL)handleURL:(NSURL *)url;
- (void)shutdown;
@end
NS_ASSUME_NONNULL_END
