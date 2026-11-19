// Foundation environment doubles only. Link the FULL production PDPresenterLease.m.
// PDLeaseTestNativeChange simulates a native signal; the owner-mutation bridge
// calls the real production wrappers with C-function originals. Neither is
// private-hook or WindowServer evidence. No lease state/logic is substituted.
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import "PDPresenterLease.h"
#import "PDABI.h"
#include <limits.h>
#include <stdio.h>
#include <string.h>

@protocol _UIComparable <NSObject>
@end
@class _UIScenePresenterOwner, UIScenePresentationManager, _UIScenePresenter;
static NSUInteger checks, failures, managerInvalidations, ownerInvalidations;
static NSUInteger nativeInvalidations, containerInvalidations;
static NSString *caseName;
static void PDCheck(BOOL pass, const char *expression, int line) {
    checks++;
    if (!pass) {
        failures++;
        fprintf(stderr, "LEASE FAIL %s:%d: %s\n", caseName.UTF8String, line, expression);
    }
}
#define CHECK(expression) PDCheck((BOOL)(expression), #expression, __LINE__)
static void injected(void) {
    @throw [NSException exceptionWithName:@"PDInjected" reason:@"fixture fault" userInfo:nil];
}
@interface PDContainer : NSObject
- (void)invalidate;
@end
@implementation PDContainer
- (void)invalidate { containerInvalidations++; }
@end

@interface _UIScenePresenterOwner : NSObject {
@public
    BOOL _invalidated;
    UIScenePresentationManager *_scenePresentationManager;
    NSMutableOrderedSet *_activePresentersByPriority;
    NSMutableSet *_inactivePresentersByPriority;
    _UIScenePresenter *_prioritizedPresenter;
}
- (void)_activatePresenter:(_UIScenePresenter *)presenter;
- (void)_deactivatePresenter:(_UIScenePresenter *)presenter;
- (void)_invalidatePresenter:(_UIScenePresenter *)presenter;
- (void)invalidate;
@end
@interface _UIScenePresenter : NSObject {
@public
    BOOL _invalidated;
    _UIScenePresenterOwner *_owner;
    // Do not weaken to id: production requires @"<NSCopying><_UIComparable>".
    id<NSCopying, _UIComparable> _sortContext;
}
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic) BOOL nativeObject;
@property(nonatomic) BOOL throwActivateAfterMutation;
@property(nonatomic) BOOL throwInvalidate;
@property(nonatomic) NSUInteger activateCalls;
@property(nonatomic) NSUInteger deactivateCalls;
@property(nonatomic) NSUInteger invalidateCalls;
@property(nonatomic, copy) dispatch_block_t duringInvalidate;
@property(nonatomic, copy) dispatch_block_t duringActivate;
- (void)activate;
- (void)deactivate;
- (void)invalidate;
- (id)presentationView;
- (void)modifyPresentationContext:(void (^)(id context))block;
@end

typedef NS_ENUM(NSUInteger, PDFactoryMode) {
    PDFactoryNormal, PDFactoryThrowBefore, PDFactoryThrowAfter,
    PDFactoryNilBefore, PDFactoryNilAfter
};
@interface UIScenePresentationManager : NSObject {
@public
    BOOL _invalidated;
    _UIScenePresenterOwner *_scenePresenterOwner;
}
@property(nonatomic) PDFactoryMode mode;
@property(nonatomic) NSInteger lastPriority;
@property(nonatomic) NSUInteger factoryCalls;
@property(nonatomic) BOOL registeredBeforeReturn;
@property(nonatomic) BOOL failCreatedInvalidation;
@property(nonatomic, copy) dispatch_block_t beforeRegistration;
@property(nonatomic, strong) _UIScenePresenter *lastCreated;
@property(nonatomic, strong) PDContainer *container;
- (id)createPresenterWithIdentifier:(id)identifier priority:(NSInteger)priority;
- (void)invalidate;
@end
@implementation _UIScenePresenterOwner
- (void)selectPriority {
    _prioritizedPresenter = nil;
    for (_UIScenePresenter *p in _activePresentersByPriority) {
        if (!_prioritizedPresenter || [(NSNumber *)p->_sortContext longLongValue] >
            [(NSNumber *)_prioritizedPresenter->_sortContext longLongValue]) _prioritizedPresenter = p;
    }
}
- (void)_activatePresenter:(_UIScenePresenter *)p {
    [_inactivePresentersByPriority removeObject:p];
    [_activePresentersByPriority addObject:p];
    [self selectPriority];
}
- (void)_deactivatePresenter:(_UIScenePresenter *)p {
    [_activePresentersByPriority removeObject:p];
    if (!p->_invalidated) [_inactivePresentersByPriority addObject:p];
    [self selectPriority];
}
- (void)_invalidatePresenter:(_UIScenePresenter *)p {
    [_activePresentersByPriority removeObject:p];
    [_inactivePresentersByPriority removeObject:p];
    p->_invalidated = YES;
    [self selectPriority];
}
- (void)invalidate { ownerInvalidations++; _invalidated = YES; }
@end
@implementation _UIScenePresenter
- (void)activate {
    self.activateCalls++;
    [_owner _activatePresenter:self];
    dispatch_block_t during = self.duringActivate;
    self.duringActivate = nil;
    if (during) during(); // Still inside the original activation after mutation.
    if (self.throwActivateAfterMutation) injected();
}
- (void)deactivate { self.deactivateCalls++; [_owner _deactivatePresenter:self]; }
- (void)invalidate {
    self.invalidateCalls++;
    if (self.nativeObject) nativeInvalidations++;
    dispatch_block_t during = self.duringInvalidate;
    self.duringInvalidate = nil;
    if (during) during();
    if (self.throwInvalidate) injected();
    [_owner _invalidatePresenter:self];
}
- (id)presentationView { return _owner->_scenePresentationManager.container; }
- (void)modifyPresentationContext:(void (^)(id context))block {
    if (block) block([self presentationView]);
}
@end
@implementation UIScenePresentationManager
- (id)createPresenterWithIdentifier:(id)identifier priority:(NSInteger)priority {
    self.factoryCalls++;
    self.lastPriority = priority;
    if (self.mode == PDFactoryThrowBefore) injected();
    if (self.mode == PDFactoryNilBefore) return nil;
    _UIScenePresenter *p = [_UIScenePresenter new];
    p->_owner = _scenePresenterOwner;
    p->_sortContext = (id<NSCopying, _UIComparable>)[NSNumber numberWithInteger:priority];
    p.identifier = identifier;
    p.throwInvalidate = self.failCreatedInvalidation;
    self.lastCreated = p;
    dispatch_block_t before = self.beforeRegistration;
    self.beforeRegistration = nil;
    if (before) before(); // No discoverable presenter yet: ticket must survive.
    // Native registration precedes return (including a throw or nil return).
    [_scenePresenterOwner->_inactivePresentersByPriority addObject:p];
    self.registeredBeforeReturn = [_scenePresenterOwner->_inactivePresentersByPriority containsObject:p];
    if (self.mode == PDFactoryThrowAfter) injected();
    if (self.mode == PDFactoryNilAfter) return nil;
    return p;
}
- (void)invalidate { managerInvalidations++; _invalidated = YES; }
@end

