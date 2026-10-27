#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Fan modes shared by the app and the privileged helper.
/// 0 auto, 1 cool, 2 max.
@protocol MonitoringHelperXPC <NSObject>
- (void)setFanMode:(NSInteger)mode
      floorPercent:(NSInteger)floor
autoReturnWhenCool:(BOOL)autoReturn
             reply:(void (^)(NSString *_Nullable error))reply;
- (void)setChargingEnabled:(BOOL)enabled
                      reply:(void (^)(NSString *_Nullable error))reply;
- (void)setChargeLimitPercent:(NSInteger)percent
                         reply:(void (^)(NSString *_Nullable error))reply;
- (void)setLowLagEnabled:(BOOL)enabled
                    reply:(void (^)(BOOL active, NSString *_Nullable error))reply;
- (void)setClamshellSleepDisabled:(BOOL)disabled
                             reply:(void (^)(NSString *_Nullable error))reply;
- (void)restoreAllWithReply:(void (^)(BOOL fansAuto, NSString *_Nullable error))reply;
- (void)versionWithReply:(void (^)(NSString *version))reply;
- (void)relaunchIfVersionMismatches:(NSString *)expected
                               reply:(void (^)(BOOL relaunching))reply;
@end

NS_ASSUME_NONNULL_END
