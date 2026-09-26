#import <Foundation/Foundation.h>

// Objective-C ABI of the @objc Swift singleton. Keep the C++ bridge independent
// of LiveKit's Swift-only SPM protocol imports (including RoomDelegate).
NS_ASSUME_NONNULL_BEGIN
@interface GloryVoiceNative : NSObject
+ (GloryVoiceNative *)shared;
- (BOOL)hasRecordPermission;
- (void)requestRecordPermission;
- (NSString *)joinRoom:(NSString *)url token:(NSString *)token listenOnly:(BOOL)listenOnly;
- (void)leaveRoom;
- (NSString *)setMicrophoneEnabled:(BOOL)enabled;
- (void)setParticipantVolume:(NSString *)identity volume:(double)volume;
- (NSString *)getStatus;
- (NSString *)getCapabilities;
@end
NS_ASSUME_NONNULL_END
