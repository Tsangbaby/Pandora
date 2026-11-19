#import "PDPresenterLease.h"
#import "PDABI.h"
#import <objc/message.h>
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <substrate.h>
#endif

static BOOL PDLeaseError(NSError **error, NSString *text) {
    if (error) *error = [NSError errorWithDomain:@"com.tsangbaby.pandora.lease" code:1
        userInfo:@{NSLocalizedDescriptionKey:text}];
    return NO;
}
id PDLeaseObject(id object, const char *name, const char *encoding) {
    if (!object || !name || !encoding) return nil;
    Ivar field = class_getInstanceVariable(object_getClass(object), name);
    const char *type = field ? ivar_getTypeEncoding(field) : NULL;
    if (!type || strcmp(type, encoding)) return nil;
    ptrdiff_t offset = ivar_getOffset(field);
    if (offset < 0 || (size_t)offset + sizeof(id) > class_getInstanceSize(object_getClass(object))) return nil;
    return object_getIvar(object, field);
}
BOOL PDLeaseFlag(id object, const char *name, BOOL *value) {
    if (!object || !value) return NO;
    Ivar field = class_getInstanceVariable(object_getClass(object), name);
    const char *type = field ? ivar_getTypeEncoding(field) : NULL;
    if (!type || strcmp(type, @encode(BOOL))) return NO;
    ptrdiff_t offset = ivar_getOffset(field);
    if (offset < 0 || (size_t)offset + sizeof(BOOL) > class_getInstanceSize(object_getClass(object))) return NO;
    *value = *(const BOOL *)((__bridge const uint8_t *)object + offset);
    return YES;
}
NSArray *PDLeaseMembers(id collection) {
    if (!collection) return @[];
    if ([collection isKindOfClass:NSOrderedSet.class]) return [collection count] <= 64 ? [collection array] : nil;
    if ([collection isKindOfClass:NSSet.class]) return [collection count] <= 64 ? [collection allObjects] : nil;
    return nil;
}
static id PDLeaseGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return PDMatches(object, selector, "@", @[]) ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}
static BOOL PDLeaseCall(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!PDMatches(object, selector, "v", @[])) return NO;
    ((void (*)(id, SEL))objc_msgSend)(object, selector);
    return YES;
}
static NSArray *PDActive(id owner) {
    return PDLeaseMembers(PDLeaseObject(owner, "_activePresentersByPriority", "@\"NSMutableOrderedSet\""));
}
static NSArray *PDInactive(id owner) {
    return PDLeaseMembers(PDLeaseObject(owner, "_inactivePresentersByPriority", "@\"NSMutableSet\""));
}
static id PDPrioritized(id owner) {
    return PDLeaseObject(owner, "_prioritizedPresenter", "@\"_UIScenePresenter\"");
}

@interface PDPresenterLease ()
@property (nonatomic, strong, readwrite) id presenter;
@property (nonatomic, readwrite) BOOL ended;
@property (nonatomic, strong) id manager;
@property (nonatomic, strong) id owner;
@property (nonatomic, strong) id nativePresenter;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) dispatch_block_t onChange;
@property (nonatomic) BOOL lossLatched;
@property (nonatomic) BOOL releasing;
@property (nonatomic) BOOL activated;
@property (nonatomic) NSUInteger nativeDepth;
@property (nonatomic) BOOL notificationQueued;
@property (nonatomic) BOOL notificationDelivered;
- (void)noticeNativeChange;
- (void)deliverChangeIfReady;
@end
static PDPresenterLease *PDCurrentLease;
static NSUInteger PDNativeOwnerDepth;
static void (*PDOriginalActivate)(id, SEL, id);
static void (*PDOriginalDeactivate)(id, SEL, id);
static void (*PDOriginalInvalidate)(id, SEL, id);

