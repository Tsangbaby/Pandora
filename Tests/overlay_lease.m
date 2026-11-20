// Foundation environment doubles, NOT UIKit/WindowServer evidence. The driver
// includes the EXACT final PDOverlayLease section of PDNative.m, byte-for-byte.
// No lease state/implementation, transaction, or ABI checker is substituted.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CGAffineTransform.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import "PDABI.h"
#include <stdbool.h>
#include <stdio.h>

// Foundation supplies the CoreGraphics scalar declarations. Supply only this
// scalar helper so the executable links Foundation alone; geometry is not tested.
bool CGAffineTransformIsIdentity(CGAffineTransform t) {
    return t.a == 1 && t.b == 0 && t.c == 0 && t.d == 1 && t.tx == 0 && t.ty == 0;
}

@class UIWindow, UIViewController;
static NSUInteger checks, failures, snapshotReads, presenterCancels;
static NSUInteger hiddenWrites, keyWrites, rootWrites, borrowedViewWrites;
static NSUInteger windowInvalidations, containerInvalidations, nativeInvalidations;
static NSUInteger borrowedRemovals;
static BOOL recordingEffects;
static NSString *caseName;
static dispatch_block_t duringObserverInit;

static void PDCheck(BOOL pass, const char *message, int line) {
    checks++;
    if (!pass) {
        failures++;
        fprintf(stderr, "OVERLAY FAIL %s:%d: %s\n", caseName.UTF8String, line, message);
    }
}
#define CHECK(expression, message) PDCheck((BOOL)(expression), (message), __LINE__)
static void inject(const char *operation) {
    fprintf(stderr, "INJECT %s: %s (one-shot exception)\n", caseName.UTF8String, operation);
    @throw [NSException exceptionWithName:@"PDInjected" reason:@(operation) userInfo:nil];
}

@interface UIView : NSObject {
@protected
    __weak UIView *_superview;
    NSMutableArray<UIView *> *_subviews;
}
@property(nonatomic) CGRect frame;
@property(nonatomic) CGRect bounds;
@property(nonatomic) NSUInteger autoresizingMask;
@property(nonatomic) CGAffineTransform transform;
@property(nonatomic, weak, readonly) UIWindow *window;
@property(nonatomic, weak, readonly) UIView *superview;
@property(nonatomic, copy, readonly) NSArray<UIView *> *subviews;
@property(nonatomic) BOOL borrowed;
@property(nonatomic) BOOL container;
@property(nonatomic) NSUInteger removeThrows, removeCalls, addThrowsAfter;
- (void)addSubview:(UIView *)view;
- (void)removeFromSuperview;
- (void)invalidate;
@end
static const NSUInteger UIViewAutoresizingFlexibleWidth = 1U << 1;
static const NSUInteger UIViewAutoresizingFlexibleHeight = 1U << 4;

@implementation UIView
- (instancetype)init {
    if ((self = [super init])) {
        _subviews = [NSMutableArray new];
        _frame = _bounds = (CGRect){{0, 0}, {320, 480}};
        _transform = (CGAffineTransform){1, 0, 0, 1, 0, 0};
    }
    return self;
}
- (UIView *)superview { return _superview; }
- (NSArray<UIView *> *)subviews { return [_subviews copy]; }
- (UIWindow *)window { return _superview.window; }
- (void)addSubview:(UIView *)view {
    if (view.superview) [view removeFromSuperview];
    [_subviews addObject:view]; view->_superview = self;
    if (self.addThrowsAfter) { self.addThrowsAfter--; inject("addSubview AFTER mutation"); }
}
- (void)removeFromSuperview {
    self.removeCalls++;
    if (recordingEffects && self.borrowed) borrowedRemovals++;
    if (self.removeThrows) { self.removeThrows--; inject("own view removeFromSuperview"); }
    UIView *parent = _superview;
    if (parent) [parent->_subviews removeObjectIdenticalTo:self];
    _superview = nil;
}
- (void)invalidate {
    if (self.container) containerInvalidations++;
    else if (self.borrowed) nativeInvalidations++;
}
@end

