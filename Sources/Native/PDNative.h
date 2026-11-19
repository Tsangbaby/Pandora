#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

BOOL PDProbeCanPresent(void);

@interface PDSystemWindow : UIWindow
@end

@interface PDSceneSession : NSObject
@property (nonatomic, strong, readonly, nullable) UIView *hostedView;
@property (nonatomic, readonly) CGSize sourceSize;
@property (nonatomic, readonly) BOOL remainsForeground;
+ (nullable instancetype)captureWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(capture());
- (BOOL)requestFocusWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(requestFocus());
- (void)invalidate;
@end

@interface PDOverlayLease : NSObject
+ (nullable instancetype)attachWindow:(UIWindow *)window
                 onOrientationChange:(dispatch_block_t)handler
                               error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(attach(window:onOrientationChange:));
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
