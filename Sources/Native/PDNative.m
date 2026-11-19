#import "PDNative.h"
#import "PDABI.h"
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

@protocol PDLayerHostConstruction <NSObject>
- (instancetype)initWithSceneLayer:(id)layer;
- (void)setCurrentPresentationContext:(id)context;
@end

@interface PDSceneSession ()
@property (nonatomic, strong, readwrite) UIView *hostedView;
@property (nonatomic, readwrite) CGSize sourceSize;
@property (nonatomic, strong) id scene;
@property (nonatomic, strong) id context;
@property (nonatomic, copy) NSString *sceneIdentifier;
@end

@implementation PDSceneSession
+ (instancetype)captureWithError:(NSError **)error {
    if (!NSThread.isMainThread) { PDError(error, @"必须在主线程操作。"); return nil; }
    PDSceneSession *session = [self new];
    @try {
        if (!PDProbeCanPresent()) {
            PDError(error, @"此探针仅支持当前前台的备忘录。请先打开一篇非敏感测试笔记。"); return nil;
        }
        NSString *identifier = PDSceneIdentifier();
        id scene = PDScene(identifier);
        Class sceneClass = NSClassFromString(@"FBScene");
        if (!sceneClass || ![scene isKindOfClass:sceneClass] ||
            !PDTrue(scene, NSSelectorFromString(@"isValid")) ||
            !PDTrue(scene, NSSelectorFromString(@"isActive"))) {
            PDError(error, @"未取得有效的前台 FBScene；没有启动或新建场景。"); return nil;
        }
        id settings = PDObject(scene, @"settings");
        SEL frameSelector = NSSelectorFromString(@"frame");
        if (!PDMatches(settings, frameSelector, @encode(CGRect), @[])) {
            PDError(error, @"Scene frame 的 ABI 不匹配，已拒绝调用。"); return nil;
        }
        CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(settings, frameSelector);
        if (!isfinite(frame.origin.x) || !isfinite(frame.origin.y) ||
            !isfinite(frame.size.width) || !isfinite(frame.size.height) ||
            fabs(frame.origin.x) > 0.5 || fabs(frame.origin.y) > 0.5 ||
            frame.size.width < 160 || frame.size.height < 160 ||
            frame.size.width > 8192 || frame.size.height > 8192) {
            PDError(error, @"仅支持原生全屏、有效尺寸的前台场景。"); return nil;
        }
        id layersObject = PDObject(PDObject(scene, @"layerManager"), @"layers");
        NSArray *layers = nil;
        if ([layersObject isKindOfClass:NSArray.class]) layers = layersObject;
        else if ([layersObject isKindOfClass:NSOrderedSet.class]) layers = [layersObject array];
        else if ([layersObject isKindOfClass:NSSet.class]) layers = [layersObject allObjects];
        if (!layers.count || layers.count > 16) {
            PDError(error, @"场景层列表不受支持，未创建宿主。"); return nil;
        }
        id contentLayer = nil;
        Class layerClass = NSClassFromString(@"FBSceneLayer");
        for (id layer in layers) {
            SEL keyboard = NSSelectorFromString(@"isKeyboardLayer");
            SEL proxy = NSSelectorFromString(@"isKeyboardProxyLayer");
            SEL contextID = NSSelectorFromString(@"contextID");
            if (!layerClass || ![layer isKindOfClass:layerClass] ||
                !PDMatches(layer, keyboard, @encode(BOOL), @[]) ||
                !PDMatches(layer, proxy, @encode(BOOL), @[]) ||
                !PDMatches(layer, contextID, "I", @[])) {
                PDError(error, @"场景层类型或 ABI 不匹配。"); return nil;
            }
            if (((BOOL (*)(id, SEL))objc_msgSend)(layer, keyboard) ||
                ((BOOL (*)(id, SEL))objc_msgSend)(layer, proxy)) continue;
            if (!((unsigned int (*)(id, SEL))objc_msgSend)(layer, contextID)) continue;
            if (contentLayer) {
                PDError(error, @"检测到多个内容层；此最小探针不猜测层序，请关闭弹窗后重试。"); return nil;
            }
            contentLayer = layer;
        }
        Class hostClass = NSClassFromString(@"_UIContextLayerHostView");
        Class contextClass = NSClassFromString(@"UIScenePresentationContext");
        if (!contentLayer || ![hostClass isSubclassOfClass:UIView.class] || !contextClass) {
            PDError(error, @"场景宿主类型不可用。"); return nil;
        }
        id<PDLayerHostConstruction> allocated = [hostClass alloc];
        if (!PDMatches(allocated, @selector(initWithSceneLayer:), "@", @[@"@"]) ||
            !PDMatches(allocated, @selector(setCurrentPresentationContext:), "v", @[@"@"])) {
            PDError(error, @"场景宿主接口不可用；没有退回截图。"); return nil;
        }
        session.scene = scene;
        session.sceneIdentifier = identifier;
        session.sourceSize = frame.size;
        session.context = [contextClass new];
        if (!session.context) { PDError(error, @"呈现上下文创建失败。"); return nil; }
        id<PDLayerHostConstruction> host = [allocated initWithSceneLayer:contentLayer];
        if (![host isKindOfClass:UIView.class]) { PDError(error, @"宿主创建失败。"); return nil; }
        session.hostedView = (UIView *)host;
        [host setCurrentPresentationContext:session.context];
        session.hostedView.userInteractionEnabled = YES;
        if (!session.remainsForeground) {
            [session invalidate]; PDError(error, @"准备期间前台场景已改变，已取消。"); return nil;
        }
        return session;
    } @catch (__unused NSException *exception) {
        [session invalidate]; PDError(error, @"私有接口抛出异常；已撤销本探针持有的视图。"); return nil;
    }
}

