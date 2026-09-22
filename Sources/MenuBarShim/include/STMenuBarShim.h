#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin layer around the private MenuBarClientCore framework.
/// Everything related to dlopen and NSClassFromString lives here and nowhere else.
@interface STMenuBarShim : NSObject

/// NO when the framework or either of the two classes is missing.
/// Call this once at startup and cache the result.
+ (BOOL)isAvailable;

@end

NS_ASSUME_NONNULL_END
