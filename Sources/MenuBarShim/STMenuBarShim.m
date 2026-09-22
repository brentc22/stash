#import "include/STMenuBarShim.h"
#import <dlfcn.h>
#import <objc/message.h>

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

+ (nullable id)activateWithAllowedBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers
                                  allowedSystemItems:(NSArray<NSNumber *> *)systemItems
                                          completion:(void (^)(NSError *_Nullable))completion {
    if (![self isAvailable]) { return nil; }

    Class configClass = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");

    SEL initSel = NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:");
    if (![configClass instancesRespondToSelector:initSel]) { return nil; }

    // performSelector:withObject:withObject: instead of NSInvocation: this exact form
    // was proven working on this machine on 2026-09-22. The NSInvocation approach with
    // an __unsafe_unretained return value read off an -init method is ARC-fragile and
    // was never actually verified.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id builtConfig = [[configClass alloc]
        performSelector:initSel
             withObject:systemItems
             withObject:bundleIdentifiers];
#pragma clang diagnostic pop
    if (builtConfig == nil) { return nil; }

    id assertion = [[assertionClass alloc] init];
    SEL activateSel = NSSelectorFromString(@"activateWithConfiguration:completionHandler:");
    if (![assertion respondsToSelector:activateSel]) { return nil; }

    // NSInvocation stays here because this selector takes two arguments plus a block;
    // performSelector cannot express that shape.
    NSMethodSignature *sig = [assertion methodSignatureForSelector:activateSel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = assertion;
    inv.selector = activateSel;
    [inv setArgument:&builtConfig atIndex:2];
    id handler = [completion copy];
    [inv setArgument:&handler atIndex:3];
    [inv invoke];

    return assertion;
}

+ (void)invalidate:(nullable id)token {
    if (token == nil) { return; }
    SEL sel = NSSelectorFromString(@"invalidate");
    if ([token respondsToSelector:sel]) {
        ((void (*)(id, SEL))objc_msgSend)(token, sel);
    }
}

@end
