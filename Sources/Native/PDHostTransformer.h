#import <Foundation/Foundation.h>
#import <CoreGraphics/CGAffineTransform.h>

NS_ASSUME_NONNULL_BEGIN
// Each call builds a fresh composite. After publication to a context, never
// mutate or freeze-copy it: the target context retains the evaluated object.
FOUNDATION_EXPORT id _Nullable PDCreateNativeHostTransformer(CGAffineTransform transform,
    NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL PDNativeHostTransformerMatches(id _Nullable value, CGAffineTransform expected);
NS_ASSUME_NONNULL_END
