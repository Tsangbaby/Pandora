#import "PDHostTransformer.h"
#import "PDABI.h"
#import <objc/message.h>
#import <math.h>

static BOOL PDFiniteAffine(CGAffineTransform t) {
    return isfinite(t.a) && isfinite(t.b) && isfinite(t.c) &&
        isfinite(t.d) && isfinite(t.tx) && isfinite(t.ty);
}
static BOOL PDHostTransformError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"com.tsangbaby.pandora.host-transform" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
BOOL PDNativeHostTransformerMatches(id value, CGAffineTransform expected) {
    if (!value || !PDFiniteAffine(expected)) return NO;
    Class target = NSClassFromString(@"UITransformer");
    SEL get = NSSelectorFromString(@"transform");
    if (!target || ![value isKindOfClass:target] || !PDMatches(value,get,@encode(CGAffineTransform),@[])) return NO;
    @try {
        CGAffineTransform actual = ((CGAffineTransform (*)(id,SEL))objc_msgSend)(value,get);
        return PDFiniteAffine(actual) && fabs(actual.a-expected.a)<=1e-10 &&
            fabs(actual.b-expected.b)<=1e-10 && fabs(actual.c-expected.c)<=1e-10 &&
            fabs(actual.d-expected.d)<=1e-10 && fabs(actual.tx-expected.tx)<=1e-10 &&
            fabs(actual.ty-expected.ty)<=1e-10;
    } @catch (__unused NSException *exception) { return NO; }
}
id PDCreateNativeHostTransformer(CGAffineTransform transform, NSError **error) {
    if (!PDFiniteAffine(transform)) { PDHostTransformError(error,@"变换系数不是有限数值，没有创建原生对象。"); return nil; }
    Class elementaryClass = NSClassFromString(@"UITransform");
    Class compositeClass = NSClassFromString(@"UIMutableTransformer");
    Class targetClass = NSClassFromString(@"UITransformer");
    SEL affine = NSSelectorFromString(@"transformWithCGAffineTransform:");
    SEL add = NSSelectorFromString(@"addTransform:reason:");
    if (!elementaryClass || !compositeClass || !targetClass ||
        ![compositeClass isSubclassOfClass:targetClass] ||
        !PDMatches(elementaryClass,affine,"@",@[[NSString stringWithUTF8String:@encode(CGAffineTransform)]]) ||
        !PDMatches(compositeClass,@selector(new),"@",@[]) ||
        !PDMethodMatches(class_getInstanceMethod(compositeClass,add),"v",@[@"@",@"@"])) {
        PDHostTransformError(error,@"原生组合变换构造 ABI 不匹配。"); return nil;
    }
    @try {
        // This factory intentionally creates only an elementary UITransform.
        id elementary = ((id (*)(id,SEL,CGAffineTransform))objc_msgSend)(elementaryClass,affine,transform);
        if (!elementary || ![elementary isKindOfClass:elementaryClass]) {
            PDHostTransformError(error,@"原生基础变换创建失败。"); return nil;
        }
        id composite = [compositeClass new];
        if (!composite || ![composite isKindOfClass:compositeClass]) {
            PDHostTransformError(error,@"原生组合变换创建失败。"); return nil;
        }
        ((void (*)(id,SEL,id,id))objc_msgSend)(composite,add,elementary,@"com.tsangbaby.pandora.host-transform");
        if (!PDNativeHostTransformerMatches(composite,transform)) {
            PDHostTransformError(error,@"原生组合变换类型或矩阵回查不匹配。"); return nil;
        }
        // NO copy/mutableCopy here. The verified iOS15.4.1 context store/copy
        // preserves this evaluated object; transform-copy does not. A later
        // layout update must build a NEW object, never mutate this one.
        return composite;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: @"无详细原因";
        if (reason.length>160) reason = [[reason substringToIndex:160] stringByAppendingString:@"…"];
        PDHostTransformError(error,[NSString stringWithFormat:@"组合变换异常 %@：%@",exception.name ?: @"NSException",reason]);
        return nil;
    }
}