@interface UIViewController : NSObject {
    __weak UIViewController *_parentViewController;
    NSMutableArray<UIViewController *> *_children;
    UIView *_view;
}
@property(nonatomic, strong) UIView *view;
@property(nonatomic, strong, readonly) UIView *viewIfLoaded;
@property(nonatomic, weak, readonly) UIViewController *parentViewController;
@property(nonatomic, copy, readonly) NSArray<UIViewController *> *children;
@property(nonatomic) BOOL borrowed;
@property(nonatomic) NSUInteger addThrowsAfter, removeParentThrows;
@property(nonatomic) NSUInteger addCalls, didMoveCalls, willMoveCalls, removeParentCalls;
@property(nonatomic, copy) dispatch_block_t duringAddChild;
- (void)addChildViewController:(UIViewController *)controller;
- (void)didMoveToParentViewController:(UIViewController *)parent;
- (void)willMoveToParentViewController:(UIViewController *)parent;
- (void)removeFromParentViewController;
- (void)invalidate;
@end
@implementation UIViewController
- (instancetype)init {
    if ((self = [super init])) { _view = [UIView new]; _children = [NSMutableArray new]; }
    return self;
}
- (UIView *)view { return _view; }
- (void)setView:(UIView *)view {
    if (recordingEffects && self.borrowed) borrowedViewWrites++;
    _view = view;
}
- (UIView *)viewIfLoaded { return _view; }
- (UIViewController *)parentViewController { return _parentViewController; }
- (NSArray<UIViewController *> *)children { return [_children copy]; }
- (void)addChildViewController:(UIViewController *)controller {
    self.addCalls++;
    [_children addObject:controller]; controller->_parentViewController = self;
    dispatch_block_t hook = self.duringAddChild; self.duringAddChild = nil;
    if (hook) hook();
    if (self.addThrowsAfter) { self.addThrowsAfter--; inject("addChild AFTER mutation"); }
}
- (void)didMoveToParentViewController:(UIViewController *)parent {
    (void)parent; self.didMoveCalls++;
}
- (void)willMoveToParentViewController:(UIViewController *)parent {
    (void)parent; self.willMoveCalls++;
}
- (void)removeFromParentViewController {
    self.removeParentCalls++;
    if (recordingEffects && self.borrowed) borrowedRemovals++;
    if (self.removeParentThrows) { self.removeParentThrows--; inject("removeFromParent"); }
    UIViewController *parent = _parentViewController;
    if (parent) [parent->_children removeObjectIdenticalTo:self];
    _parentViewController = nil;
}
- (void)invalidate { if (self.borrowed) nativeInvalidations++; }
@end

@interface UIWindow : UIView {
    BOOL _hidden, _keyWindow;
    UIViewController *_rootViewController;
}
@property(nonatomic) BOOL hidden;
@property(nonatomic, getter=isKeyWindow) BOOL keyWindow;
@property(nonatomic, strong) UIViewController *rootViewController;
- (void)makeKeyWindow;
- (void)makeKeyAndVisible;
- (void)resignKeyWindow;
@end
@implementation UIWindow
- (UIWindow *)window { return self; }
- (BOOL)hidden { return _hidden; }
- (void)setHidden:(BOOL)value { if (recordingEffects) hiddenWrites++; _hidden = value; }
- (BOOL)isKeyWindow { return _keyWindow; }
- (void)setKeyWindow:(BOOL)value { if (recordingEffects) keyWrites++; _keyWindow = value; }
- (UIViewController *)rootViewController { return _rootViewController; }
- (void)setRootViewController:(UIViewController *)value {
    if (recordingEffects) rootWrites++;
    _rootViewController = value;
}
- (void)makeKeyWindow { self.keyWindow = YES; }
- (void)makeKeyAndVisible { self.hidden = NO; self.keyWindow = YES; }
- (void)resignKeyWindow { self.keyWindow = NO; }
- (void)invalidate { windowInvalidations++; }
@end

@interface PDBorrowedResource : NSObject
- (void)invalidate;
@end
@implementation PDBorrowedResource
- (void)invalidate { nativeInvalidations++; }
@end