static void PDNativeChange(id owner, id presenter) {
    if (!NSThread.isMainThread) return; // Native owner methods require main queue.
    PDPresenterLease *lease = PDCurrentLease;
    if (lease && !lease.ended && !lease.releasing && lease.owner == owner && lease.presenter != presenter)
        [lease noticeNativeChange];
}
static void PDOwnerActivate(id self, SEL command, id presenter) {
    BOOL main = NSThread.isMainThread;
    if (main) PDNativeOwnerDepth++;
    @try {
        PDNativeChange(self, presenter);
        PDOriginalActivate(self, command, presenter); // Exactly once, unmodified.
    } @finally {
        if (main) { PDNativeOwnerDepth--; [PDCurrentLease deliverChangeIfReady]; }
    }
}
static void PDOwnerDeactivate(id self, SEL command, id presenter) {
    BOOL main = NSThread.isMainThread;
    if (main) PDNativeOwnerDepth++;
    @try {
        PDNativeChange(self, presenter);
        PDOriginalDeactivate(self, command, presenter);
    } @finally {
        if (main) { PDNativeOwnerDepth--; [PDCurrentLease deliverChangeIfReady]; }
    }
}
static void PDOwnerInvalidate(id self, SEL command, id presenter) {
    BOOL main = NSThread.isMainThread;
    if (main) PDNativeOwnerDepth++;
    @try {
        PDNativeChange(self, presenter);
        PDOriginalInvalidate(self, command, presenter);
    } @finally {
        if (main) { PDNativeOwnerDepth--; [PDCurrentLease deliverChangeIfReady]; }
    }
}
static BOOL PDInstallOwnerSignals(void) {
#if defined(PD_LEASE_TESTING)
    return YES; // Fake environment; production pass-through wrappers are not installed.
#elif TARGET_OS_IPHONE
    static BOOL attempted, ready;
    if (attempted) return ready;
    attempted = YES;
    Class c = NSClassFromString(@"_UIScenePresenterOwner");
    SEL a = NSSelectorFromString(@"_activatePresenter:");
    SEL d = NSSelectorFromString(@"_deactivatePresenter:");
    SEL i = NSSelectorFromString(@"_invalidatePresenter:");
    if (!PDMethodMatches(class_getInstanceMethod(c,a), "v", @[@"@"]) ||
        !PDMethodMatches(class_getInstanceMethod(c,d), "v", @[@"@"]) ||
        !PDMethodMatches(class_getInstanceMethod(c,i), "v", @[@"@"])) return NO;
    IMP preA = method_getImplementation(class_getInstanceMethod(c,a));
    IMP preD = method_getImplementation(class_getInstanceMethod(c,d));
    IMP preI = method_getImplementation(class_getInstanceMethod(c,i));
    if (!preA || !preD || !preI) return NO;
    PDOriginalActivate = (void (*)(id,SEL,id))preA;
    PDOriginalDeactivate = (void (*)(id,SEL,id))preD;
    PDOriginalInvalidate = (void (*)(id,SEL,id))preI;
    IMP original = NULL;
    MSHookMessageEx(c,a,(IMP)PDOwnerActivate,&original);
    BOOL okA = original != NULL;
    if (original) PDOriginalActivate = (void (*)(id,SEL,id))original;
    original = NULL;
    MSHookMessageEx(c,d,(IMP)PDOwnerDeactivate,&original);
    BOOL okD = original != NULL;
    if (original) PDOriginalDeactivate = (void (*)(id,SEL,id))original;
    original = NULL;
    MSHookMessageEx(c,i,(IMP)PDOwnerInvalidate,&original);
    BOOL okI = original != NULL;
    if (original) PDOriginalInvalidate = (void (*)(id,SEL,id))original;
    ready = okA && okD && okI;
    // Any partial install remains pass-through; no native ownership was acquired.
    return ready;
#else
    return NO;
#endif
}
#if defined(PD_LEASE_TESTING)
void PDLeaseTestNativeChange(id owner, id presenter) { PDNativeChange(owner,presenter); }
void PDLeaseTestInvokeOwnerMutation(NSUInteger kind, id owner, id presenter, void (*original)(id,SEL,id)) {
    void (**slot)(id,SEL,id) = kind==0 ? &PDOriginalActivate : (kind==1 ? &PDOriginalDeactivate : &PDOriginalInvalidate);
    void (*saved)(id,SEL,id) = *slot;
    *slot = original;
    @try {
        SEL selector = NSSelectorFromString(kind==0 ? @"_activatePresenter:" : (kind==1 ? @"_deactivatePresenter:" : @"_invalidatePresenter:"));
        if (kind==0) PDOwnerActivate(owner,selector,presenter);
        else if (kind==1) PDOwnerDeactivate(owner,selector,presenter);
        else PDOwnerInvalidate(owner,selector,presenter);
    } @finally { *slot = saved; }
}
#endif