// Deliberately wrong REAL ivar encodings, never runtime-patched fake metadata.
@interface PDWrongFlag : NSObject { @public int _invalidated; }
@end
@implementation PDWrongFlag
@end
@interface PDWrongManagerReference : NSObject { @public BOOL _invalidated; id _scenePresenterOwner; }
@end
@implementation PDWrongManagerReference
@end
@interface PDMissingManagerReference : NSObject { @public BOOL _invalidated; }
@end
@implementation PDMissingManagerReference
@end
@interface PDWrongOwnerReference : NSObject {
@public
    BOOL _invalidated;
    id _scenePresentationManager;
    NSMutableOrderedSet *_activePresentersByPriority;
    NSMutableSet *_inactivePresentersByPriority;
    _UIScenePresenter *_prioritizedPresenter;
}
@end
@implementation PDWrongOwnerReference
@end
@interface PDMissingOwnerReference : NSObject {
@public
    BOOL _invalidated;
    NSMutableOrderedSet *_activePresentersByPriority;
    NSMutableSet *_inactivePresentersByPriority;
    _UIScenePresenter *_prioritizedPresenter;
}
@end
@implementation PDMissingOwnerReference
@end
@interface PDMissingNativeOwner : NSObject {
@public BOOL _invalidated; id<NSCopying, _UIComparable> _sortContext;
}
@end
@implementation PDMissingNativeOwner
@end
@interface PDWrongNativeOwner : NSObject {
@public BOOL _invalidated; id _owner; id<NSCopying, _UIComparable> _sortContext;
}
@end
@implementation PDWrongNativeOwner
@end

static UIScenePresentationManager *M;
static _UIScenePresenterOwner *O;
static _UIScenePresenter *N;
static void fresh(NSString *name) {
    if (![PDPresenterLease cancelOutstandingWithError:nil]) {
        [NSException raise:@"PDHarnessCleanup" format:@"previous case retained cleanup ticket"];
    }
    // Break only fixture retain cycles AFTER production confirms cleanup.
    if (O) {
        [O->_activePresentersByPriority removeAllObjects];
        [O->_inactivePresentersByPriority removeAllObjects];
        O->_scenePresentationManager = nil; O->_prioritizedPresenter = nil;
    }
    if (M) M->_scenePresenterOwner = nil;
    if (N) N->_owner = nil;
    caseName = name;
    M = [UIScenePresentationManager new];
    O = [_UIScenePresenterOwner new];
    N = [_UIScenePresenter new];
    M.container = [PDContainer new];
    M->_scenePresenterOwner = O;
    O->_scenePresentationManager = M;
    O->_activePresentersByPriority = [NSMutableOrderedSet orderedSetWithObject:N];
    O->_inactivePresentersByPriority = [NSMutableSet new];
    O->_prioritizedPresenter = N;
    N->_owner = O;
    N->_sortContext = (id<NSCopying, _UIComparable>)@41;
    N.identifier = @"native";
    N.nativeObject = YES;
}
static PDPresenterLease *stage(dispatch_block_t handler, NSError **error) {
    return [PDPresenterLease stageWithManager:M owner:O nativePresenter:N onChange:handler error:error];
}
static BOOL restored(void) {
    return O->_activePresentersByPriority.count == 1 &&
        O->_activePresentersByPriority.firstObject == N && !O->_inactivePresentersByPriority.count &&
        O->_prioritizedPresenter == N && !N->_invalidated && !M->_invalidated && !O->_invalidated &&
        N.activateCalls == 0 && N.deactivateCalls == 0 && N.invalidateCalls == 0;
}
static BOOL encoding(Class cls, const char *name, const char *expected) {
    Ivar field = class_getInstanceVariable(cls, name);
    return field && strcmp(ivar_getTypeEncoding(field), expected) == 0;
}
static void drain(void) {
    __block BOOL done = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ done = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!done && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
    if (!done) [NSException raise:@"PDHarnessQueue" format:@"main queue did not drain"];
}