@interface FBSOrientationObserver : NSObject
@property(nonatomic) NSInteger activeInterfaceOrientation;
@property(nonatomic, copy) void (^handler)(id);
@property(nonatomic) NSUInteger invalidateThrows, invalidateCalls;
@property(nonatomic) BOOL invalidated;
- (void)invalidate;
@end
static FBSOrientationObserver *lastObserver;
@implementation FBSOrientationObserver
- (instancetype)init {
    if ((self = [super init])) {
        _activeInterfaceOrientation = 1;
        lastObserver = self;
        dispatch_block_t hook = duringObserverInit; duringObserverInit = nil;
        if (hook) hook(); // Earliest observer setup, before assignment to the lease.
    }
    return self;
}
- (void)invalidate {
    self.invalidateCalls++;
    if (self.invalidateThrows) { self.invalidateThrows--; inject("observer.invalidate"); }
    self.invalidated = YES; self.handler = nil;
}
@end

// Minimal public declarations matching PDNative.h, minus nullability/Swift names.
// The real header imports UIKit and must NOT be imported into this executable.
typedef NS_ENUM(NSInteger, PDProbeTarget) {
    PDProbeTargetNotes,
    PDProbeTargetFiles,
};
@interface PDOverlayLease : NSObject
+ (BOOL)finishPendingWithError:(NSError **)error;
@property (nonatomic, readonly) BOOL valid;
@property (nonatomic, readonly) BOOL allowsDeferredFinish;
+ (instancetype)attachController:(UIViewController *)controller target:(PDProbeTarget)target
                 onInvalidation:(dispatch_block_t)handler error:(NSError **)error;
- (BOOL)finishWithError:(NSError **)error;
@end
@interface PDOverlayLease (SceneBinding)
- (BOOL)matchesSnapshot:(NSDictionary *)snapshot;
@end
@interface PDPresenterLease : NSObject
+ (BOOL)cancelOutstandingWithError:(NSError **)error;
@end
@implementation PDPresenterLease
+ (BOOL)cancelOutstandingWithError:(NSError **)error {
    (void)error; presenterCancels++; return YES;
}
@end

static UIWindow *nativeWindow;
static UIViewController *nativeParent, *borrowedChild;
static UIView *nativeRoot, *borrowedContainer;
static PDBorrowedResource *nativePresenter, *nativeManager, *nativeOwner;
static BOOL PDError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"PDOverlayFixture" code:1
                                     userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static BOOL canPresent = YES;
static PDProbeTarget foregroundTarget;
static NSObject *nativeScene;
static NSString *nativeIdentifier;
static BOOL PDBoundSceneIsCurrent(PDProbeTarget target, NSString *identifier, id scene) {
    return canPresent && target == foregroundTarget && scene && scene == nativeScene &&
        [identifier isEqualToString:nativeIdentifier];
}
static NSDictionary *PDNativeSnapshot(PDProbeTarget target, NSError **error) {
    snapshotReads++;
    if (!PDBoundSceneIsCurrent(target, nativeIdentifier, nativeScene)) {
        PDError(error, @"Target has no current scene"); return nil;
    }
    return @{ @"scene":nativeScene, @"identifier":nativeIdentifier,
              @"parent":nativeParent, @"root":nativeRoot, @"window":nativeWindow,
              @"container":borrowedContainer, @"nativeView":borrowedChild.view,
              @"native":nativePresenter, @"manager":nativeManager, @"owner":nativeOwner };
}

// The driver writes this include from the unique production class extension to
// EOF. No copied/reimplemented overlay, testing macro, or runtime patch is used.
#include "overlay-lease-under-test.inc"

