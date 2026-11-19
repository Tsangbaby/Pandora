#import "PDNative.h"
#import "PDABI.h"
#import "PDPresenterLease.h"
#import "PDNativeProfile.h"
#import <objc/message.h>
#import <math.h>

static NSString *const PDNotes = @"com.apple.mobilenotes";
static BOOL PDError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"com.tsangbaby.pandora.probe" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}
static id PDObject(id target, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!PDMatches(target, selector, "@", @[])) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}
static id PDObjectArgument(id target, NSString *name, id value) {
    SEL selector = NSSelectorFromString(name);
    if (!PDMatches(target, selector, "@", @[@"@"])) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(target, selector, value);
}
static id PDWorkspace(void) { return PDObject(NSClassFromString(@"SBMainWorkspace"), @"sharedInstance"); }
static NSString *PDFrontBundle(void) {
    id application = PDObject(UIApplication.sharedApplication, @"_accessibilityFrontMostApplication");
    id value = PDObject(application, @"bundleIdentifier");
    return [value isKindOfClass:NSString.class] ? value : nil;
}
static BOOL PDTrue(id receiver, SEL selector) {
    return PDMatches(receiver, selector, @encode(BOOL), @[]) &&
        ((BOOL (*)(id, SEL))objc_msgSend)(receiver, selector);
}

BOOL PDProbeCanPresent(void) {
    if (!NSThread.isMainThread) return NO;
    @try {
        id lock = PDObject(NSClassFromString(@"SBLockScreenManager"), @"sharedInstance");
        SEL locked = NSSelectorFromString(@"isUILocked");
        return PDMatches(lock, locked, @encode(BOOL), @[]) &&
            !((BOOL (*)(id, SEL))objc_msgSend)(lock, locked) &&
            [PDFrontBundle() isEqualToString:PDNotes];
    } @catch (__unused NSException *exception) { return NO; }
}

static NSString *PDSceneIdentifier(void) {
    // iOS 15.4.1: SBMainWorkspace.sceneManager is nil even with Notes frontmost.
    // Use existing main-display Scenes, never a fabricated/default Scene ID.
    if (![PDFrontBundle() isEqualToString:PDNotes]) return nil;
    id manager = PDObject(NSClassFromString(@"SBSceneManagerCoordinator"), @"mainDisplaySceneManager");
    id scenes = PDObject(manager, @"allScenes");
    if (!([scenes isKindOfClass:NSSet.class] || [scenes isKindOfClass:NSArray.class] ||
          [scenes isKindOfClass:NSOrderedSet.class]) || [scenes count] > 128) return nil;
    id frontBoard = PDObject(NSClassFromString(@"FBSceneManager"), @"sharedInstance");
    Class sceneClass = NSClassFromString(@"FBScene");
    if (!frontBoard || !sceneClass) return nil;
    NSString *identifier = nil;
    for (id scene in scenes) {
        if (![scene isKindOfClass:sceneClass]) return nil;
        id bundle = PDObject(PDObject(scene, @"clientProcess"), @"bundleIdentifier");
        if (![bundle isKindOfClass:NSString.class]) return nil;
        if (![bundle isEqualToString:PDNotes]) continue;
        if (!PDMatches(scene, NSSelectorFromString(@"isValid"), @encode(BOOL), @[]) ||
            !PDMatches(scene, NSSelectorFromString(@"isActive"), @encode(BOOL), @[]) ||
            !PDMatches(scene, NSSelectorFromString(@"accessibilitySceneIsForegroundVisible"), @encode(BOOL), @[])) return nil;
        if (!PDTrue(scene, NSSelectorFromString(@"isValid")) ||
            !PDTrue(scene, NSSelectorFromString(@"isActive")) ||
            !PDTrue(scene, NSSelectorFromString(@"accessibilitySceneIsForegroundVisible"))) continue;
        id value = PDObject(scene, @"identifier");
        if (identifier || ![value isKindOfClass:NSString.class] || ![value length] ||
            PDObjectArgument(frontBoard, @"sceneWithIdentifier:", value) != scene) return nil;
        identifier = value;
    }
    return [PDFrontBundle() isEqualToString:PDNotes] ? identifier : nil;
}

static id PDScene(NSString *identifier) {
    id manager = PDObject(NSClassFromString(@"FBSceneManager"), @"sharedInstance");
    return identifier ? PDObjectArgument(manager, @"sceneWithIdentifier:", identifier) : nil;
}


