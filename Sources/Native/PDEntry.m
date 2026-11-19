#import "PDABI.h"
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <substrate.h>

static void (*PDOriginalFrontChanged)(id, SEL, id);
static BOOL PDLifecycleReady;

static void PDRuntime(const char *name) {
    id runtime = objc_getClass("PDProbeRuntime");
    SEL selector = sel_registerName(name);
    if (PDMatches(runtime, selector, "v", @[]))
        ((void (*)(id, SEL))objc_msgSend)(runtime, selector);
}

static void PDFrontChanged(id self, SEL command, id display) {
    PDOriginalFrontChanged(self, command, display);
    if (NSThread.isMainThread) PDRuntime("foregroundChanged");
    else dispatch_async(dispatch_get_main_queue(), ^{ PDRuntime("foregroundChanged"); });
}

static void PDNotification(__unused CFNotificationCenterRef center,
                           __unused void *observer, CFStringRef name,
                           __unused const void *object, __unused CFDictionaryRef info) {
    BOOL show = CFEqual(name, CFSTR("com.tsangbaby.pandora.probe.show"));
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!show) PDRuntime("stopControls");
        else if (PDLifecycleReady) PDRuntime("showControls");
        else NSLog(@"[Pandora] Lifecycle ABI unavailable; controls remain off.");
    });
}

__attribute__((constructor)) static void PDInstall(void) {
    @autoreleasepool {
        NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
        if (os.majorVersion != 15 || os.minorVersion != 4 || os.patchVersion != 1 ||
            ![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        Class springBoard = objc_getClass("SpringBoard");
        SEL selector = sel_registerName("frontDisplayDidChange:");
        Method method = class_getInstanceMethod(springBoard, selector);
        if (PDMethodMatches(method, "v", @[@"@"])) {
            IMP original = NULL;
            MSHookMessageEx(springBoard, selector, (IMP)PDFrontChanged, &original);
            if (original) {
                PDOriginalFrontChanged = (void (*)(id, SEL, id))original;
                PDLifecycleReady = YES;
            }
        }
        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(center, NULL, PDNotification,
            CFSTR("com.tsangbaby.pandora.probe.show"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(center, NULL, PDNotification,
            CFSTR("com.tsangbaby.pandora.probe.stop"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(center, NULL, PDNotification,
            CFSTR("com.apple.springboard.lockstate"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