static BOOL nativeUntouched(void) {
    return !hiddenWrites && !keyWrites && !rootWrites && !borrowedViewWrites &&
        !windowInvalidations && !containerInvalidations && !nativeInvalidations &&
        !borrowedRemovals && !nativeWindow.hidden && nativeWindow.isKeyWindow &&
        nativeWindow.rootViewController == nativeParent && nativeParent.viewIfLoaded == nativeRoot &&
        nativeRoot.superview == nativeWindow && nativeRoot.window == nativeWindow &&
        borrowedChild.parentViewController == nativeParent && borrowedChild.view.superview == nativeRoot &&
        borrowedContainer.superview == nativeRoot;
}
static BOOL cleaned(UIViewController *own) {
    return own && !own.parentViewController && !own.viewIfLoaded.superview &&
        nativeParent.children.count == 1 && nativeParent.children.firstObject == borrowedChild &&
        nativeRoot.subviews.count == 2 && [nativeRoot.subviews containsObject:borrowedChild.view] &&
        [nativeRoot.subviews containsObject:borrowedContainer] && nativeUntouched();
}
static void fresh(void) {
    NSError *error = nil;
    if (![PDOverlayLease finishPendingWithError:&error] || (nativeWindow && !nativeUntouched()))
        [NSException raise:@"PDHarnessCleanup" format:@"prior cleanup/native invariant: %@", error];
    recordingEffects = NO; canPresent = YES; foregroundTarget = PDProbeTargetNotes;
    nativeScene = [NSObject new]; nativeIdentifier = @"sceneID:overlay-fixture";
    snapshotReads = presenterCancels = 0; lastObserver = nil; duringObserverInit = nil;
    nativeWindow = [UIWindow new]; nativeWindow.borrowed = YES;
    nativeParent = [UIViewController new]; nativeParent.borrowed = YES;
    nativeRoot = nativeParent.view; nativeRoot.borrowed = YES;
    borrowedChild = [UIViewController new]; borrowedChild.borrowed = YES;
    borrowedChild.view.borrowed = YES;
    borrowedContainer = [UIView new]; borrowedContainer.borrowed = YES; borrowedContainer.container = YES;
    nativePresenter = [PDBorrowedResource new]; nativeManager = [PDBorrowedResource new];
    nativeOwner = [PDBorrowedResource new];
    nativeWindow.rootViewController = nativeParent; nativeWindow.hidden = NO; nativeWindow.keyWindow = YES;
    [nativeWindow addSubview:nativeRoot];
    [nativeParent addChildViewController:borrowedChild];
    [nativeRoot addSubview:borrowedChild.view]; [nativeRoot addSubview:borrowedContainer];
    recordingEffects = YES;
}
static PDOverlayLease *attach(UIViewController *own, NSError **error) {
    return [PDOverlayLease attachController:own target:PDProbeTargetNotes onInvalidation:^{} error:error];
}
static BOOL attachRefused(void) {
    NSUInteger before = snapshotReads; NSError *error = nil;
    PDOverlayLease *unexpected = attach([UIViewController new], &error);
    return !unexpected && error && snapshotReads == before;
}

static void testNormal(void) {
    fresh(); UIViewController *own = [UIViewController new]; NSError *error = nil;
    PDOverlayLease *lease = attach(own, &error);
    CHECK(lease && lease.valid && !error && own.parentViewController == nativeParent &&
          own.view.superview == nativeRoot && own.view.window == nativeWindow && own.didMoveCalls == 1 &&
          [nativeParent.children containsObject:own] && lastObserver.handler,
          "public child containment and own subview attached to borrowed root");
    canPresent = NO;
    CHECK(!lease.valid && lease.allowsDeferredFinish,
          "foreground loss invalidates input but cannot prevent the FIRST deferred cleanup");
    CHECK([PDOverlayLease finishPendingWithError:&error] && !error && cleaned(own) && !lease.valid &&
          own.willMoveCalls == 1 && own.view.removeCalls == 1 && own.removeParentCalls == 1 &&
          lastObserver.invalidated && lastObserver.invalidateCalls == 1 && presenterCancels == 1,
          "finishPending removes only own containment and observer");
    CHECK(!lease.allowsDeferredFinish, "a completed retirement cannot schedule another deferred cleanup");
    CHECK([lease finishWithError:nil] && [PDOverlayLease finishPendingWithError:nil] &&
          own.view.removeCalls == 1 && own.removeParentCalls == 1 && lastObserver.invalidateCalls == 1 &&
          presenterCancels == 1, "successful cleanup is idempotent");
    CHECK(nativeUntouched() && cleaned(own),
          "no hide/rekey/root replacement/window or container invalidation; borrowed root intact");
}