static BOOL PDLiveFlag(id object, const char *name) {
    BOOL value = YES;
    return PDLeaseFlag(object,name,&value) && !value;
}
static BOOL PDNativeFrame(CGRect frame) {
    return isfinite(frame.origin.x) && isfinite(frame.origin.y) && isfinite(frame.size.width) && isfinite(frame.size.height) &&
        fabs(frame.origin.x)<0.5 && fabs(frame.origin.y)<0.5 && frame.size.width>=160 && frame.size.height>=160 &&
        frame.size.width<=8192 && frame.size.height<=8192;
}
static NSDictionary *PDNativeSnapshot(NSError **error) {
    if (!PDProbeCanPresent()) { PDError(error,@"请先在竖屏打开前台备忘录；没有创建或激活场景。"); return nil; }
    NSString *identifier = PDSceneIdentifier(); id scene = PDScene(identifier);
    if (![scene isKindOfClass:NSClassFromString(@"FBScene")] || !PDTrue(scene,NSSelectorFromString(@"isValid")) ||
        !PDTrue(scene,NSSelectorFromString(@"isActive"))) { PDError(error,@"未取得唯一有效的前台 Notes Scene。"); return nil; }
    id manager = PDReadCachedPresentationManager(scene);
    if (![manager isKindOfClass:NSClassFromString(@"UIScenePresentationManager")] ||
        !PDLiveFlag(manager,"_invalidated") || PDLeaseObject(manager,"_scene","@\"FBScene\"") != scene) {
        PDError(error,@"未读到受支持的既有原生管理器；不会另建管理器。"); return nil;
    }
    id owner = PDLeaseObject(manager,"_scenePresenterOwner","@\"_UIScenePresenterOwner\"");
    if (![owner isKindOfClass:NSClassFromString(@"_UIScenePresenterOwner")] || !PDLiveFlag(owner,"_invalidated") ||
        PDLeaseObject(owner,"_scenePresentationManager","@\"UIScenePresentationManager\"") != manager ||
        PDLeaseObject(owner,"_context","@") != scene) { PDError(error,@"原生所有者关系不受支持。"); return nil; }
    NSArray *active = PDLeaseMembers(PDLeaseObject(owner,"_activePresentersByPriority","@\"NSMutableOrderedSet\""));
    NSArray *inactive = PDLeaseMembers(PDLeaseObject(owner,"_inactivePresentersByPriority","@\"NSMutableSet\""));
    id native = PDLeaseObject(owner,"_prioritizedPresenter","@\"_UIScenePresenter\"");
    if (active.count!=1 || active.firstObject!=native || !inactive || inactive.count || !native || !PDLiveFlag(native,"_invalidated")) {
        PDError(error,@"此候选只接受一个稳定原生呈现者，没有接管。"); return nil;
    }
    UIView *nativeView = PDLeaseObject(native,"_view","@\"_UIScenePresentationView\"");
    if (![nativeView isKindOfClass:UIView.class]) { PDError(error,@"原生呈现视图尚未准备好，没有加载视图。"); return nil; }
    UIWindow *window = nativeView.window;
    UIViewController *parent = window.rootViewController;
    UIView *root = parent.viewIfLoaded;
    if (![window isKindOfClass:NSClassFromString(@"SBMainSwitcherWindow")] || window.hidden || window.alpha<0.99 ||
        window.screen!=UIScreen.mainScreen || !root || root.window!=window || root.hidden || root.alpha<0.99 ||
        ![nativeView isDescendantOfView:root] || !CGAffineTransformIsIdentity(root.transform) ||
        !PDTrue(window,NSSelectorFromString(@"_usesWindowServerHitTesting")) ||
        !PDTrue(window,NSSelectorFromString(@"_isWindowServerHostingManaged"))) {
        PDError(error,@"既有原生窗口、根视图或事件通路不符合候选前提，没有创建窗口。"); return nil;
    }
    id settings = PDObject(scene,@"settings"); SEL getFrame = NSSelectorFromString(@"frame");
    if (!PDMatches(settings,getFrame,@encode(CGRect),@[])) { PDError(error,@"Scene 几何 ABI 不匹配。"); return nil; }
    CGRect frame = ((CGRect (*)(id,SEL))objc_msgSend)(settings,getFrame);
    if (!PDNativeFrame(frame) || !PDNativeFrame(root.bounds) ||
        fabs(root.bounds.size.width-frame.size.width)>0.5 || fabs(root.bounds.size.height-frame.size.height)>0.5) {
        PDError(error,@"此候选仅支持竖屏全尺寸、同一坐标平面。"); return nil;
    }
    UIView *container = PDLeaseObject(owner,"_realSceneHostViewsContainer","@\"_UISceneLayerHostContainerView\"");
    if (![container isKindOfClass:UIView.class] || !PDLiveFlag(container,"_invalidated") ||
        PDLeaseObject(container,"_scene","@\"FBScene\"")!=scene ||
        PDLeaseObject(nativeView,"_hostContainerView","@\"_UISceneLayerHostContainerView\"")!=container) {
        PDError(error,@"原生完整层容器关系不一致，未接管。"); return nil;
    }
    if (!PDProbeCanPresent() || PDScene(identifier)!=scene || PDReadCachedPresentationManager(scene)!=manager)
        { PDError(error,@"准备期间前台或场景改变，已取消。"); return nil; }
    return @{@"scene":scene,@"identifier":identifier,@"manager":manager,@"owner":owner,@"native":native,
        @"nativeView":nativeView,@"window":window,@"parent":parent,@"root":root,@"container":container,@"frame":[NSValue valueWithCGRect:frame]};
}

