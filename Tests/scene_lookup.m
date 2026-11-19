#import <Foundation/Foundation.h>
#import "PDABI.h"
#import <objc/message.h>
#include <stdio.h>

// Only the environment is doubled. The five lookup functions below are extracted
// byte-for-byte from the production PDNative.m by test_scene_lookup.py.
static NSString *const PDNotes = @"com.apple.mobilenotes";
static id mainManager;
static id fbManager;
static id beforeBundle;
static id afterBundle;
static NSUInteger frontReads;
static NSUInteger roundTripReads;
static NSUInteger checks;
static NSUInteger failures;
static NSString *caseName;

@interface MockProcess : NSObject
@property (nonatomic, strong) id bundleIdentifier;
@end
@implementation MockProcess
@end

@interface WrongBundleABI : NSObject
- (NSUInteger)bundleIdentifier;
@end
@implementation WrongBundleABI
- (NSUInteger)bundleIdentifier { abort(); }
@end

@interface FBScene : NSObject
@property (nonatomic, strong) id clientProcess;
@property (nonatomic, strong) id identifier;
@property (nonatomic) BOOL valid;
@property (nonatomic) BOOL active;
@property (nonatomic) BOOL visible;
- (BOOL)isValid;
- (BOOL)isActive;
- (BOOL)accessibilitySceneIsForegroundVisible;
@end
@implementation FBScene
- (BOOL)isValid { return self.valid; }
- (BOOL)isActive { return self.active; }
- (BOOL)accessibilitySceneIsForegroundVisible { return self.visible; }
@end

@interface SBMainDisplaySceneManager : NSObject
@property (nonatomic, strong) id allScenes;
@end
@implementation SBMainDisplaySceneManager
@end

@interface WrongCollectionABI : NSObject
- (NSUInteger)allScenes;
@end
@implementation WrongCollectionABI
- (NSUInteger)allScenes { abort(); }
@end

@interface SBSceneManagerCoordinator : NSObject
+ (id)mainDisplaySceneManager;
@end
@implementation SBSceneManagerCoordinator
+ (id)mainDisplaySceneManager { return mainManager; }
@end

@interface FBSceneManager : NSObject
@property (nonatomic, strong) NSMutableDictionary *lookup;
+ (id)sharedInstance;
- (id)sceneWithIdentifier:(id)identifier;
@end
@implementation FBSceneManager
+ (id)sharedInstance { return fbManager; }
- (id)sceneWithIdentifier:(id)identifier {
    roundTripReads++;
    return self.lookup[identifier];
}
@end

static NSString *PDFrontBundle(void) {
    return frontReads++ == 0 ? beforeBundle : afterBundle;
}
static id PDWorkspace(void) { return nil; } // Observed probe1 receiver chain is nil.
#include "scene-under-test.inc"

static void expect(BOOL pass, NSString *description) {
    checks++;
    if (!pass) {
        failures++;
        fprintf(stderr, "SCENE FAIL %s: %s\n", caseName.UTF8String, description.UTF8String);
    }
}
static NSUInteger wrongActive(id self, SEL selector) {
    (void)self; (void)selector; abort();
}
static FBScene *makeScene(id bundle, id identifier) {
    FBScene *scene = [FBScene new];
    MockProcess *process = [MockProcess new];
    process.bundleIdentifier = bundle;
    scene.clientProcess = process;
    scene.identifier = identifier;
    scene.valid = YES;
    scene.active = YES;
    scene.visible = YES;
    return scene;
}
static FBScene *reset(NSString *name) {
    caseName = name;
    frontReads = roundTripReads = 0;
    beforeBundle = afterBundle = PDNotes;
    SBMainDisplaySceneManager *main = [SBMainDisplaySceneManager new];
    FBSceneManager *fb = [FBSceneManager new];
    FBScene *scene = makeScene(PDNotes, @"sceneID:com.apple.mobilenotes-actual-session");
    main.allScenes = [NSSet setWithObject:scene];
    fb.lookup = [@{scene.identifier:scene} mutableCopy];
    mainManager = main;
    fbManager = fb;
    return scene;
}
static void replaceScenes(id scenes) { [(SBMainDisplaySceneManager *)mainManager setAllScenes:scenes]; }
static BOOL resolves(FBScene *scene) { return [PDSceneIdentifier() isEqual:scene.identifier]; }

