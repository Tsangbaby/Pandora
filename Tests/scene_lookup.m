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
#ifdef PD_SCENE_BASELINE
static id PDWorkspace(void) { return nil; } // Observed probe1 receiver chain is nil.
#endif
#include "scene-under-test.inc"

static NSString *lookupNotes(void) {
#ifdef PD_SCENE_BASELINE
    return PDSceneIdentifier();
#else
    return PDSceneIdentifier(PDNotes);
#endif
}

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
static FBScene *resetForBundle(NSString *name, NSString *bundle, NSString *identifier) {
    caseName = name;
    frontReads = roundTripReads = 0;
    beforeBundle = afterBundle = bundle;
    SBMainDisplaySceneManager *main = [SBMainDisplaySceneManager new];
    FBSceneManager *fb = [FBSceneManager new];
    FBScene *scene = makeScene(bundle, identifier);
    main.allScenes = [NSSet setWithObject:scene];
    fb.lookup = [@{scene.identifier:scene} mutableCopy];
    mainManager = main;
    fbManager = fb;
    return scene;
}
static FBScene *reset(NSString *name) {
    return resetForBundle(name, PDNotes, @"sceneID:com.apple.mobilenotes-actual-session");
}
static void replaceScenes(id scenes) { [(SBMainDisplaySceneManager *)mainManager setAllScenes:scenes]; }
static BOOL resolves(FBScene *scene) { return [lookupNotes() isEqual:scene.identifier]; }

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
    expect(lookupNotes() == nil && roundTripReads == 0, @"no scene query for another front App");
    reset(@"front changed"); afterBundle = @"com.openminis.app";
    expect(lookupNotes() == nil, @"changed foreground rejected");
    reset(@"no main manager"); mainManager = nil;
    expect(lookupNotes() == nil, @"nil manager rejected");
    reset(@"unsupported manager ABI"); mainManager = [WrongCollectionABI new];
    expect(lookupNotes() == nil, @"wrong ABI not called");
    reset(@"nil collection"); replaceScenes(nil);
    expect(lookupNotes() == nil, @"nil collection rejected");
    reset(@"wrong collection type"); replaceScenes(@"not a collection");
    expect(lookupNotes() == nil, @"unknown collection rejected");
    reset(@"empty collection"); replaceScenes(@[]);
    expect(lookupNotes() == nil, @"zero scenes rejected");
    reset(@"non-Scene entry"); replaceScenes(@[[NSObject new]]);
    expect(lookupNotes() == nil, @"unknown scene type rejected");
    reset(@"nil FrontBoard manager"); fbManager = nil;
    expect(lookupNotes() == nil, @"roundtrip manager required");

    scene = reset(@"invalid Scene"); scene.valid = NO;
    expect(lookupNotes() == nil, @"invalid scene rejected");
    scene = reset(@"inactive Scene"); scene.active = NO;
    expect(lookupNotes() == nil, @"inactive scene rejected");
    scene = reset(@"not foreground visible"); scene.visible = NO;
    expect(lookupNotes() == nil, @"background/occluded scene rejected");
    scene = reset(@"nil process"); scene.clientProcess = nil;
    expect(lookupNotes() == nil, @"unreadable process rejected");
    scene = reset(@"wrong process ABI"); scene.clientProcess = [WrongBundleABI new];
    expect(lookupNotes() == nil, @"wrong bundle getter ABI never called");
    scene = reset(@"non-string bundle"); [(MockProcess *)scene.clientProcess setBundleIdentifier:@23];
    expect(lookupNotes() == nil, @"non-string bundle rejected");
    scene = reset(@"bundle substring impostor");
    [(MockProcess *)scene.clientProcess setBundleIdentifier:@"prefix.com.apple.mobilenotes.suffix"];
    expect(lookupNotes() == nil, @"substring match must not identify Notes");
    scene = reset(@"nil identifier"); scene.identifier = nil;
    expect(lookupNotes() == nil, @"nil identifier rejected");
    scene = reset(@"empty identifier"); scene.identifier = @"";
    expect(lookupNotes() == nil, @"empty identifier rejected");
    scene = reset(@"non-string identifier"); scene.identifier = @42;
    expect(lookupNotes() == nil, @"non-string identifier rejected");
    scene = reset(@"lookup returns nil"); [(FBSceneManager *)fbManager setLookup:[NSMutableDictionary new]];
    expect(lookupNotes() == nil, @"unresolved real identifier rejected");
    scene = reset(@"lookup returns different object");
    [(FBSceneManager *)fbManager setLookup:[@{scene.identifier:makeScene(PDNotes,scene.identifier)} mutableCopy]];
    expect(lookupNotes() == nil, @"equal identifier cannot replace object identity");

    scene = reset(@"two eligible Notes Scenes");
    FBScene *second = makeScene(PDNotes, @"sceneID:com.apple.mobilenotes-other-session");
    [(FBSceneManager *)fbManager lookup][second.identifier] = second;
    replaceScenes(@[scene,second]);
    expect(lookupNotes() == nil, @"ambiguous Notes scenes rejected");

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
    expect(lookupNotes() == nil, @"unreadable identity prevents uniqueness proof");

    scene = reset(@"unreadable Notes companion state ABI");
    Class wrongState = objc_allocateClassPair(FBScene.class, "MockWrongActiveABI", 0);
    if (!wrongState || !class_addMethod(wrongState, @selector(isActive), (IMP)wrongActive, "Q16@0:8")) abort();
    objc_registerClassPair(wrongState);
    second = [wrongState new];
    second.clientProcess = scene.clientProcess;
    second.identifier = @"sceneID:unreadable-state";
    second.valid = second.visible = YES;
    replaceScenes(@[scene,second]);
    expect(lookupNotes() == nil, @"unknown Notes state ABI prevents uniqueness proof");

    scene = reset(@"too many scenes");
    NSMutableArray *oversized = [NSMutableArray new];
    for (NSUInteger i=0;i<129;i++) [oversized addObject:scene];
    replaceScenes(oversized);
    expect(lookupNotes() == nil && roundTripReads == 0, @"bounded collection checked before iteration");

