#import <Foundation/Foundation.h>
#import "PDABI.h"

@interface PDFake : NSObject
+ (id)shared;
- (id)object;
- (void)take:(id)value reason:(id)reason;
- (BOOL)flag;
- (unsigned int)context;
- (void)handler:(void (^)(id))block;
@end
@implementation PDFake
+ (id)shared { return [self new]; }
- (id)object { return self; }
- (void)take:(id)value reason:(id)reason { (void)value; (void)reason; }
- (BOOL)flag { return NO; }
- (unsigned int)context { return 1; }
- (void)handler:(void (^)(id))block { (void)block; }
@end

static unsigned count;
#define CHECK(test) do { count++; if (!(test)) { fprintf(stderr, "ABI FAIL line %d\n", __LINE__); return 1; } } while (0)
int main(void) { @autoreleasepool {
    PDFake *value = [PDFake new];
    CHECK(PDMatches(PDFake.class, @selector(shared), "@", @[]));
    CHECK(PDMatches(value, @selector(object), "@", @[]));
    CHECK(!PDMatches(nil, @selector(object), "@", @[]));
    CHECK(!PDMatches(value, NSSelectorFromString(@"missing"), "@", @[]));
    CHECK(!PDMatches(value, @selector(object), "v", @[]));
    CHECK(!PDMatches(value, @selector(object), "@", @[@"@"]));
    CHECK(PDMatches(value, @selector(take:reason:), "v", @[@"@", @"@"]));
    CHECK(!PDMatches(value, @selector(take:reason:), "v", @[@"@"]));
    CHECK(!PDMatches(value, @selector(take:reason:), "v", @[@"I", @"@"]));
    CHECK(PDMatches(value, @selector(flag), @encode(BOOL), @[]));
    CHECK(!PDMatches(value, @selector(flag), "@", @[]));
    CHECK(PDMatches(value, @selector(context), "I", @[]));
    CHECK(!PDMatches(value, @selector(context), "Q", @[]));
    CHECK(PDMatches(value, @selector(handler:), "v", @[@"@?"]));
    CHECK(!PDMatches(value, @selector(handler:), "v", @[@"@"]));
    CHECK(PDTypeEqual("r@\"NSString\"", "@"));
    CHECK(!PDTypeEqual("@?", "@"));
    CHECK(!PDTypeEqual("^v", "@"));
    printf("PANDORA_ABI_TESTS checks=%u failures=0\n", count);
    return 0;
} }