@interface PDSceneSession ()
@property (nonatomic, strong, readwrite) UIView *hostedView;
@property (nonatomic, readwrite) CGSize sourceSize;
@property (nonatomic, strong) NSDictionary *snapshot;
@property (nonatomic, strong) PDPresenterLease *lease;
@property (nonatomic, weak) UIView *carrier;
@property (nonatomic) CGRect baseFrame;
@property (nonatomic) BOOL activated;
@property (nonatomic) BOOL frameConfigured;
@end

@implementation PDSceneSession
+ (BOOL)cancelPendingWithError:(NSError **)error {
    return [PDPresenterLease cancelOutstandingWithError:error];
}
+ (instancetype)captureInView:(UIView *)carrier onOwnershipChange:(dispatch_block_t)changed error:(NSError **)error {
    if (!NSThread.isMainThread) { PDError(error,@"必须在主线程操作。"); return nil; }
    NSDictionary *snapshot = PDNativeSnapshot(error);
    if (!snapshot) return nil;
    if (carrier.window!=snapshot[@"window"] || ![carrier isDescendantOfView:snapshot[@"root"]] ||
        !CGAffineTransformIsIdentity(carrier.transform)) {
        PDError(error,@"卡片不在已验证的同一原生坐标层级中，没有创建呈现者。"); return nil;
    }
    PDSceneSession *session = [self new]; session.snapshot = snapshot; session.carrier = carrier;
    session.sourceSize = [snapshot[@"frame"] CGRectValue].size;
    @try {
        session.lease = [PDPresenterLease stageWithManager:snapshot[@"manager"] owner:snapshot[@"owner"]
            nativePresenter:snapshot[@"native"] onChange:changed error:error];
        if (!session.lease) return nil;
        BOOL prepared = [session.lease performOperation:^BOOL{
            id p = session.lease.presenter;
            UIView *view = PDObject(p,@"presentationView"); // Inactive own view, native defaults.
            if (![view isKindOfClass:NSClassFromString(@"_UIScenePresentationView")] || view.superview ||
                !CGAffineTransformIsIdentity(view.transform) || !PDNativeFrame(view.frame) ||
                fabs(view.bounds.size.width-session.sourceSize.width)>0.5 || fabs(view.bounds.size.height-session.sourceSize.height)>0.5) return NO;
            session.hostedView = view; session.baseFrame = view.frame;
            [carrier addSubview:view];
            return view.window==snapshot[@"window"] && PDProbeCanPresent();
        } error:error];
        if (!prepared) {
            [session finishWithError:nil]; PDError(error,@"原生视图准备失败或已取消，已尝试只撤销实验对象。"); return nil;
        }
        return session;
    } @catch (__unused NSException *exception) {
        [session finishWithError:nil]; PDError(error,@"原生准备异常，已尝试只撤销实验对象。"); return nil;
    }
}
- (BOOL)matchesCurrentEnvironment {
    NSDictionary *s = self.snapshot;
    UIWindow *window = s[@"window"]; UIViewController *parent = s[@"parent"]; UIView *root = s[@"root"];
    return s && !self.lease.ended && PDProbeCanPresent() &&
        PDScene(s[@"identifier"])==s[@"scene"] && PDReadCachedPresentationManager(s[@"scene"])==s[@"manager"] &&
        PDLeaseObject(s[@"manager"],"_scenePresenterOwner","@\"_UIScenePresenterOwner\"")==s[@"owner"] &&
        window.rootViewController==parent && parent.viewIfLoaded==root && root.window==window &&
        !window.hidden && !root.hidden && self.carrier.window==window && self.hostedView.window==window &&
        [self.carrier isDescendantOfView:root] && PDTrue(s[@"scene"],NSSelectorFromString(@"isValid")) &&
        PDTrue(s[@"scene"],NSSelectorFromString(@"isActive"));
}
- (BOOL)updateFrame:(CGRect)frame error:(NSError **)error {
    if (!NSThread.isMainThread || ![self matchesCurrentEnvironment] ||
        (self.activated && !self.lease.readyForInput)) return PDError(error,@"原生呈现关系变化，拒绝布局或输入。");
    PDHostMapping mapping;
    CGRect base = self.baseFrame;
    if (!PDMakeHostMapping(base.origin.x,base.origin.y,base.size.width,base.size.height,
        frame.origin.x,frame.origin.y,frame.size.width,frame.size.height,&mapping) ||
        !CGRectContainsRect(self.carrier.bounds,frame)) return PDError(error,@"目标卡片几何无效，拒绝变换。");
    CGFloat sx = mapping.a;
    CGAffineTransform transform = CGAffineTransformMake(mapping.a,mapping.b,mapping.c,mapping.d,mapping.tx,mapping.ty);
    Class transformClass = NSClassFromString(@"UITransformer");
    Class baseTransformClass = NSClassFromString(@"UITransform");
    SEL factory = NSSelectorFromString(@"transformWithCGAffineTransform:");
    if (!transformClass || ![transformClass isSubclassOfClass:baseTransformClass] ||
        !PDMatches(transformClass,factory,"@",@[[NSString stringWithUTF8String:@encode(CGAffineTransform)]]))
        return PDError(error,@"原生 UITransformer 工厂 ABI 不匹配。");
    @try {
        __block NSString *failure = @"原生布局操作被取消。";
        BOOL updated = [self.lease performOperation:^BOOL{
        id value = ((id (*)(id,SEL,CGAffineTransform))objc_msgSend)(transformClass,factory,transform);
        if (!value || ![value isKindOfClass:transformClass]) { failure = @"原生工厂未返回 UITransformer。"; return NO; }
        __block BOOL applied = NO;
        void (^modify)(id) = ^(id context) {
            SEL setter = NSSelectorFromString(@"setHostTransformer:");
            if ([context isKindOfClass:NSClassFromString(@"UIMutableScenePresentationContext")] &&
                PDMatches(context,setter,"v",@[@"@"])) {
                ((void (*)(id,SEL,id))objc_msgSend)(context,setter,value); applied = YES;
            }
        };
        SEL change = NSSelectorFromString(@"modifyPresentationContext:");
        ((void (*)(id,SEL,id))objc_msgSend)(self.lease.presenter,change,modify);
        if (!applied) { failure = @"原生上下文未接收几何变换。"; return NO; }
        self.hostedView.clipsToBounds = YES;
        self.hostedView.layer.cornerRadius = 16/sx; // Only our presentation view.
        CGRect actual = [self.hostedView convertRect:self.hostedView.bounds toView:self.carrier];
        if (fabs(actual.origin.x-frame.origin.x)>0.5 || fabs(actual.origin.y-frame.origin.y)>0.5 ||
            fabs(actual.size.width-frame.size.width)>0.5 || fabs(actual.size.height-frame.size.height)>0.5)
            { failure = @"原生坐标变换回查不匹配，未判定托管成功。"; return NO; }
        self.frameConfigured = YES; return YES;
        } error:error];
        return updated ? YES : PDError(error,failure);
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: @"无详细原因";
        if (reason.length > 160) reason = [[reason substringToIndex:160] stringByAppendingString:@"…"];
        return PDError(error,[NSString stringWithFormat:@"原生上下文更新异常 %@：%@；已撤销实验。",exception.name ?: @"NSException",reason]);
    }
}
- (BOOL)activateWithError:(NSError **)error {
    if (!self.frameConfigured || ![self matchesCurrentEnvironment]) return PDError(error,@"呈现尚未准备好，未激活。");
    if (![self.lease activateWithError:error]) return NO;
    self.activated = YES;
    if (!self.remainsForeground ||
        PDLeaseObject(self.hostedView,"_hostContainerView","@\"_UISceneLayerHostContainerView\"")!=self.snapshot[@"container"])
        return PDError(error,@"原生完整层承载回查失败，需撤销实验。");
    return YES;
}
- (BOOL)remainsForeground {
    @try { return self.activated && self.lease.readyForInput && [self matchesCurrentEnvironment]; }
    @catch (__unused NSException *exception) { return NO; }
}
- (BOOL)requestFocusWithError:(NSError **)error {
    if (!self.remainsForeground) return PDError(error,@"原生承载或前台已变化，拒绝焦点请求。");
    @try {
        id focus = PDObject(PDWorkspace(),@"keyboardFocusController"); SEL selector=NSSelectorFromString(@"userFocusRequestForScene:reason:");
        if (!PDMatches(focus,selector,"v",@[@"@",@"@"])) return PDError(error,@"焦点接口 ABI 不匹配。");
        ((void (*)(id,SEL,id,id))objc_msgSend)(focus,selector,self.snapshot[@"scene"],@"com.tsangbaby.pandora.manual-native-probe");
        return YES; // A request, never a claim that actual text reached Notes.
    } @catch (__unused NSException *exception) { return PDError(error,@"焦点请求异常，请结束实验。"); }
}
- (BOOL)finishWithError:(NSError **)error {
    if (!NSThread.isMainThread) return PDError(error,@"清理必须在主线程。");
    self.activated = NO;
    if (self.lease && ![self.lease cancelWithError:error]) return NO;
    [self.hostedView removeFromSuperview]; self.hostedView = nil;
    self.lease = nil; self.snapshot = nil; self.carrier = nil;
    return YES;
}
@end