int main(void) { @autoreleasepool {
    FBScene *scene = reset(@"unique native set");
    expect(resolves(scene), @"real Scene identifier resolves");
    expect(roundTripReads == 1, @"exactly one same-manager roundtrip");
    expect(frontReads == 2, @"foreground checked before and after");
    expect(PDScene(scene.identifier) == scene, @"existing PDScene helper preserves object identity");

    scene = reset(@"array collection"); replaceScenes(@[scene]);
    expect(resolves(scene), @"NSArray accepted");
    scene = reset(@"ordered set collection"); replaceScenes([NSOrderedSet orderedSetWithObject:scene]);
    expect(resolves(scene), @"NSOrderedSet accepted");

    reset(@"front is not Notes"); beforeBundle = @"com.openminis.app";
    expect(PDSceneIdentifier() == nil && roundTripReads == 0, @"no scene query for another front App");
    reset(@"front changed"); afterBundle = @"com.openminis.app";
    expect(PDSceneIdentifier() == nil, @"changed foreground rejected");
    reset(@"no main manager"); mainManager = nil;
    expect(PDSceneIdentifier() == nil, @"nil manager rejected");
    reset(@"unsupported manager ABI"); mainManager = [WrongCollectionABI new];
    expect(PDSceneIdentifier() == nil, @"wrong ABI not called");
    reset(@"nil collection"); replaceScenes(nil);
    expect(PDSceneIdentifier() == nil, @"nil collection rejected");
    reset(@"wrong collection type"); replaceScenes(@"not a collection");
    expect(PDSceneIdentifier() == nil, @"unknown collection rejected");
    reset(@"empty collection"); replaceScenes(@[]);
    expect(PDSceneIdentifier() == nil, @"zero scenes rejected");
    reset(@"non-Scene entry"); replaceScenes(@[[NSObject new]]);
    expect(PDSceneIdentifier() == nil, @"unknown scene type rejected");
    reset(@"nil FrontBoard manager"); fbManager = nil;
    expect(PDSceneIdentifier() == nil, @"roundtrip manager required");

    scene = reset(@"invalid Scene"); scene.valid = NO;
    expect(PDSceneIdentifier() == nil, @"invalid scene rejected");
    scene = reset(@"inactive Scene"); scene.active = NO;
    expect(PDSceneIdentifier() == nil, @"inactive scene rejected");
    scene = reset(@"not foreground visible"); scene.visible = NO;
    expect(PDSceneIdentifier() == nil, @"background/occluded scene rejected");
    scene = reset(@"nil process"); scene.clientProcess = nil;
    expect(PDSceneIdentifier() == nil, @"unreadable process rejected");
    scene = reset(@"wrong process ABI"); scene.clientProcess = [WrongBundleABI new];
    expect(PDSceneIdentifier() == nil, @"wrong bundle getter ABI never called");
    scene = reset(@"non-string bundle"); [(MockProcess *)scene.clientProcess setBundleIdentifier:@23];
    expect(PDSceneIdentifier() == nil, @"non-string bundle rejected");
    scene = reset(@"bundle substring impostor");
    [(MockProcess *)scene.clientProcess setBundleIdentifier:@"prefix.com.apple.mobilenotes.suffix"];
    expect(PDSceneIdentifier() == nil, @"substring match must not identify Notes");
    scene = reset(@"nil identifier"); scene.identifier = nil;
    expect(PDSceneIdentifier() == nil, @"nil identifier rejected");
    scene = reset(@"empty identifier"); scene.identifier = @"";
    expect(PDSceneIdentifier() == nil, @"empty identifier rejected");
    scene = reset(@"non-string identifier"); scene.identifier = @42;
    expect(PDSceneIdentifier() == nil, @"non-string identifier rejected");
    scene = reset(@"lookup returns nil"); [(FBSceneManager *)fbManager setLookup:[NSMutableDictionary new]];
    expect(PDSceneIdentifier() == nil, @"unresolved real identifier rejected");
    scene = reset(@"lookup returns different object");
    [(FBSceneManager *)fbManager setLookup:[@{scene.identifier:makeScene(PDNotes,scene.identifier)} mutableCopy]];
    expect(PDSceneIdentifier() == nil, @"equal identifier cannot replace object identity");

    scene = reset(@"two eligible Notes Scenes");
    FBScene *second = makeScene(PDNotes, @"sceneID:com.apple.mobilenotes-other-session");
    [(FBSceneManager *)fbManager lookup][second.identifier] = second;
    replaceScenes(@[scene,second]);
    expect(PDSceneIdentifier() == nil, @"ambiguous Notes scenes rejected");

    scene = reset(@"one active and one inactive Notes Scene");
    second = makeScene(PDNotes, @"sceneID:inactive"); second.active = NO;
    replaceScenes(@[second,scene]);
    expect(resolves(scene), @"unique eligible scene survives inactive companion");

    scene = reset(@"foreign Scene mentions Notes in identifier");
    FBScene *foreign = makeScene(@"com.example.foreign", @"sceneID:com.apple.mobilenotes-impostor");
    replaceScenes(@[foreign,scene]);
    expect(resolves(scene), @"process identity wins over identifier text");

    scene = reset(@"unreadable companion identity");
    foreign = makeScene(@42, @"unknown"); replaceScenes(@[scene,foreign]);
    expect(PDSceneIdentifier() == nil, @"unreadable identity prevents uniqueness proof");

    scene = reset(@"unreadable Notes companion state ABI");
    Class wrongState = objc_allocateClassPair(FBScene.class, "MockWrongActiveABI", 0);
    if (!wrongState || !class_addMethod(wrongState, @selector(isActive), (IMP)wrongActive, "Q16@0:8")) abort();
    objc_registerClassPair(wrongState);
    second = [wrongState new];
    second.clientProcess = scene.clientProcess;
    second.identifier = @"sceneID:unreadable-state";
    second.valid = second.visible = YES;
    replaceScenes(@[scene,second]);
    expect(PDSceneIdentifier() == nil, @"unknown Notes state ABI prevents uniqueness proof");

    scene = reset(@"too many scenes");
    NSMutableArray *oversized = [NSMutableArray new];
    for (NSUInteger i=0;i<129;i++) [oversized addObject:scene];
    replaceScenes(oversized);
    expect(PDSceneIdentifier() == nil && roundTripReads == 0, @"bounded collection checked before iteration");

    printf("PANDORA_SCENE_TESTS checks=%lu failures=%lu\n", (unsigned long)checks, (unsigned long)failures);
    return failures ? 1 : 0;
} }