- (BOOL)remainsForeground {
    if (!self.scene || !PDProbeCanPresent()) return NO;
    @try {
        NSString *identifier = PDSceneIdentifier();
        return [identifier isEqualToString:self.sceneIdentifier] && PDScene(identifier) == self.scene &&
            PDTrue(self.scene, NSSelectorFromString(@"isValid")) &&
            PDTrue(self.scene, NSSelectorFromString(@"isActive"));
    } @catch (__unused NSException *exception) { return NO; }
}

- (BOOL)requestFocusWithError:(NSError **)error {
    if (!self.remainsForeground) return PDError(error, @"原前台场景已失效，拒绝焦点请求。");
    @try {
        id focus = PDObject(PDWorkspace(), @"keyboardFocusController");
        SEL selector = NSSelectorFromString(@"userFocusRequestForScene:reason:");
        if (!PDMatches(focus, selector, "v", @[@"@", @"@"]))
            return PDError(error, @"焦点接口 ABI 不匹配。");
        ((void (*)(id, SEL, id, id))objc_msgSend)(focus, selector, self.scene,
            @"com.tsangbaby.pandora.manual-probe");
        return YES; // Request issued, NOT an assertion that text input succeeded.
    } @catch (__unused NSException *exception) { return PDError(error, @"焦点请求异常，请结束实验。"); }
}

- (void)invalidate {
    NSAssert(NSThread.isMainThread, @"Main-thread UI cleanup required");
    [self.hostedView removeFromSuperview];
    self.hostedView = nil;
    self.context = nil;
    self.scene = nil;
    self.sceneIdentifier = nil;
    // Never changed native Scene settings, presenter, lifecycle or assertion tokens.
}
@end

@implementation PDSystemWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
@end

@interface PDOverlayLease ()
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) id hosting;
@property (nonatomic, strong) id orientationObserver;
@property (nonatomic, copy) dispatch_block_t orientationChanged;
@property (nonatomic) unsigned int contextID;
@property (nonatomic) BOOL invalidated;
@end