static void testABI(void) {
    fresh(@"exact runtime ABI");
    CHECK(NSThread.isMainThread);
    CHECK(encoding(M.class, "_scenePresenterOwner", "@\"_UIScenePresenterOwner\""));
    CHECK(encoding(O.class, "_scenePresentationManager", "@\"UIScenePresentationManager\""));
    CHECK(encoding(O.class, "_activePresentersByPriority", "@\"NSMutableOrderedSet\""));
    CHECK(encoding(O.class, "_inactivePresentersByPriority", "@\"NSMutableSet\""));
    CHECK(encoding(O.class, "_prioritizedPresenter", "@\"_UIScenePresenter\""));
    CHECK(encoding(N.class, "_owner", "@\"_UIScenePresenterOwner\""));
    CHECK(encoding(N.class, "_sortContext", "@\"<NSCopying><_UIComparable>\""));
    CHECK(encoding(N.class, "_invalidated", @encode(BOOL)));
    CHECK(PDMatches(M, @selector(createPresenterWithIdentifier:priority:), "@", @[@"@", [NSString stringWithUTF8String:@encode(NSInteger)]]));
    CHECK(PDMatches(N, @selector(modifyPresentationContext:), "v", @[@"@?"]));
    BOOL flag = YES;
    CHECK(PDLeaseFlag(N, "_invalidated", &flag) && !flag);
    CHECK(!PDLeaseFlag([PDWrongFlag new], "_invalidated", &flag));
    CHECK(!PDLeaseFlag([NSObject new], "_invalidated", &flag));
    CHECK(PDLeaseObject(M, "_scenePresenterOwner", "@\"_UIScenePresenterOwner\"") == O);
    CHECK(PDLeaseObject(M, "_scenePresenterOwner", "@") == nil);
    CHECK(PDLeaseObject(N, "missing", "@") == nil);
    CHECK(PDLeaseMembers(@[N]) == nil);
    CHECK(PDLeaseMembers([NSSet setWithObject:N]).count == 1);
    NSMutableSet *large = [NSMutableSet new];
    for (NSUInteger i = 0; i < 65; i++) [large addObject:[NSObject new]];
    CHECK(PDLeaseMembers(large) == nil);
}
static void testLifecycle(void) {
    fresh(@"stage inactive / activate / own-only cancel");
    __block NSUInteger changes = 0;
    NSError *error = nil;
    PDPresenterLease *lease = stage(^{ changes++; }, &error);
    _UIScenePresenter *p = lease.presenter;
    CHECK(lease != nil && error == nil);
    CHECK(M.factoryCalls == 1 && M.lastPriority == 42);
    CHECK([p.identifier hasPrefix:@"com.tsangbaby.pandora.probe3."]);
    CHECK(M.registeredBeforeReturn && O->_inactivePresentersByPriority.count == 1 && [O->_inactivePresentersByPriority containsObject:p]);
    CHECK(O->_activePresentersByPriority.count == 1 && O->_prioritizedPresenter == N);
    CHECK(!lease.readyForInput && !lease.ended && p.activateCalls == 0);
    CHECK([lease activateWithError:&error] && error == nil);
    CHECK(lease.readyForInput && O->_prioritizedPresenter == p);
    CHECK(O->_activePresentersByPriority.count == 2 && [O->_activePresentersByPriority containsObject:N]);
    CHECK(O->_inactivePresentersByPriority.count == 0 && p.activateCalls == 1);
    error = nil;
    CHECK(![lease activateWithError:&error] && error != nil && p.activateCalls == 1);
    error = nil;
    CHECK([lease cancelWithError:&error] && error == nil);
    CHECK(lease.ended && !lease.readyForInput && lease.presenter == nil);
    CHECK(p && p->_invalidated && p.deactivateCalls == 1 && p.invalidateCalls == 1);
    CHECK(restored());
    CHECK([lease cancelWithError:nil] && [PDPresenterLease cancelOutstandingWithError:nil]);
    CHECK(p.deactivateCalls == 1 && p.invalidateCalls == 1);
    drain();
    CHECK(changes == 0);
}
static void testFactoryFaults(void) {
    NSError *error = nil;
    fresh(@"factory throw before registration");
    M.mode = PDFactoryThrowBefore;
    CHECK(stage(^{}, &error) == nil && error != nil);
    CHECK(M.factoryCalls == 1 && M.lastCreated == nil && restored());
    CHECK([PDPresenterLease cancelOutstandingWithError:nil]);

    fresh(@"factory throw after registration");
    M.mode = PDFactoryThrowAfter; error = nil;
    CHECK(stage(^{}, &error) == nil && error != nil);
    CHECK(M.registeredBeforeReturn && M.lastCreated->_invalidated);
    CHECK(M.lastCreated.deactivateCalls == 1 && M.lastCreated.invalidateCalls == 1 && restored());
    CHECK([PDPresenterLease cancelOutstandingWithError:nil]);

    fresh(@"factory nil before registration");
    M.mode = PDFactoryNilBefore; error = nil;
    CHECK(stage(^{}, &error) == nil && error != nil);
    CHECK(M.factoryCalls == 1 && M.lastCreated == nil && restored());
    CHECK([PDPresenterLease cancelOutstandingWithError:nil]);

    fresh(@"factory nil after registration");
    M.mode = PDFactoryNilAfter; error = nil;
    CHECK(stage(^{}, &error) == nil && error != nil);
    CHECK(M.registeredBeforeReturn && M.lastCreated->_invalidated && restored());
    CHECK(M.lastCreated.deactivateCalls == 1 && M.lastCreated.invalidateCalls == 1);
    CHECK([PDPresenterLease cancelOutstandingWithError:nil]);
    drain();
}
static void testFactoryReentry(void) {
    fresh(@"factory cancel before registration then returns presenter");
    __block NSUInteger callbacks = 0, entries = 0;
    M.beforeRegistration = ^{
        entries++;
        CHECK(M.lastCreated != nil && !M.registeredBeforeReturn && restored());
        NSError *cancelError = nil, *stageError = nil;
        CHECK(![PDPresenterLease cancelOutstandingWithError:&cancelError] && cancelError != nil);
        CHECK(stage(^{}, &stageError) == nil && stageError != nil && M.factoryCalls == 1);
        drain();
        CHECK(callbacks == 0 && !M.lastCreated->_invalidated);
        CHECK(M.lastCreated.deactivateCalls == 0 && M.lastCreated.invalidateCalls == 0);
    };
    NSError *error = nil;
    CHECK(stage(^{ callbacks++; }, &error) == nil && error != nil);
    _UIScenePresenter *p = M.lastCreated;
    CHECK(entries == 1 && M.factoryCalls == 1 && M.registeredBeforeReturn);
    CHECK(p && p->_invalidated && p.activateCalls == 0);
    CHECK(p.deactivateCalls == 1 && p.invalidateCalls == 1 && restored());
    CHECK([PDPresenterLease cancelOutstandingWithError:nil]);
    drain();
    CHECK(callbacks == 0);
    PDPresenterLease *next = stage(^{}, nil);
    CHECK(next != nil && M.factoryCalls == 2 && [next cancelWithError:nil] && restored());

    fresh(@"factory cancel before registration then registers and throws");
    M.mode = PDFactoryThrowAfter; callbacks = 0; entries = 0;
    M.beforeRegistration = ^{
        entries++;
        CHECK(M.lastCreated != nil && !M.registeredBeforeReturn && restored());
        NSError *cancelError = nil, *stageError = nil;
        CHECK(![PDPresenterLease cancelOutstandingWithError:&cancelError] && cancelError != nil);
        CHECK(stage(^{}, &stageError) == nil && stageError != nil && M.factoryCalls == 1);
        drain();
        CHECK(callbacks == 0 && !M.lastCreated->_invalidated);
        CHECK(M.lastCreated.deactivateCalls == 0 && M.lastCreated.invalidateCalls == 0);
    };
    error = nil;
    CHECK(stage(^{ callbacks++; }, &error) == nil && error != nil);
    p = M.lastCreated;
    CHECK(entries == 1 && M.factoryCalls == 1 && M.registeredBeforeReturn);
    CHECK(p && p->_invalidated && p.activateCalls == 0);
    CHECK(p.deactivateCalls == 1 && p.invalidateCalls == 1 && restored());
    CHECK([PDPresenterLease cancelOutstandingWithError:nil]);
    drain();
    CHECK(callbacks == 0);
    M.mode = PDFactoryNormal;
    next = stage(^{}, nil);
    CHECK(next != nil && M.factoryCalls == 2 && [next cancelWithError:nil] && restored());
}