@interface PDOverlayLease ()
@property (nonatomic, strong) UIViewController *controller;
@property (nonatomic, weak) UIViewController *parent;
@property (nonatomic, weak) UIView *nativeRoot;
@property (nonatomic, weak) UIWindow *nativeWindow;
@property (nonatomic, strong) id orientationObserver;
@property (nonatomic, copy) dispatch_block_t invalidationHandler;
@property (nonatomic) BOOL invalidated;
@property (nonatomic) BOOL retiring;
@property (nonatomic) BOOL retirementRequested;
@property (nonatomic) NSUInteger attachDepth;
@end
static PDOverlayLease *PDPendingOverlay;

@implementation PDOverlayLease
+ (BOOL)finishPendingWithError:(NSError **)error {
    if (!NSThread.isMainThread) return PDError(error,@"清理必须在主线程。");
    return !PDPendingOverlay || [PDPendingOverlay finishWithError:error];
}
+ (instancetype)attachController:(UIViewController *)controller onInvalidation:(dispatch_block_t)changed error:(NSError **)error {
    if (!NSThread.isMainThread || controller.parentViewController || PDPendingOverlay) {
        PDError(error,@"控制视图已有父控制器或上一清理未确认，禁止重复附加。"); return nil;
    }
    NSDictionary *snapshot = PDNativeSnapshot(error); if (!snapshot) return nil;
    PDOverlayLease *lease = [self new];
    lease.controller = controller; lease.parent = snapshot[@"parent"];
    lease.nativeRoot = snapshot[@"root"]; lease.nativeWindow = snapshot[@"window"]; lease.invalidationHandler = changed;
    PDPendingOverlay = lease; // Exists before the first observer/containment side effect.
    lease.attachDepth++;
    @try {
        lease.orientationObserver = [NSClassFromString(@"FBSOrientationObserver") new];
        SEL orientation = NSSelectorFromString(@"activeInterfaceOrientation"), handler = NSSelectorFromString(@"setHandler:");
        if (!PDMatches(lease.orientationObserver,orientation,@encode(NSInteger),@[]) ||
            !PDMatches(lease.orientationObserver,handler,"v",@[@"@?"]) ||
            !PDMatches(lease.orientationObserver,NSSelectorFromString(@"invalidate"),"v",@[]) ||
            ((NSInteger (*)(id,SEL))objc_msgSend)(lease.orientationObserver,orientation)!=1) {
            [lease finishWithError:nil]; PDError(error,@"此候选仅支持竖屏；不会修改系统方向。"); return nil;
        }
        __weak PDOverlayLease *weakLease = lease;
        void (^orientationCallback)(id) = ^(__unused id update) {
            dispatch_async(dispatch_get_main_queue(), ^{
                PDOverlayLease *live = weakLease;
                if (!live || live.invalidated) return;
                NSInteger value = ((NSInteger (*)(id,SEL))objc_msgSend)(live.orientationObserver,orientation);
                if (value!=1 && live.invalidationHandler) live.invalidationHandler();
            });
        };
        ((void (*)(id,SEL,id))objc_msgSend)(lease.orientationObserver,handler,orientationCallback);
        [lease.parent addChildViewController:controller];
        controller.view.frame = lease.nativeRoot.bounds;
        controller.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [lease.nativeRoot addSubview:controller.view];
        [controller didMoveToParentViewController:lease.parent];
        if (!lease.valid || lease.retirementRequested) { [lease finishWithError:nil]; PDError(error,@"根视图准备期间变化或已取消，没有接管场景。"); return nil; }
        return lease;
    } @catch (__unused NSException *exception) {
        [lease finishWithError:nil]; PDError(error,@"控制层准备异常，已尝试移除自己的视图。"); return nil;
    } @finally {
        lease.attachDepth--;
        if (lease.retirementRequested) [lease finishWithError:nil];
    }
}
- (BOOL)allowsDeferredFinish {
    // Foreground/root validity can be lost while a native operation unwinds.
    // It must not prevent the FIRST deferred cleanup; an already-attempted
    // retirement, including a failed one, must not enqueue its own retry.
    return NSThread.isMainThread && !self.invalidated && !self.retiring && !self.retirementRequested && !self.attachDepth;
}
- (BOOL)valid {
    return NSThread.isMainThread && !self.invalidated && !self.retiring && !self.retirementRequested && self.controller && self.parent && self.nativeRoot && self.nativeWindow &&
        PDProbeCanPresent() && !self.nativeWindow.hidden && self.nativeWindow.rootViewController==self.parent &&
        self.parent.viewIfLoaded==self.nativeRoot && self.nativeRoot.window==self.nativeWindow &&
        self.controller.parentViewController==self.parent && self.controller.viewIfLoaded.superview==self.nativeRoot &&
        self.controller.viewIfLoaded.window==self.nativeWindow && CGAffineTransformIsIdentity(self.nativeRoot.transform);
}
- (BOOL)finishWithError:(NSError **)error {
    if (!NSThread.isMainThread) return PDError(error,@"清理必须在主线程。");
    if (self.invalidated) return YES;
    self.retirementRequested = YES;
    if (self.attachDepth || self.retiring) return PDError(error,@"控制层调用未退出或正在清理，票据已保留。");
    if (![PDPresenterLease cancelOutstandingWithError:error]) return NO;
    self.retiring = YES; self.invalidationHandler = nil;
    BOOL success = YES;
    @try { if (self.controller.parentViewController) [self.controller willMoveToParentViewController:nil]; }
    @catch (__unused NSException *e) { success = NO; }
    @try { [self.controller.viewIfLoaded removeFromSuperview]; }
    @catch (__unused NSException *e) { success = NO; }
    @try { if (self.controller.parentViewController) [self.controller removeFromParentViewController]; }
    @catch (__unused NSException *e) { success = NO; }
    @try {
        if (self.orientationObserver) {
            SEL invalidate=NSSelectorFromString(@"invalidate");
            if (!PDMatches(self.orientationObserver,invalidate,"v",@[])) success = NO;
            else { ((void (*)(id,SEL))objc_msgSend)(self.orientationObserver,invalidate); self.orientationObserver = nil; }
        }
    } @catch (__unused NSException *e) { success = NO; }
    if (self.controller.parentViewController || self.controller.viewIfLoaded.superview || self.orientationObserver) success = NO;
    self.retiring = NO;
    if (!success) return PDError(error,@"控制层清理未确认，票据仍保留且禁止重复附加；没有修改原生窗口。");
    self.invalidated = YES; self.controller = nil;
    self.parent = nil; self.nativeRoot = nil; self.nativeWindow = nil;
    if (PDPendingOverlay == self) PDPendingOverlay = nil;
    return YES; // Never hide, re-key, unregister or clear the borrowed native window.
}
@end
