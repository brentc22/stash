#import "include/STMenuBarShim.h"
#import <dlfcn.h>

static NSString *const kFrameworkPath =
    @"/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore";

@implementation STMenuBarShim

+ (BOOL)loadFramework {
    static BOOL loaded = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loaded = dlopen(kFrameworkPath.UTF8String, RTLD_NOW) != NULL;
    });
    return loaded;
}

+ (BOOL)isAvailable {
    if (![self loadFramework]) { return NO; }
    return NSClassFromString(@"MBAssessmentModeConfiguration") != nil
        && NSClassFromString(@"MBAssessmentModeAssertion") != nil;
}

@end