static void testActivationReentry(void) {
    fresh(@"activation cancel while original mutation has not returned");
    __block NSUInteger callbacks = 0, entries = 0;
    __block BOOL inOriginal = NO, callbackInOriginal = NO, callbackCleaned = NO;
    PDPresenterLease *lease = stage(^{
        callbacks++;
        callbackInOriginal = inOriginal;
        callbackCleaned = [PDPresenterLease cancelOutstandingWithError:nil];
    }, nil);
    _UIScenePresenter *p = lease.presenter;
    CHECK(lease != nil && p != nil);
    p.duringActivate = ^{
        inOriginal = YES; entries++;
        CHECK(O->_prioritizedPresenter == p && [O->_activePresentersByPriority containsObject:p]);
        NSError *cancelError = nil, *stageError = nil;
        CHECK(![PDPresenterLease cancelOutstandingWithError:&cancelError] && cancelError != nil);
        CHECK(!lease.ended && lease.presenter == p && !lease.readyForInput);
        CHECK(stage(^{}, &stageError) == nil && stageError != nil && M.factoryCalls == 1);
        drain();
        CHECK(callbacks == 0 && p.deactivateCalls == 0 && p.invalidateCalls == 0 && !p->_invalidated);
        inOriginal = NO;
    };
    NSError *error = nil;
    CHECK(![lease activateWithError:&error] && error != nil);
    CHECK(entries == 1 && callbacks == 0 && !lease.ended && !lease.readyForInput);
    CHECK(p.activateCalls == 1 && O->_prioritizedPresenter == p && !p->_invalidated);
    error = nil;
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 1);
    drain();
    CHECK(callbacks == 1 && !callbackInOriginal && callbackCleaned);
    CHECK(lease.ended && lease.presenter == nil && restored());
    CHECK(p.deactivateCalls == 1 && p.invalidateCalls == 1 && p->_invalidated);
    drain();
    CHECK(callbacks == 1 && [PDPresenterLease cancelOutstandingWithError:nil]);
}

static void testCleanupTicket(void) {
    fresh(@"factory throws without handle, failed rollback retains ticket");
    M.mode = PDFactoryThrowAfter;
    M.failCreatedInvalidation = YES;
    NSError *ticketError = nil;
    CHECK(stage(^{}, &ticketError) == nil && ticketError != nil);
    _UIScenePresenter *orphan = M.lastCreated;
    CHECK(orphan && !orphan->_invalidated && orphan.deactivateCalls == 1 && orphan.invalidateCalls == 1);
    ticketError = nil;
    CHECK(stage(^{}, &ticketError) == nil && ticketError != nil && M.factoryCalls == 1);
    ticketError = nil;
    CHECK(![PDPresenterLease cancelOutstandingWithError:&ticketError] && ticketError != nil);
    orphan.throwInvalidate = NO;
    CHECK([PDPresenterLease cancelOutstandingWithError:nil] && restored());
    CHECK(orphan.deactivateCalls == 3 && orphan.invalidateCalls == 3 && orphan->_invalidated);
    M.mode = PDFactoryNormal; M.failCreatedInvalidation = NO;
    PDPresenterLease *afterOrphan = stage(^{}, nil);
    CHECK(afterOrphan != nil && M.factoryCalls == 2 && [afterOrphan cancelWithError:nil] && restored());

    fresh(@"activation throws after native mutation");
    PDPresenterLease *lease = stage(^{}, nil);
    _UIScenePresenter *p = lease.presenter;
    p.throwActivateAfterMutation = YES;
    NSError *error = nil;
    CHECK(lease != nil);
    CHECK(![lease activateWithError:&error] && error != nil && !lease.readyForInput);
    CHECK(O->_prioritizedPresenter == p && p.activateCalls == 1);
    CHECK([lease cancelWithError:nil] && lease.ended && restored());
    CHECK(p.deactivateCalls == 1 && p.invalidateCalls == 1 && p->_invalidated);

    fresh(@"failed cleanup retains exclusion until retry");
    lease = stage(^{}, nil); p = lease.presenter;
    CHECK(lease != nil && [lease activateWithError:nil]);
    p.throwInvalidate = YES; error = nil;
    CHECK(![lease cancelWithError:&error] && error != nil && !lease.ended);
    CHECK(!lease.readyForInput && [O->_inactivePresentersByPriority containsObject:p]);
    error = nil;
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 1);
    error = nil;
    CHECK(![PDPresenterLease cancelOutstandingWithError:&error] && error != nil);
    p.throwInvalidate = NO;
    CHECK([PDPresenterLease cancelOutstandingWithError:nil] && lease.ended && restored());
    CHECK(p.deactivateCalls == 3 && p.invalidateCalls == 3 && p->_invalidated);
    PDPresenterLease *next = stage(^{}, nil);
    CHECK(next != nil && M.factoryCalls == 2);
    CHECK([next cancelWithError:nil] && restored());

    fresh(@"reentrant cleanup cannot stage or recursively cancel");
    lease = stage(^{}, nil); p = lease.presenter;
    __block PDPresenterLease *nested = nil;
    __block NSError *nestedError = nil, *recursiveError = nil;
    __block BOOL recursiveResult = YES;
    // Captures are dropped by the fake invalidate method before invoking this.
    p.duringInvalidate = ^{
        nested = stage(^{}, &nestedError);
        recursiveResult = [lease cancelWithError:&recursiveError];
    };
    CHECK([lease cancelWithError:nil]);
    CHECK(nested == nil && nestedError != nil && M.factoryCalls == 1);
    CHECK(!recursiveResult && recursiveError != nil);
    CHECK(lease.ended && restored());
}

