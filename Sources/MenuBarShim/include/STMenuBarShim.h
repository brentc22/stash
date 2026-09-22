#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin layer around the private MenuBarClientCore framework.
/// Everything related to dlopen and NSClassFromString lives here and nowhere else.
@interface STMenuBarShim : NSObject

/// NO when the framework or either of the two classes is missing.
/// Call this once at startup and cache the result.
+ (BOOL)isAvailable;

/// Activates a new assertion. Returns a token you keep and later hand to
/// +invalidate:; nil when the framework is missing.
/// completion receives nil on success, otherwise the system's NSError.
/// NOTE: both arrays must be NSArray. An NSSet raises an exception.
+ (nullable id)activateWithAllowedBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers
                                  allowedSystemItems:(NSArray<NSNumber *> *)systemItems
                                          completion:(void (^)(NSError *_Nullable))completion;

/// Safe with nil.
+ (void)invalidate:(nullable id)token;

@end

NS_ASSUME_NONNULL_END
