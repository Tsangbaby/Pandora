// Runtime environment doubles only: no UIKit or model of Apple context internals.
#import "PDHostTransformer.h"
#include <math.h>
#include <stdio.h>

static const CGAffineTransform A = {1.25, -0.5, 0.375, 0.75, 123.0, -42.5};
static const CGAffineTransform B = {-0.75, 0.25, 1.5, 2.0, -8.0, 61.0};

typedef enum {
    NoFault, FactoryNil, FactoryWrongType, FactoryThrows,
    NewNil, NewWrongType, AddIgnores, AddThrows,
} Fault;
static Fault fault;
static unsigned factoryCalls, newCalls, addCalls, validAdds, copyCalls, mutableCopyCalls;
static Class factoryReceiver;

@interface UITransform : NSObject
@property(nonatomic) CGAffineTransform transform;
+ (id)transformWithCGAffineTransform:(CGAffineTransform)matrix;
@end

@interface UITransformer : UITransform <NSCopying, NSMutableCopying>
@end

@interface UIMutableTransformer : UITransformer
- (void)addTransform:(UITransform *)elementary reason:(NSString *)reason;
@end

@implementation UITransform
- (instancetype)init {
    if ((self = [super init])) _transform = CGAffineTransformIdentity;
    return self;
}

+ (id)transformWithCGAffineTransform:(CGAffineTransform)matrix {
    ++factoryCalls;
    factoryReceiver = self;
    if (fault == FactoryNil) return nil;
    if (fault == FactoryWrongType) return [NSObject new];
    if (fault == FactoryThrows) [NSException raise:@"FixtureFactory" format:@"factory threw"];
    // Non-polymorphic, even when inherited by a subclass.
    UITransform *elementary = [UITransform new];
    elementary.transform = matrix;
    return elementary;
}
@end

@implementation UITransformer
// Deliberately lose the evaluated matrix. Do not make the double's copy safe.
- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    ++copyCalls;
    return [UITransformer new];
}

- (id)mutableCopyWithZone:(NSZone *)zone {
    (void)zone;
    ++mutableCopyCalls;
    return [UITransformer new];
}
@end

@implementation UIMutableTransformer
+ (instancetype)new {
    ++newCalls;
    if (fault == NewNil) return nil;
    if (fault == NewWrongType) return (id)[UITransformer new];
    return [super new];
}

- (void)addTransform:(UITransform *)elementary reason:(NSString *)reason {
    ++addCalls;
    if (fault == AddThrows) [NSException raise:@"FixtureAdd" format:@"add threw"];
    if ([elementary class] != [UITransform class] ||
        ![reason isKindOfClass:[NSString class]] || !reason.length) return;
    ++validAdds;
    // The fixture only needs the one-element composition used by the factory.
    if (fault != AddIgnores) self.transform = elementary.transform;
}
@end

static unsigned checks, failures;
#define CHECK(condition) do { \
    ++checks; \
    if (!(condition)) { \
        ++failures; \
        fprintf(stderr, "host_transformer.m:%d: %s\n", __LINE__, #condition); \
    } \
} while (0)

static void testConstruction(void) {
    NSArray *retained;
    __weak id priorA;
    @autoreleasepool {
        NSError *error = nil;
        id a = PDCreateNativeHostTransformer(A, &error);
        CHECK([a isKindOfClass:[UIMutableTransformer class]] && !error);
        CHECK(PDNativeHostTransformerMatches(a, A));
        CHECK(factoryCalls == 1 && factoryReceiver == [UITransform class]);
        CHECK(newCalls == 1 && addCalls == 1 && validAdds == 1);
        // Ordinary Foundation storage retains the evaluated object, not a copy.
        retained = a ? @[a] : @[];
        priorA = a;
    }

    NSError *error = nil;
    id b = PDCreateNativeHostTransformer(B, &error);
    id storedA = retained.firstObject;
    CHECK([b isKindOfClass:[UIMutableTransformer class]] && !error);
    CHECK(PDNativeHostTransformerMatches(b, B));
    CHECK(storedA && storedA == priorA && storedA != b);
    CHECK(PDNativeHostTransformerMatches(storedA, A));
    CHECK(factoryCalls == 2 && factoryReceiver == [UITransform class]);
    CHECK(newCalls == 2 && addCalls == 2 && validAdds == 2);
    CHECK(copyCalls == 0 && mutableCopyCalls == 0);

    // Negative control: sending the old factory to the subclass still yields
    // an elementary object with the right matrix but the wrong type.
    UITransform *old = [UITransformer transformWithCGAffineTransform:A];
    CHECK(factoryReceiver == [UITransformer class] && [old class] == [UITransform class]);
    CHECK(CGAffineTransformEqualToTransform(old.transform, A));
    CHECK(!PDNativeHostTransformerMatches(old, A));

    // Negative controls: both copies have an acceptable class but lose B.
    UITransformer *original = [b isKindOfClass:[UITransformer class]] ? b : nil;
    id copied = [original copy];
    id mutableCopied = [original mutableCopy];
    CHECK(copyCalls == 1 && mutableCopyCalls == 1);
    CHECK([copied class] == [UITransformer class] &&
          PDNativeHostTransformerMatches(copied, CGAffineTransformIdentity));
    CHECK(!PDNativeHostTransformerMatches(copied, B));
    CHECK([mutableCopied class] == [UITransformer class] &&
          PDNativeHostTransformerMatches(mutableCopied, CGAffineTransformIdentity));
    CHECK(!PDNativeHostTransformerMatches(mutableCopied, B));
    CHECK(PDNativeHostTransformerMatches(original, B));
}