static void testViewRemovalRetry(void) {
    fresh(); UIViewController *own = [UIViewController new];
    PDOverlayLease *lease = attach(own, nil); own.view.removeThrows = 1;
    CHECK(lease && lease.valid, "view-removal fault starts from a valid overlay");
    NSError *error = nil;
    CHECK(![PDOverlayLease finishPendingWithError:&error] && error && !lease.valid &&
          own.view.superview == nativeRoot && !own.parentViewController && own.view.removeCalls == 1 &&
          own.removeParentCalls == 1 && lastObserver.invalidated && lastObserver.invalidateCalls == 1,
          "view removal throws: first finish NO; parent and observer still cleaned independently");
    CHECK(!lease.allowsDeferredFinish, "a failed retirement must await explicit retry, never self-enqueue");
    CHECK(attachRefused(), "failed view removal keeps pending ticket and blocks a new attach");
    error = nil;
    CHECK([PDOverlayLease finishPendingWithError:&error] && !error && cleaned(own) &&
          own.view.removeCalls == 2 && own.removeParentCalls == 1 && lastObserver.invalidateCalls == 1 &&
          presenterCancels == 2, "second finish actually retries failed own-view removal");
    CHECK([lease finishWithError:nil] && [PDOverlayLease finishPendingWithError:nil] &&
          own.view.removeCalls == 2 && lastObserver.invalidateCalls == 1 && presenterCancels == 2 &&
          nativeUntouched(), "view retry confirms completion before idempotence");
}

static void testObserverRetry(void) {
    fresh(); UIViewController *own = [UIViewController new];
    PDOverlayLease *lease = attach(own, nil); lastObserver.invalidateThrows = 1;
    CHECK(lease && lease.valid, "observer fault starts from a valid overlay");
    NSError *error = nil;
    CHECK(![PDOverlayLease finishPendingWithError:&error] && error && !lease.valid && cleaned(own) &&
          own.view.removeCalls == 1 && own.removeParentCalls == 1 && !lastObserver.invalidated &&
          lastObserver.invalidateCalls == 1,
          "observer throws: first finish NO despite independently removed own view and parent");
    CHECK(attachRefused(), "failed observer invalidation retains pending ticket even without containment");
    error = nil;
    CHECK([PDOverlayLease finishPendingWithError:&error] && !error && cleaned(own) &&
          lastObserver.invalidated && lastObserver.invalidateCalls == 2 && own.view.removeCalls == 2 &&
          own.removeParentCalls == 1 && presenterCancels == 2,
          "second finish actually retries observer invalidation");
    CHECK([lease finishWithError:nil] && [PDOverlayLease finishPendingWithError:nil] &&
          lastObserver.invalidateCalls == 2 && own.view.removeCalls == 2 && presenterCancels == 2 &&
          nativeUntouched(), "observer retry confirms completion before idempotence");
}

static void testParentRemovalRetry(void) {
    fresh(); UIViewController *own = [UIViewController new];
    PDOverlayLease *lease = attach(own, nil); own.removeParentThrows = 1;
    CHECK(lease && lease.valid, "parent-removal fault starts from a valid overlay");
    NSError *error = nil;
    CHECK(![PDOverlayLease finishPendingWithError:&error] && error && !lease.valid &&
          own.parentViewController == nativeParent && !own.view.superview && own.removeParentCalls == 1 &&
          own.view.removeCalls == 1 && lastObserver.invalidated && lastObserver.invalidateCalls == 1,
          "parent removal throws: first finish NO; view and observer still cleaned independently");
    CHECK(attachRefused(), "failed parent removal keeps pending ticket and blocks a new attach");
    error = nil;
    CHECK([PDOverlayLease finishPendingWithError:&error] && !error && cleaned(own) &&
          own.removeParentCalls == 2 && own.willMoveCalls == 2 && own.view.removeCalls == 2 &&
          lastObserver.invalidateCalls == 1 && presenterCancels == 2,
          "second finish actually retries parent removal and confirms containment gone");
    CHECK([lease finishWithError:nil] && [PDOverlayLease finishPendingWithError:nil] &&
          own.removeParentCalls == 2 && own.view.removeCalls == 2 && presenterCancels == 2 &&
          nativeUntouched(), "parent retry is idempotent only after real removal");
}

static void testPartialChild(void) {
    fresh(); UIViewController *own = [UIViewController new];
    nativeParent.addThrowsAfter = 1; own.removeParentThrows = 1;
    NSError *error = nil;
    CHECK(!attach(own, &error) && error && own.didMoveCalls == 0,
          "exception after addChild mutation returns no lease and reports attach failure");
    CHECK(own.parentViewController == nativeParent && !own.view.superview && own.removeParentCalls == 1 &&
          own.view.removeCalls == 1 && lastObserver.invalidated && lastObserver.invalidateCalls == 1,
          "partial child cleanup failure leaves a retryable orphan; independent steps ran");
    CHECK(attachRefused(), "partial addChild retains durable pending ticket without a returned lease");
    error = nil;
    CHECK([PDOverlayLease finishPendingWithError:&error] && !error && cleaned(own) &&
          own.removeParentCalls == 2 && own.view.removeCalls == 2 && lastObserver.invalidateCalls == 1,
          "finishPending eventually retries and removes orphaned child containment");
    CHECK([PDOverlayLease finishPendingWithError:nil] && own.removeParentCalls == 2 &&
          presenterCancels == 2 && nativeUntouched(), "partial child completion is idempotent and own-only");
}