static void testOperationReentry(void) {
    fresh(@"nested protected view/context operation cancels without retiring ticket");
    __block NSUInteger callbacks = 0;
    __block BOOL inOuter = NO, inInner = NO, callbackInOperation = NO, callbackCleaned = NO;
    PDPresenterLease *lease = stage(^{
        callbacks++;
        callbackInOperation = inOuter || inInner;
        callbackCleaned = [PDPresenterLease cancelOutstandingWithError:nil];
    }, nil);
    _UIScenePresenter *p = lease.presenter;
    CHECK(lease != nil && [lease activateWithError:nil]);
    BOOL result = [lease performOperation:^BOOL{
        inOuter = YES;
        CHECK([p presentationView] == M.container);
        BOOL innerResult = [lease performOperation:^BOOL{
            inInner = YES;
            [p modifyPresentationContext:^(id context) {
                CHECK(context == M.container);
                NSError *cancelError = nil, *stageError = nil;
                CHECK(![PDPresenterLease cancelOutstandingWithError:&cancelError] && cancelError != nil);
                CHECK(stage(^{}, &stageError) == nil && stageError != nil && M.factoryCalls == 1);
                drain();
                CHECK(callbacks == 0 && !lease.ended && !lease.readyForInput && !p->_invalidated);
                CHECK(p.deactivateCalls == 0 && p.invalidateCalls == 0);
            }];
            inInner = NO;
            return YES;
        } error:nil];
        CHECK(!innerResult && !lease.ended && lease.presenter == p);
        NSError *cancelError = nil, *stageError = nil;
        CHECK(![lease cancelWithError:&cancelError] && cancelError != nil);
        CHECK(stage(^{}, &stageError) == nil && stageError != nil && M.factoryCalls == 1);
        drain(); // Inner unwind must not notify while the outer native depth remains.
        CHECK(callbacks == 0 && !p->_invalidated && p.deactivateCalls == 0 && p.invalidateCalls == 0);
        inOuter = NO;
        return YES;
    } error:nil];
    CHECK(!result && callbacks == 0 && !lease.ended && !lease.readyForInput);
    __block BOOL refusedRan = NO;
    NSError *error = nil;
    CHECK(![lease performOperation:^BOOL{ refusedRan = YES; return YES; } error:&error] && error != nil && !refusedRan);
    drain();
    CHECK(callbacks == 1 && !callbackInOperation && callbackCleaned);
    CHECK(lease.ended && lease.presenter == nil && restored());
    CHECK(p.activateCalls == 1 && p.deactivateCalls == 1 && p.invalidateCalls == 1 && p->_invalidated);
}

static void testOperationThrow(void) {
    fresh(@"nested protected operation cancellation and exception unwind");
    __block NSUInteger callbacks = 0;
    __block BOOL inOuter = NO, inInner = NO, callbackInOperation = NO, callbackCleaned = NO;
    PDPresenterLease *lease = stage(^{
        callbacks++;
        callbackInOperation = inOuter || inInner;
        callbackCleaned = [PDPresenterLease cancelOutstandingWithError:nil];
    }, nil);
    _UIScenePresenter *p = lease.presenter;
    CHECK(lease != nil && [lease activateWithError:nil]);
    NSException *fault = [NSException exceptionWithName:@"PDOperationFault" reason:@"exact exception" userInfo:nil];
    NSException *caught = nil;
    @try {
        [lease performOperation:^BOOL{
            inOuter = YES;
            @try {
                return [lease performOperation:^BOOL{
                    inInner = YES;
                    @try {
                        CHECK([p presentationView] == M.container);
                        [p modifyPresentationContext:^(id context) {
                            CHECK(context == M.container);
                            NSError *cancelError = nil, *stageError = nil;
                            CHECK(![PDPresenterLease cancelOutstandingWithError:&cancelError] && cancelError != nil);
                            CHECK(stage(^{}, &stageError) == nil && stageError != nil && M.factoryCalls == 1);
                        }];
                        drain();
                        CHECK(callbacks == 0 && !lease.ended && !p->_invalidated);
                        @throw fault;
                    } @finally { inInner = NO; }
                } error:nil];
            } @finally {
                drain(); // The inner depth unwound, but the outer barrier still applies.
                CHECK(callbacks == 0 && !lease.ended && lease.presenter == p);
                CHECK(p.deactivateCalls == 0 && p.invalidateCalls == 0);
                inOuter = NO;
            }
        } error:nil];
    } @catch (NSException *exception) { caught = exception; }
    CHECK(caught == fault && !inOuter && !inInner);
    CHECK(callbacks == 0 && !lease.ended && !lease.readyForInput);
    NSError *error = nil;
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 1);
    drain();
    CHECK(callbacks == 1 && !callbackInOperation && callbackCleaned);
    CHECK(lease.ended && lease.presenter == nil && restored());
    CHECK(p.activateCalls == 1 && p.deactivateCalls == 1 && p.invalidateCalls == 1 && p->_invalidated);
    PDPresenterLease *next = stage(^{}, nil);
    CHECK(next != nil && M.factoryCalls == 2 && [next cancelWithError:nil] && restored());
}