@implementation PDOverlayLease
+ (instancetype)attachWindow:(UIWindow *)window
         onOrientationChange:(dispatch_block_t)changed error:(NSError **)error {
    if (!NSThread.isMainThread) { PDError(error, @"系统窗口须由主线程创建。"); return nil; }
    PDOverlayLease *lease = [self new];
    lease.window = window;
    @try {
        lease.orientationObserver = [NSClassFromString(@"FBSOrientationObserver") new];
        SEL orientation = NSSelectorFromString(@"activeInterfaceOrientation");
        SEL handler = NSSelectorFromString(@"setHandler:");
        // This probe is portrait-only. Any rotation closes it, rather than guessing geometry.
        if (!PDMatches(lease.orientationObserver, orientation, @encode(NSInteger), @[]) ||
            !PDMatches(lease.orientationObserver, handler, "v", @[@"@?"]) ||
            !PDMatches(lease.orientationObserver, NSSelectorFromString(@"invalidate"), "v", @[]) ||
            ((NSInteger (*)(id, SEL))objc_msgSend)(lease.orientationObserver, orientation) != 1) {
            [lease invalidate]; PDError(error, @"本轮探针仅验证竖屏；旋转会安全退出。"); return nil;
        }
        lease.orientationChanged = changed;
        __weak PDOverlayLease *weakLease = lease;
        void (^orientationCallback)(id) = ^(__unused id update) {
            dispatch_async(dispatch_get_main_queue(), ^{
                PDOverlayLease *live = weakLease;
                if (!live || live.invalidated) return;
                NSInteger value = ((NSInteger (*)(id, SEL))objc_msgSend)(live.orientationObserver, orientation);
                if (value != 1 && live.orientationChanged) live.orientationChanged();
            });
        };
        ((void (*)(id, SEL, id))objc_msgSend)(lease.orientationObserver, handler, orientationCallback);
        lease.hosting = [NSClassFromString(@"SBSAccessibilityWindowHostingController") new];
        SEL registerWindow = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
        SEL unregisterWindow = NSSelectorFromString(@"unregisterWindowWithContextID:");
        SEL context = NSSelectorFromString(@"_contextId");
        if (!PDMatches(lease.hosting, registerWindow, "v", @[@"I", @"d"]) ||
            !PDMatches(lease.hosting, unregisterWindow, "v", @[@"I"]) ||
            !PDMatches(lease.hosting, NSSelectorFromString(@"invalidate"), "v", @[]) ||
            !PDMatches(window, context, "I", @[])) {
            [lease invalidate]; PDError(error, @"系统窗口注册接口不匹配。"); return nil;
        }
        window.windowLevel = UIWindowLevelStatusBar + 1;
        window.hidden = NO; // Deliberately never makeKeyWindow: retain native keyboard ownership.
        [window layoutIfNeeded];
        lease.contextID = ((unsigned int (*)(id, SEL))objc_msgSend)(window, context);
        if (!lease.contextID) { [lease invalidate]; PDError(error, @"系统窗口 contextID 为零。"); return nil; }
        ((void (*)(id, SEL, unsigned int, double))objc_msgSend)(lease.hosting, registerWindow,
            lease.contextID, (double)window.windowLevel);
        return lease;
    } @catch (__unused NSException *exception) {
        [lease invalidate]; PDError(error, @"系统窗口创建异常，已执行清理。"); return nil;
    }
}

- (void)invalidate {
    NSAssert(NSThread.isMainThread, @"Main-thread window cleanup required");
    if (self.invalidated) return;
    self.invalidated = YES;
    self.window.hidden = YES;
    self.window.rootViewController = nil;
    SEL unregisterWindow = NSSelectorFromString(@"unregisterWindowWithContextID:");
    @try {
        if (self.contextID && PDMatches(self.hosting, unregisterWindow, "v", @[@"I"]))
            ((void (*)(id, SEL, unsigned int))objc_msgSend)(self.hosting, unregisterWindow, self.contextID);
    } @catch (__unused NSException *exception) { NSLog(@"[Pandora] window unregister exception"); }
    @try {
        SEL invalidate = NSSelectorFromString(@"invalidate");
        if (PDMatches(self.hosting, invalidate, "v", @[]))
            ((void (*)(id, SEL))objc_msgSend)(self.hosting, invalidate);
    } @catch (__unused NSException *exception) { NSLog(@"[Pandora] window invalidation exception"); }
    self.contextID = 0;
    self.orientationChanged = nil;
    @try {
        SEL handler = NSSelectorFromString(@"setHandler:");
        if (PDMatches(self.orientationObserver, handler, "v", @[@"@?"]))
            ((void (*)(id, SEL, id))objc_msgSend)(self.orientationObserver, handler, nil);
    } @catch (__unused NSException *exception) {}
    @try {
        SEL invalidate = NSSelectorFromString(@"invalidate");
        if (PDMatches(self.orientationObserver, invalidate, "v", @[]))
            ((void (*)(id, SEL))objc_msgSend)(self.orientationObserver, invalidate);
    } @catch (__unused NSException *exception) {}
    self.orientationObserver = nil;
    self.hosting = nil;
    self.window = nil;
}
@end