static void testPartialSubview(void) {
    fresh(); UIViewController *own = [UIViewController new];
    nativeRoot.addThrowsAfter = 1; own.view.removeThrows = 1;
    NSError *error = nil;
    CHECK(!attach(own, &error) && error && own.didMoveCalls == 0,
          "exception after addSubview mutation returns no lease and reports attach failure");
    __weak UIViewController *pendingOwn = own; UIView *orphan = own.view;
    own = nil; // Detached parent cannot retain it; only the production ticket owns the controller.
    CHECK(pendingOwn && !pendingOwn.parentViewController && orphan.superview == nativeRoot &&
          orphan.removeCalls == 1 && lastObserver.invalidated && lastObserver.invalidateCalls == 1,
          "partial subview orphan and its controller survive via durable cleanup ticket");
    CHECK(attachRefused(), "partial addSubview keeps ticket and refuses a fresh attach");
    own = pendingOwn; error = nil;
    CHECK([PDOverlayLease finishPendingWithError:&error] && !error && cleaned(own) &&
          orphan.removeCalls == 2 && own.removeParentCalls == 1 && lastObserver.invalidateCalls == 1,
          "finishPending eventually retries and removes the orphaned own subview");
    CHECK([PDOverlayLease finishPendingWithError:nil] && orphan.removeCalls == 2 &&
          presenterCancels == 2 && nativeUntouched(), "partial subview completion is idempotent and own-only");
}

static void testReentrantChild(void) {
    fresh(); UIViewController *own = [UIViewController new];
    __block BOOL cancelResult = YES, nestedAccepted = YES, deferred = NO;
    __block NSError *cancelError = nil, *nestedError = nil;
    __block NSUInteger hookCalls = 0;
    nativeParent.duringAddChild = ^{
        hookCalls++;
        NSError *localError = nil;
        cancelResult = [PDOverlayLease finishPendingWithError:&localError];
        cancelError = localError;
        deferred = own.parentViewController == nativeParent && own.view.removeCalls == 0 &&
            own.removeParentCalls == 0 && lastObserver.invalidateCalls == 0 && presenterCancels == 0;
        nestedAccepted = attach([UIViewController new], &nestedError) != nil;
    };
    NSError *error = nil; PDOverlayLease *lease = attach(own, &error);
    CHECK(hookCalls == 1 && !cancelResult && cancelError && !lease && error,
          "reentrant cancellation during addChild returns NO and retires outer attach");
    CHECK(deferred && !nestedAccepted && nestedError && snapshotReads == 1,
          "no in-flight cleanup/new snapshot: addChild must unwind before a new attach");
    CHECK(cleaned(own) && own.view.removeCalls == 1 && own.removeParentCalls == 1 &&
          lastObserver.invalidated && lastObserver.invalidateCalls == 1 && presenterCancels == 1,
          "outer addChild attach unwinds and cleans its pending ticket");
    BOOL confirmed = [PDOverlayLease finishPendingWithError:nil];
    UIViewController *next = [UIViewController new]; PDOverlayLease *nextLease = attach(next, nil);
    BOOL nextValid = nextLease.valid; BOOL nextFinished = [PDOverlayLease finishPendingWithError:nil];
    CHECK(confirmed && nextLease && nextValid && nextFinished && cleaned(next) && nativeUntouched(),
          "new attach is allowed only after reentrant child cleanup has unwound and confirmed");
}