// C originals are recorders, not lease replacements. Exercise the three real
// owner wrappers nested 0 -> 1 -> 2; never invalidate the native presenter.
static struct {
    NSUInteger calls[3], depth, callbacks;
    BOOL arguments[3], cancelBlocked[3], stageBlocked[3], deferred[3], intact[3], exited[3];
    BOOL callbackEarly, callbackAfterAllExits, callbackCleaned;
} ownerProbe;
static PDPresenterLease *ownerProbeLease;
static _UIScenePresenter *ownerProbePresenter;
static void originalActivate(id owner, SEL selector, id presenter);
static void originalDeactivate(id owner, SEL selector, id presenter);
static void originalInvalidate(id owner, SEL selector, id presenter);
static void probeOwnerOriginal(NSUInteger kind, id owner, SEL selector, id presenter) {
    ownerProbe.calls[kind]++;
    ownerProbe.depth++;
    SEL expected = kind == 0 ? @selector(_activatePresenter:) :
        (kind == 1 ? @selector(_deactivatePresenter:) : @selector(_invalidatePresenter:));
    ownerProbe.arguments[kind] = owner == O && sel_isEqual(selector, expected) && presenter == N;
    @try {
        drain(); // The wrapper has already latched the loss before this original.
        BOOL before = ownerProbe.callbacks == 0;
        NSError *cancelError = nil, *stageError = nil;
        ownerProbe.cancelBlocked[kind] = ![PDPresenterLease cancelOutstandingWithError:&cancelError] && cancelError != nil;
        ownerProbe.stageBlocked[kind] = stage(^{}, &stageError) == nil && stageError != nil && M.factoryCalls == 1;
        if (kind == 0) PDLeaseTestInvokeOwnerMutation(1, owner, presenter, originalDeactivate);
        else if (kind == 1) PDLeaseTestInvokeOwnerMutation(2, owner, presenter, originalInvalidate);
        drain(); // In particular, inner wrapper exit must not release outer delivery.
        ownerProbe.deferred[kind] = before && ownerProbe.callbacks == 0;
        ownerProbe.intact[kind] = !ownerProbeLease.ended && ownerProbeLease.presenter == ownerProbePresenter &&
            !ownerProbeLease.readyForInput && !ownerProbePresenter->_invalidated &&
            ownerProbePresenter.deactivateCalls == 0 && ownerProbePresenter.invalidateCalls == 0 &&
            O->_prioritizedPresenter == ownerProbePresenter;
    } @finally {
        ownerProbe.exited[kind] = YES;
        ownerProbe.depth--;
    }
}
static void originalActivate(id owner, SEL selector, id presenter) {
    probeOwnerOriginal(0, owner, selector, presenter);
}
static void originalDeactivate(id owner, SEL selector, id presenter) {
    probeOwnerOriginal(1, owner, selector, presenter);
}
static void originalInvalidate(id owner, SEL selector, id presenter) {
    probeOwnerOriginal(2, owner, selector, presenter);
}
static void testOwnerOriginalForwarding(void) {
    fresh(@"real owner wrappers forward unchanged exactly once and defer through nested originals");
    memset(&ownerProbe, 0, sizeof(ownerProbe));
    ownerProbeLease = stage(^{
        ownerProbe.callbacks++;
        ownerProbe.callbackEarly = ownerProbe.depth != 0;
        ownerProbe.callbackAfterAllExits = ownerProbe.exited[0] && ownerProbe.exited[1] && ownerProbe.exited[2];
        ownerProbe.callbackCleaned = [PDPresenterLease cancelOutstandingWithError:nil];
    }, nil);
    ownerProbePresenter = ownerProbeLease.presenter;
    CHECK(ownerProbeLease != nil && [ownerProbeLease activateWithError:nil]);
    PDLeaseTestInvokeOwnerMutation(0, O, N, originalActivate);
    CHECK(ownerProbe.calls[0] == 1);
    CHECK(ownerProbe.calls[1] == 1);
    CHECK(ownerProbe.calls[2] == 1);
    CHECK(ownerProbe.arguments[0]);
    CHECK(ownerProbe.arguments[1]);
    CHECK(ownerProbe.arguments[2]);
    CHECK(ownerProbe.cancelBlocked[0] && ownerProbe.stageBlocked[0]);
    CHECK(ownerProbe.cancelBlocked[1] && ownerProbe.stageBlocked[1]);
    CHECK(ownerProbe.cancelBlocked[2] && ownerProbe.stageBlocked[2]);
    CHECK(ownerProbe.deferred[0] && ownerProbe.intact[0]);
    CHECK(ownerProbe.deferred[1] && ownerProbe.intact[1]);
    CHECK(ownerProbe.deferred[2] && ownerProbe.intact[2]);
    CHECK(ownerProbe.depth == 0 && ownerProbe.callbacks == 0 && !ownerProbeLease.ended);
    CHECK(!ownerProbeLease.readyForInput && ownerProbePresenter.activateCalls == 1);
    drain();
    CHECK(ownerProbe.callbacks == 1 && !ownerProbe.callbackEarly && ownerProbe.callbackAfterAllExits);
    CHECK(ownerProbe.callbackCleaned && ownerProbeLease.ended && ownerProbeLease.presenter == nil);
    CHECK(ownerProbePresenter.deactivateCalls == 1 && ownerProbePresenter.invalidateCalls == 1 && ownerProbePresenter->_invalidated);
    CHECK(restored());
    drain();
    CHECK(ownerProbe.callbacks == 1 && [PDPresenterLease cancelOutstandingWithError:nil]);
    ownerProbeLease = nil; ownerProbePresenter = nil;
}

