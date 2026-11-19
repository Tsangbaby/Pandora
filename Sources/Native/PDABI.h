#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <string.h>

// Class objects are checked through their metaclass. Never invoke a mismatched IMP.
static inline BOOL PDTypeEqual(const char *actual, const char *expected) {
    while (*actual && strchr("rnNoORV", *actual)) actual++;
    if (strcmp(expected, "@") == 0) return actual[0] == '@' && actual[1] != '?';
    return strcmp(actual, expected) == 0;
}
static inline BOOL PDMethodMatches(Method method, const char *result, NSArray<NSString *> *arguments) {
    if (!method || method_getNumberOfArguments(method) != arguments.count + 2) return NO;
    char type[256] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (!PDTypeEqual(type, result)) return NO;
    for (NSUInteger i = 0; i < arguments.count; i++) {
        memset(type, 0, sizeof(type));
        method_getArgumentType(method, (unsigned)i + 2, type, sizeof(type));
        if (!PDTypeEqual(type, arguments[i].UTF8String)) return NO;
    }
    return YES;
}

static inline BOOL PDMatches(id target, SEL selector, const char *result, NSArray<NSString *> *arguments) {
    return target && PDMethodMatches(class_getInstanceMethod(object_getClass(target), selector), result, arguments);
}