static void testReentrantObserver(void) {
    fresh(); UIViewController *own = [UIViewController new];
    __block BOOL cancelResult = YES, nestedAccepted = YES, deferred = NO;
    __block NSError *cancelError = nil, *nestedError = nil;
    __block NSUInteger hookCalls = 0;
    duringObserverInit = ^{
        hookCalls++;
        NSError *localError = nil;
        cancelResult = [PDOverlayLease finishPendingWithError:&localError];
        cancelError = localError;
        deferred = !own.parentViewController && own.view.removeCalls == 0 &&
            lastObserver.invalidateCalls == 0 && presenterCancels == 0;
        nestedAccepted = attach([UIViewController new], &nestedError) != nil;
    };
    NSError *error = nil; PDOverlayLease *lease = attach(own, &error);
    CHECK(hookCalls == 1 && !cancelResult && cancelError && !lease && error,
          "reentrant cancellation inside observer init sees the preexisting durable ticket");
    CHECK(deferred && !nestedAccepted && nestedError && snapshotReads == 1,
          "observer setup cannot clear ticket or permit a nested attach before outer unwind");
    CHECK(cleaned(own) && own.view.removeCalls == 1 && own.removeParentCalls == 1 &&
          lastObserver.invalidated && lastObserver.invalidateCalls == 1 && presenterCancels == 1,
          "outer observer setup unwinds and independently removes observer/own containment");
    BOOL confirmed = [PDOverlayLease finishPendingWithError:nil];
    UIViewController *next = [UIViewController new]; PDOverlayLease *nextLease = attach(next, nil);
    BOOL nextValid = nextLease.valid; BOOL nextFinished = [PDOverlayLease finishPendingWithError:nil];
    CHECK(confirmed && nextLease && nextValid && nextFinished && cleaned(next) && nativeUntouched(),
          "new attach succeeds after observer reentrancy is fully unwound, without native mutation");
}

static void testSceneBinding(void) {
    fresh(); foregroundTarget = PDProbeTargetFiles;
    UIViewController *own = [UIViewController new]; NSError *error = nil;
    PDOverlayLease *lease = [PDOverlayLease attachController:own target:PDProbeTargetFiles
                                             onInvalidation:^{} error:&error];
    NSDictionary *snapshot = PDNativeSnapshot(PDProbeTargetFiles, &error);
    CHECK(lease.valid && snapshot && !error && [lease matchesSnapshot:snapshot],
          "Files overlay matches its exact bound Scene and hierarchy");

    NSMutableDictionary *stale = [snapshot mutableCopy];
    stale[@"scene"] = [NSObject new];
    CHECK(lease.valid && ![lease matchesSnapshot:stale],
          "a different Scene object with the same identifier and hierarchy cannot be captured");
    stale = [snapshot mutableCopy];
    stale[@"identifier"] = @"sceneID:stale-overlay-fixture";
    CHECK(lease.valid && ![lease matchesSnapshot:stale],
          "a different identifier with the same Scene and hierarchy cannot be captured");

    stale = [snapshot mutableCopy];
    stale[@"manager"] = [NSObject new];
    CHECK(lease.valid && ![lease matchesSnapshot:stale],
          "the same scene and window cannot be re-bound to a different presentation manager");

    foregroundTarget = PDProbeTargetNotes;
    CHECK(!lease.valid && ![lease matchesSnapshot:snapshot] && lease.allowsDeferredFinish && attachRefused(),
          "foreground target switch blocks match and reattach without preventing cleanup");
    error = nil;
    CHECK([PDOverlayLease finishPendingWithError:&error] && !error && cleaned(own),
          "stale binding can still retire only its own containment");
}

int main(void) { @autoreleasepool {
    @try {
        caseName = @"normal public containment";
        testNormal();
        caseName = @"own-view cleanup retry";
        testViewRemovalRetry();
        caseName = @"observer cleanup retry";
        testObserverRetry();
        caseName = @"parent cleanup retry";
        testParentRemovalRetry();
        caseName = @"partial addChild";
        testPartialChild();
        caseName = @"partial addSubview";
        testPartialSubview();
        caseName = @"reentrant addChild cancellation";
        testReentrantChild();
        caseName = @"reentrant observer cancellation";
        testReentrantObserver();
        caseName = @"typed Scene binding";
        testSceneBinding();
    } @catch (NSException *exception) {
        failures++;
        fprintf(stderr, "OVERLAY EXCEPTION %s: %s: %s\n", caseName.UTF8String,
                exception.name.UTF8String, exception.reason.UTF8String);
    }
    printf("PANDORA_OVERLAY_LEASE_TESTS checks=%lu failures=%lu\n",
           (unsigned long)checks, (unsigned long)failures);
    return failures ? 1 : 0;
} }