static void testSignals(void) {
    fresh(@"foreign signal latches synchronously, callback queued once");
    __block NSUInteger changes = 0;
    __block BOOL callbackMain = NO, callbackReady = YES;
    __block PDPresenterLease *lease = nil;
    lease = stage(^{ changes++; callbackMain = NSThread.isMainThread; callbackReady = lease.readyForInput; }, nil);
    CHECK(lease != nil && [lease activateWithError:nil]);
    PDLeaseTestNativeChange(O, lease.presenter); // Own signal is not a loss.
    PDLeaseTestNativeChange([_UIScenePresenterOwner new], N);
    drain();
    CHECK(lease.readyForInput && changes == 0);
    PDLeaseTestNativeChange(O, N); // Environment signal, NOT real Hook evidence.
    CHECK(!lease.readyForInput && changes == 0);
    PDLeaseTestNativeChange(O, N);
    NSError *error = nil;
    CHECK(![lease activateWithError:&error] && error != nil);
    drain();
    CHECK(changes == 1 && callbackMain && !callbackReady);
    PDLeaseTestNativeChange(O, N);
    drain();
    CHECK(changes == 1 && !lease.readyForInput);
    CHECK([lease cancelWithError:nil] && restored());
    PDLeaseTestNativeChange(O, N); // Retired transaction has no observer.
    drain();
    CHECK(changes == 1);

    fresh(@"stale queued callback cannot cancel a new lease");
    __block NSUInteger retiredChanges = 0, newChanges = 0;
    PDPresenterLease *retired = stage(^{
        retiredChanges++;
        [PDPresenterLease cancelOutstandingWithError:nil];
    }, nil);
    CHECK(retired != nil && [retired activateWithError:nil]);
    PDLeaseTestNativeChange(O, N);
    CHECK(!retired.readyForInput && retiredChanges == 0);
    CHECK([retired cancelWithError:nil] && retired.ended);
    PDPresenterLease *current = stage(^{ newChanges++; }, nil);
    CHECK(current != nil && [current activateWithError:nil] && current.readyForInput);
    drain();
    CHECK(retiredChanges == 0 && newChanges == 0 && current.readyForInput && !current.ended);
    _UIScenePresenterOwner *retiredOwner = O;
    CHECK([current cancelWithError:nil] && restored());
    fresh(@"retired owner signal cannot affect different owner");
    current = stage(^{ newChanges++; }, nil);
    CHECK(current != nil && [current activateWithError:nil]);
    PDLeaseTestNativeChange(retiredOwner, N);
    drain();
    CHECK(current.readyForInput && newChanges == 0);
    CHECK([current cancelWithError:nil] && restored());
}
static void testEligibility(void) {
    NSError *error = nil;
    fresh(@"manager invalidated"); M->_invalidated = YES;
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 0);
    fresh(@"owner invalidated"); O->_invalidated = YES; error = nil;
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 0);
    fresh(@"native invalidated"); N->_invalidated = YES; error = nil;
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 0);
    fresh(@"missing manager flag"); error = nil;
    CHECK([PDPresenterLease stageWithManager:[NSObject new] owner:O nativePresenter:N onChange:^{} error:&error] == nil && error != nil && M.factoryCalls == 0);
    fresh(@"wrong manager flag encoding"); error = nil;
    CHECK([PDPresenterLease stageWithManager:[PDWrongFlag new] owner:O nativePresenter:N onChange:^{} error:&error] == nil && error != nil && M.factoryCalls == 0);
    fresh(@"missing native flag"); error = nil;
    CHECK([PDPresenterLease stageWithManager:M owner:O nativePresenter:[NSObject new] onChange:^{} error:&error] == nil && error != nil && M.factoryCalls == 0);
    fresh(@"wrong native flag encoding"); error = nil;
    CHECK([PDPresenterLease stageWithManager:M owner:O nativePresenter:[PDWrongFlag new] onChange:^{} error:&error] == nil && error != nil && M.factoryCalls == 0);
    fresh(@"no active native"); [O->_activePresentersByPriority removeAllObjects]; error = nil;
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 0);
    fresh(@"two active presenters"); [O->_activePresentersByPriority addObject:[_UIScenePresenter new]]; error = nil;
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 0);
    fresh(@"preexisting inactive presenter"); [O->_inactivePresentersByPriority addObject:[_UIScenePresenter new]]; error = nil;
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 0);
    fresh(@"wrong prioritized presenter"); O->_prioritizedPresenter = [_UIScenePresenter new]; error = nil;
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 0);
    fresh(@"unsupported active collection"); O->_activePresentersByPriority = (id)@[N]; error = nil;
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 0);
    // Restore the fixture type so fresh() need not send removeAllObjects to NSArray.
    O->_activePresentersByPriority = [NSMutableOrderedSet orderedSetWithObject:N];

    fresh(@"wrong manager owner encoding");
    PDWrongManagerReference *badManager = [PDWrongManagerReference new];
    badManager->_scenePresenterOwner = O; O->_scenePresentationManager = (id)badManager; error = nil;
    CHECK([PDPresenterLease stageWithManager:badManager owner:O nativePresenter:N onChange:^{} error:&error] == nil && error != nil && M.factoryCalls == 0);
    fresh(@"missing manager owner reference"); error = nil;
    CHECK([PDPresenterLease stageWithManager:[PDMissingManagerReference new] owner:O nativePresenter:N onChange:^{} error:&error] == nil && error != nil && M.factoryCalls == 0);
    fresh(@"nil manager owner reference"); M->_scenePresenterOwner = nil; error = nil;
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 0);
    fresh(@"wrong owner manager encoding");
    PDWrongOwnerReference *badOwner = [PDWrongOwnerReference new];
    badOwner->_scenePresentationManager = M;
    badOwner->_activePresentersByPriority = O->_activePresentersByPriority;
    badOwner->_inactivePresentersByPriority = O->_inactivePresentersByPriority;
    badOwner->_prioritizedPresenter = N;
    M->_scenePresenterOwner = (id)badOwner; error = nil;
    CHECK([PDPresenterLease stageWithManager:M owner:badOwner nativePresenter:N onChange:^{} error:&error] == nil && error != nil && M.factoryCalls == 0);
    fresh(@"missing owner manager reference");
    PDMissingOwnerReference *missingOwner = [PDMissingOwnerReference new];
    missingOwner->_activePresentersByPriority = O->_activePresentersByPriority;
    missingOwner->_inactivePresentersByPriority = O->_inactivePresentersByPriority;
    missingOwner->_prioritizedPresenter = N;
    M->_scenePresenterOwner = (id)missingOwner; error = nil;
    CHECK([PDPresenterLease stageWithManager:M owner:missingOwner nativePresenter:N onChange:^{} error:&error] == nil && error != nil && M.factoryCalls == 0);
    fresh(@"nil owner manager reference"); O->_scenePresentationManager = nil; error = nil;
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 0);
}