#ifndef PD_SCENE_BASELINE
    NSString *const files = @"com.apple.DocumentsApp";
    NSString *const filesID = @"sceneID:fixture-files-session";
    scene = resetForBundle(@"Files exact process bundle", files, filesID);
    FBScene *notes = makeScene(PDNotes, @"sceneID:com.apple.DocumentsApp-owned-by-Notes");
    FBScene *impostor = makeScene(@"prefix.com.apple.DocumentsApp.suffix", @"sceneID:impostor");
    [(FBSceneManager *)fbManager lookup][notes.identifier] = notes;
    [(FBSceneManager *)fbManager lookup][impostor.identifier] = impostor;
    replaceScenes(@[notes,impostor,scene]);
    NSString *identifier = PDSceneIdentifier(files);
    expect([identifier isEqualToString:filesID], @"Files selected by exact process bundle, not identifier text");
    expect(roundTripReads == 1 && PDScene(identifier) == scene, @"Files identifier roundtrips to its own Scene");

    resetForBundle(@"Files requested with Notes foreground", files, filesID); beforeBundle = PDNotes;
    expect(PDSceneIdentifier(files) == nil && roundTripReads == 0, @"wrong foreground rejected before lookup");
    resetForBundle(@"Files loses foreground", files, filesID); afterBundle = PDNotes;
    expect(PDSceneIdentifier(files) == nil && frontReads == 2, @"Files lookup rechecks foreground");

    scene = resetForBundle(@"Files same ID different object", files, filesID);
    [(FBSceneManager *)fbManager lookup][filesID] = makeScene(files, filesID);
    expect(PDSceneIdentifier(files) == nil && roundTripReads == 1, @"same Files ID cannot replace object identity");

    scene = resetForBundle(@"two eligible Files Scenes", files, filesID);
    second = makeScene(files, @"sceneID:other-files-session");
    [(FBSceneManager *)fbManager lookup][second.identifier] = second;
    replaceScenes(@[scene,second]);
    expect(PDSceneIdentifier(files) == nil, @"ambiguous Files scenes rejected");
#endif

    printf("PANDORA_SCENE_TESTS checks=%lu failures=%lu\n", (unsigned long)checks, (unsigned long)failures);
    return failures ? 1 : 0;
} }
