#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
BOOL PDProbeCanPresent(void);

@interface PDSceneSession : NSObject
@property (nonatomic, strong, readonly, nullable) UIView *hostedView;
@property (nonatomic, readonly) CGSize sourceSize;
@property (nonatomic, readonly) BOOL remainsForeground;
+ (BOOL)cancelPendingWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(cancelPending());
+ (nullable instancetype)captureInView:(UIView *)view
                   onOwnershipChange:(dispatch_block_t)handler
                               error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(capture(in:onOwnershipChange:));
- (BOOL)updateFrame:(CGRect)frame error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(update(frame:));
- (BOOL)activateWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(activate());
- (BOOL)requestFocusWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(requestFocus());
- (BOOL)finishWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(finish());
@end

// Own containment and orientation observation only; native window is borrowed.
@interface PDOverlayLease : NSObject
+ (BOOL)finishPendingWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(finishPending());
@property (nonatomic, readonly) BOOL valid;
+ (nullable instancetype)attachController:(UIViewController *)controller
                          onInvalidation:(dispatch_block_t)handler
                                  error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(attach(controller:onInvalidation:));
- (BOOL)finishWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(finish());
@end
NS_ASSUME_NONNULL_END