static void testPriorities(void) {
    NSError *error = nil;
    fresh(@"negative signed priority plus one");
    N->_sortContext = (id<NSCopying, _UIComparable>)[NSNumber numberWithLongLong:-8];
    PDPresenterLease *lease = stage(^{}, &error);
    CHECK(lease != nil && error == nil && M.lastPriority == -7);
    CHECK([lease cancelWithError:nil] && restored());
    fresh(@"NSIntegerMin plus one");
    N->_sortContext = (id<NSCopying, _UIComparable>)[NSNumber numberWithInteger:NSIntegerMin];
    lease = stage(^{}, nil);
    CHECK(lease != nil && M.lastPriority == NSIntegerMin + 1);
    CHECK([lease cancelWithError:nil] && restored());
    fresh(@"NSIntegerMax minus one is accepted exactly once");
    N->_sortContext = (id<NSCopying, _UIComparable>)[NSNumber numberWithInteger:NSIntegerMax - 1];
    lease = stage(^{}, nil);
    CHECK(lease != nil && M.lastPriority == NSIntegerMax && M.factoryCalls == 1);
    CHECK([lease activateWithError:nil] && M.lastPriority == NSIntegerMax && M.factoryCalls == 1);
    CHECK([lease cancelWithError:nil] && restored());
    fresh(@"NSIntegerMax must not overflow"); error = nil;
    N->_sortContext = (id<NSCopying, _UIComparable>)[NSNumber numberWithInteger:NSIntegerMax];
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 0);
    fresh(@"ULLONG_MAX must not wrap signed"); error = nil;
    N->_sortContext = (id<NSCopying, _UIComparable>)[NSNumber numberWithUnsignedLongLong:ULLONG_MAX];
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 0);
    fresh(@"unsigned value above NSIntegerMax"); error = nil;
    N->_sortContext = (id<NSCopying, _UIComparable>)[NSNumber numberWithUnsignedLongLong:(unsigned long long)NSIntegerMax + 1ULL];
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 0);
    fresh(@"fractional priority"); error = nil;
    N->_sortContext = (id<NSCopying, _UIComparable>)[NSNumber numberWithDouble:3.25];
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 0);
    fresh(@"nonnumeric priority"); error = nil;
    N->_sortContext = (id<NSCopying, _UIComparable>)@"41";
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 0);
    fresh(@"missing sort context"); error = nil; N->_sortContext = nil;
    CHECK(stage(^{}, &error) == nil && error != nil && M.factoryCalls == 0);
}
static void testNativeOwnerContract(void) {
    // These are refusal assertions, NOT xfails. A lease must not accept an
    // input native presenter whose typed owner reference cannot be proven.
    fresh(@"native presenter references different owner");
    N->_owner = [_UIScenePresenterOwner new];
    NSError *error = nil;
    PDPresenterLease *lease = stage(^{}, &error);
    CHECK(lease == nil && error != nil && M.factoryCalls == 0);
    [lease cancelWithError:nil]; // Isolate later cases even when this assertion fails.

    fresh(@"native presenter missing owner ivar");
    PDMissingNativeOwner *missing = [PDMissingNativeOwner new];
    missing->_sortContext = (id<NSCopying, _UIComparable>)@41;
    O->_activePresentersByPriority = [NSMutableOrderedSet orderedSetWithObject:missing];
    O->_prioritizedPresenter = (id)missing; error = nil;
    lease = [PDPresenterLease stageWithManager:M owner:O nativePresenter:missing onChange:^{} error:&error];
    CHECK(lease == nil && error != nil && M.factoryCalls == 0);
    [lease cancelWithError:nil];

    fresh(@"native presenter wrong owner ivar encoding");
    PDWrongNativeOwner *wrong = [PDWrongNativeOwner new];
    wrong->_owner = O;
    wrong->_sortContext = (id<NSCopying, _UIComparable>)@41;
    O->_activePresentersByPriority = [NSMutableOrderedSet orderedSetWithObject:wrong];
    O->_prioritizedPresenter = (id)wrong; error = nil;
    lease = [PDPresenterLease stageWithManager:M owner:O nativePresenter:wrong onChange:^{} error:&error];
    CHECK(lease == nil && error != nil && M.factoryCalls == 0);
    [lease cancelWithError:nil];
}
int main(void) { @autoreleasepool {
    @try {
        testABI();
        testLifecycle();
        testFactoryFaults();
        testFactoryReentry();
        testActivationReentry();
        testCleanupTicket();
        testOperationReentry();
        testOperationThrow();
        testOwnerOriginalForwarding();
        testSignals();
        testEligibility();
        testPriorities();
        testNativeOwnerContract();
        caseName = @"global forbidden invalidations";
        CHECK(managerInvalidations == 0 && ownerInvalidations == 0 && nativeInvalidations == 0 && containerInvalidations == 0);
        CHECK([PDPresenterLease cancelOutstandingWithError:nil]);
    } @catch (NSException *exception) {
        failures++;
        fprintf(stderr, "LEASE UNCAUGHT %s: %s: %s\n", caseName.UTF8String,
            exception.name.UTF8String, exception.reason.UTF8String);
    }
    printf("PANDORA_PRESENTER_LEASE_TESTS checks=%lu failures=%lu\n",
        (unsigned long)checks, (unsigned long)failures);
    return failures ? 1 : 0;
} }