@implementation PDPresenterLease
+ (BOOL)cancelOutstandingWithError:(NSError **)error {
    if (!NSThread.isMainThread) return PDLeaseError(error,@"清理必须在主线程。");
    PDPresenterLease *lease = PDCurrentLease;
    return !lease || [lease cancelWithError:error];
}
- (void)noticeNativeChange {
    if (self.releasing || self.ended) return;
    self.lossLatched = YES; // Latch before original native mutation; never reacquire.
    [self deliverChangeIfReady];
}
- (void)deliverChangeIfReady {
    if (!self.lossLatched || self.releasing || self.ended || self.nativeDepth || PDNativeOwnerDepth ||
        self.notificationQueued || self.notificationDelivered || !self.onChange) return;
    self.notificationQueued = YES;
    __weak PDPresenterLease *weakLease = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        PDPresenterLease *lease = weakLease;
        lease.notificationQueued = NO;
        if (!lease || lease.ended || lease.releasing || PDCurrentLease != lease || !lease.onChange) return;
        if (lease.nativeDepth || PDNativeOwnerDepth) return; // Outermost unwind will enqueue again.
        lease.notificationDelivered = YES;
        lease.onChange();
    });
}
- (id)findOwnPresenter {
    NSArray *active = PDActive(self.owner), *inactive = PDInactive(self.owner);
    if (!active || !inactive) return nil;
    id found = nil;
    for (id p in [active arrayByAddingObjectsFromArray:inactive]) {
        if (PDLeaseObject(p,"_owner","@\"_UIScenePresenterOwner\"") != self.owner) continue;
        id identifier = PDLeaseGet(p,@"identifier");
        if ([identifier isKindOfClass:NSString.class] && [identifier isEqualToString:self.identifier]) {
            if (found && found != p) return nil;
            found = p;
        }
    }
    return found;
}
+ (instancetype)stageWithManager:(id)manager owner:(id)owner nativePresenter:(id)native
                        onChange:(dispatch_block_t)handler error:(NSError **)error {
    if (!NSThread.isMainThread || PDCurrentLease || !manager || !owner || !native || !handler) {
        PDLeaseError(error,@"已有实验事务或不在主线程，拒绝托管。"); return nil;
    }
    BOOL managerInvalid, ownerInvalid, presenterInvalid;
    NSArray *active = PDActive(owner), *inactive = PDInactive(owner);
    if (!PDLeaseFlag(manager,"_invalidated",&managerInvalid) || managerInvalid ||
        !PDLeaseFlag(owner,"_invalidated",&ownerInvalid) || ownerInvalid ||
        !PDLeaseFlag(native,"_invalidated",&presenterInvalid) || presenterInvalid ||
        PDLeaseObject(native,"_owner","@\"_UIScenePresenterOwner\"") != owner ||
        PDLeaseObject(manager,"_scenePresenterOwner","@\"_UIScenePresenterOwner\"") != owner ||
        PDLeaseObject(owner,"_scenePresentationManager","@\"UIScenePresentationManager\"") != manager ||
        active.count != 1 || active.firstObject != native || !inactive || inactive.count || PDPrioritized(owner) != native) {
        PDLeaseError(error,@"原生呈现者状态不唯一或已变化，没有创建实验呈现者。"); return nil;
    }
    NSNumber *sort = PDLeaseObject(native,"_sortContext","@\"<NSCopying><_UIComparable>\"");
    const char *type = [sort isKindOfClass:NSNumber.class] ? sort.objCType : NULL;
    if (!type || strlen(type) != 1 || !strchr("csilqCSILQ",type[0]) ||
        (strchr("CSILQ",type[0]) && sort.unsignedLongLongValue > (unsigned long long)NSIntegerMax) ||
        sort.longLongValue == NSIntegerMax) {
        PDLeaseError(error,@"原生优先级不是受支持整数或已经到上限，未创建实验呈现者。"); return nil;
    }
    NSInteger priority = (NSInteger)sort.longLongValue + 1; // Checked, once; never escalated.
    SEL factory = NSSelectorFromString(@"createPresenterWithIdentifier:priority:");
    if (!PDMatches(manager,factory,"@",@[[NSString stringWithUTF8String:"@"],[NSString stringWithUTF8String:@encode(NSInteger)]]) || !PDInstallOwnerSignals()) {
        PDLeaseError(error,@"原生工厂或交接通知 ABI 不匹配，未开始托管。"); return nil;
    }
    PDPresenterLease *lease = [self new];
    lease.manager = manager; lease.owner = owner; lease.nativePresenter = native;
    lease.identifier = [@"com.tsangbaby.pandora.probe3." stringByAppendingString:NSUUID.UUID.UUIDString];
    lease.onChange = handler;
    PDCurrentLease = lease; // Durable cleanup ticket exists before the factory.
    @try {
        lease.nativeDepth++;
        @try {
            lease.presenter = ((id (*)(id,SEL,id,NSInteger))objc_msgSend)(manager,factory,lease.identifier,priority);
        } @finally {
            lease.nativeDepth--;
            [lease deliverChangeIfReady];
        }
        id p = lease.presenter;
        if (!p || PDLeaseObject(p,"_owner","@\"_UIScenePresenterOwner\"") != owner ||
            !PDMatches(p,NSSelectorFromString(@"activate"),"v",@[]) ||
            !PDMatches(p,NSSelectorFromString(@"deactivate"),"v",@[]) ||
            !PDMatches(p,NSSelectorFromString(@"invalidate"),"v",@[]) ||
            !PDMatches(p,NSSelectorFromString(@"presentationView"),"@",@[]) ||
            !PDMatches(p,NSSelectorFromString(@"modifyPresentationContext:"),"v",@[@"@?"]) ||
            lease.lossLatched || PDPrioritized(owner) != native ||
            PDActive(owner).count != 1 || PDInactive(owner).count != 1 ||
            PDInactive(owner).firstObject != p) {
            [lease cancelWithError:nil];
            PDLeaseError(error,@"原生呈现者准备未满足事务条件，已尝试只撤销实验对象。"); return nil;
        }
        return lease;
    } @catch (__unused NSException *exception) {
        lease.presenter = [lease findOwnPresenter];
        BOOL cleaned = [lease cancelWithError:nil];
        PDLeaseError(error,cleaned ? @"呈现工厂异常；仅实验对象已撤销。" : @"呈现工厂异常且清理未确认，请关闭实验并回到原生界面。");
        return nil;
    }
}
- (BOOL)performOperation:(BOOL (^)(void))operation error:(NSError **)error {
    if (!NSThread.isMainThread || !operation || self.ended || self.releasing || self.lossLatched || PDCurrentLease != self)
        return PDLeaseError(error,@"实验事务已经关闭，拒绝原生操作。");
    self.nativeDepth++;
    BOOL result = NO;
    @try { result = operation(); }
    @finally { self.nativeDepth--; [self deliverChangeIfReady]; }
    return result && !self.lossLatched && !self.ended;
}
- (BOOL)activateWithError:(NSError **)error {
    if (!NSThread.isMainThread || self.ended || self.releasing || self.lossLatched || self.activated || PDCurrentLease != self)
        return PDLeaseError(error,@"实验事务已取消或失效，没有激活。");
    NSArray *active = PDActive(self.owner), *inactive = PDInactive(self.owner);
    if (active.count != 1 || active.firstObject != self.nativePresenter ||
        inactive.count != 1 || inactive.firstObject != self.presenter || PDPrioritized(self.owner) != self.nativePresenter)
        return PDLeaseError(error,@"准备期间原生呈现关系变化，没有激活。");
    @try {
        self.nativeDepth++;
        BOOL issued = NO;
        @try { issued = PDLeaseCall(self.presenter,@"activate"); }
        @finally { self.nativeDepth--; [self deliverChangeIfReady]; }
        if (!issued) return PDLeaseError(error,@"激活 ABI 不匹配。");
        self.activated = YES;
        if (![self readyForInput]) return PDLeaseError(error,@"实验未取得唯一原生承载，需撤销实验。");
        return YES;
    } @catch (__unused NSException *exception) { return PDLeaseError(error,@"原生激活异常，需撤销实验。"); }
}
- (BOOL)readyForInput {
    BOOL invalidated;
    return NSThread.isMainThread && self.activated && !self.ended && !self.releasing && !self.lossLatched &&
        PDCurrentLease == self && self.presenter &&
        PDLeaseFlag(self.presenter,"_invalidated",&invalidated) && !invalidated &&
        PDLeaseObject(self.presenter,"_owner","@\"_UIScenePresenterOwner\"") == self.owner &&
        PDPrioritized(self.owner) == self.presenter;
}
- (BOOL)cancelWithError:(NSError **)error {
    if (!NSThread.isMainThread) return PDLeaseError(error,@"清理必须在主线程。");
    if (self.ended) return YES;
    if (self.nativeDepth || PDNativeOwnerDepth) {
        [self noticeNativeChange];
        return PDLeaseError(error,@"原生调用尚未退出；已关闭输入并保留清理票据，禁止再次挂载。");
    }
    if (self.releasing) return PDLeaseError(error,@"清理进行中，拒绝重入。");
    self.releasing = YES; self.lossLatched = YES; self.onChange = nil;
    if (!self.presenter) self.presenter = [self findOwnPresenter];
    BOOL success = YES;
    id p = self.presenter;
    if (p) {
        if (PDLeaseObject(p,"_owner","@\"_UIScenePresenterOwner\"") != self.owner) success = NO;
        else {
            @try { if (!PDLeaseCall(p,@"deactivate")) success = NO; }
            @catch (__unused NSException *e) { success = NO; }
            @try { if (!PDLeaseCall(p,@"invalidate")) success = NO; }
            @catch (__unused NSException *e) { success = NO; }
            BOOL invalidated = NO;
            if (!PDLeaseFlag(p,"_invalidated",&invalidated) || !invalidated) success = NO;
        }
    }
    NSArray *active = PDActive(self.owner), *inactive = PDInactive(self.owner);
    if (!active || !inactive || (p && ([active containsObject:p] || [inactive containsObject:p] || PDPrioritized(self.owner) == p))) success = NO;
    if ([self findOwnPresenter]) success = NO;
    if (success) {
        self.ended = YES;
        if (PDCurrentLease == self) PDCurrentLease = nil;
        self.presenter = nil; self.manager = nil; self.owner = nil; self.nativePresenter = nil;
    }
    self.releasing = NO;
    return success ? YES : PDLeaseError(error,@"未确认实验呈现者已完全释放，禁止再次挂载。请先关闭实验检查原生界面。");
}
@end