static void testMatching(void) {
    UITransformer *probe = [UITransformer new];
    probe.transform = A;
    CHECK(PDNativeHostTransformerMatches(probe, A));
    CHECK(!PDNativeHostTransformerMatches(nil, A));

    probe.transform = (CGAffineTransform){A.a + 1, A.b, A.c, A.d, A.tx, A.ty};
    CHECK(!PDNativeHostTransformerMatches(probe, A)); // a
    probe.transform = (CGAffineTransform){A.a, A.b - 1, A.c, A.d, A.tx, A.ty};
    CHECK(!PDNativeHostTransformerMatches(probe, A)); // b
    probe.transform = (CGAffineTransform){A.a, A.b, A.c + 1, A.d, A.tx, A.ty};
    CHECK(!PDNativeHostTransformerMatches(probe, A)); // c
    probe.transform = (CGAffineTransform){A.a, A.b, A.c, A.d - 1, A.tx, A.ty};
    CHECK(!PDNativeHostTransformerMatches(probe, A)); // d
    probe.transform = (CGAffineTransform){A.a, A.b, A.c, A.d, A.tx + 1, A.ty};
    CHECK(!PDNativeHostTransformerMatches(probe, A)); // tx
    probe.transform = (CGAffineTransform){A.a, A.b, A.c, A.d, A.tx, A.ty - 1};
    CHECK(!PDNativeHostTransformerMatches(probe, A)); // ty

    probe.transform = (CGAffineTransform){A.a + 5e-11, A.b, A.c, A.d, A.tx, A.ty};
    CHECK(PDNativeHostTransformerMatches(probe, A)); // inside 1e-10
    probe.transform = (CGAffineTransform){A.a - 2e-10, A.b, A.c, A.d, A.tx, A.ty};
    CHECK(!PDNativeHostTransformerMatches(probe, A)); // outside 1e-10

    CGAffineTransform nanMatrix = A, infMatrix = A;
    nanMatrix.c = NAN;
    infMatrix.ty = INFINITY;
    probe.transform = nanMatrix;
    CHECK(!PDNativeHostTransformerMatches(probe, A));
    probe.transform = infMatrix;
    CHECK(!PDNativeHostTransformerMatches(probe, A));
    probe.transform = A;
    CHECK(!PDNativeHostTransformerMatches(probe, nanMatrix));
    CHECK(!PDNativeHostTransformerMatches(probe, infMatrix));
}

static BOOL rejects(CGAffineTransform matrix, Fault injected,
                    unsigned factories, unsigned news, unsigned adds) {
    unsigned beforeFactory = factoryCalls, beforeNew = newCalls, beforeAdd = addCalls;
    NSError *error = nil;
    fault = injected;
    id result = PDCreateNativeHostTransformer(matrix, &error);
    fault = NoFault;
    return result == nil && [error isKindOfClass:[NSError class]] &&
        error.localizedDescription.length > 0 && factoryCalls == beforeFactory + factories &&
        newCalls == beforeNew + news && addCalls == beforeAdd + adds;
}

static void testRejection(void) {
    CGAffineTransform nanMatrix = A, infMatrix = A;
    nanMatrix.a = NAN;
    infMatrix.tx = -INFINITY;
    CHECK(rejects(nanMatrix, NoFault, 0, 0, 0));
    CHECK(rejects(infMatrix, NoFault, 0, 0, 0));
    CHECK(rejects(A, FactoryNil,       1, 0, 0));
    CHECK(rejects(A, FactoryWrongType, 1, 0, 0));
    CHECK(rejects(A, FactoryThrows,    1, 0, 0));
    CHECK(rejects(A, NewNil,           1, 1, 0));
    CHECK(rejects(A, NewWrongType,     1, 1, 0));
    CHECK(rejects(A, AddIgnores,       1, 1, 1));
    CHECK(rejects(A, AddThrows,        1, 1, 1));
}

int main(void) {
    @autoreleasepool {
        testConstruction();
        testMatching();
        testRejection();
        CHECK(copyCalls == 1 && mutableCopyCalls == 1); // Only the explicit controls.
        printf("PANDORA_HOST_TRANSFORMER_TESTS checks=%u failures=%u\n", checks, failures);
    }
    return failures ? 1 : 0;
}
