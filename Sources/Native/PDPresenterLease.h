#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

NS_ASSUME_NONNULL_BEGIN
// Exact target-typed ivar access; never KVC, lazy getters or guessed offsets.
FOUNDATION_EXPORT id _Nullable PDLeaseObject(id _Nullable object, const char *name, const char *encoding);
FOUNDATION_EXPORT BOOL PDLeaseFlag(id _Nullable object, const char *name, BOOL *value);
FOUNDATION_EXPORT NSArray * _Nullable PDLeaseMembers(id _Nullable collection);

@interface PDPresenterLease : NSObject
@property (nonatomic, strong, readonly, nullable) id presenter;
@property (nonatomic, readonly) BOOL readyForInput;
@property (nonatomic, readonly) BOOL ended;
+ (nullable instancetype)stageWithManager:(id)manager owner:(id)owner
                         nativePresenter:(id)nativePresenter
                                onChange:(dispatch_block_t)handler
                                   error:(NSError * _Nullable * _Nullable)error;
- (BOOL)activateWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)performOperation:(BOOL (^)(void))operation error:(NSError * _Nullable * _Nullable)error;
- (BOOL)cancelWithError:(NSError * _Nullable * _Nullable)error;
+ (BOOL)cancelOutstandingWithError:(NSError * _Nullable * _Nullable)error;
@end

#if defined(PD_LEASE_TESTING)
// Environment signal only: tests compile the same lease, not Apple internals.
void PDLeaseTestNativeChange(id owner, id presenter);
void PDLeaseTestInvokeOwnerMutation(NSUInteger kind, id owner, id presenter, void (*original)(id,SEL,id));
#endif
NS_ASSUME_NONNULL_END
