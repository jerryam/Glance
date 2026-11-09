#import "MenuBarBridge.h"
#import <dlfcn.h>
#import <objc/message.h>

static NSString *const GLConfigurationClass = @"MBAssessmentModeConfiguration";
static NSString *const GLAssertionClass = @"MBAssessmentModeAssertion";
static NSString *const GLInitSelector = @"initWithAllowedSystemItems:allowedBundleIdentifiers:";
static NSString *const GLActivateSelector = @"activateWithConfiguration:completionHandler:";
static NSString *const GLInvalidateSelector = @"invalidate";

static BOOL GLFrameworkLoaded(void) {
    static BOOL loaded = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loaded = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_LAZY) != NULL;
    });
    return loaded;
}

BOOL GLMenuBarHidingAvailable(void) {
    if (!GLFrameworkLoaded()) return NO;
    Class configuration = NSClassFromString(GLConfigurationClass);
    Class assertion = NSClassFromString(GLAssertionClass);
    return configuration != Nil && assertion != Nil
        && [configuration instancesRespondToSelector:NSSelectorFromString(GLInitSelector)]
        && [assertion instancesRespondToSelector:NSSelectorFromString(GLActivateSelector)]
        && [assertion instancesRespondToSelector:NSSelectorFromString(GLInvalidateSelector)];
}

void GLMenuBarHidingInvalidate(id assertion) {
    if (assertion == nil) return;
    SEL selector = NSSelectorFromString(GLInvalidateSelector);
    if (![assertion respondsToSelector:selector]) return;
    @try {
        ((void (*)(id, SEL))objc_msgSend)(assertion, selector);
    } @catch (NSException *exception) {
        NSLog(@"Glance: menu bar assertion could not be ended: %@", exception.reason);
    }
}

id GLMenuBarHidingActivate(NSArray<NSNumber *> *systemItems, NSArray<NSString *> *bundleIdentifiers,
                           void (^completion)(NSError *error)) {
    if (!GLMenuBarHidingAvailable()) return nil;
    id assertion = nil;
    @try {
        id configuration = [NSClassFromString(GLConfigurationClass) alloc];
        configuration = ((id (*)(id, SEL, NSArray *, NSArray *))objc_msgSend)(
            configuration, NSSelectorFromString(GLInitSelector), systemItems, bundleIdentifiers);
        assertion = [[NSClassFromString(GLAssertionClass) alloc] init];
        if (configuration == nil || assertion == nil) return nil;
        void (^handler)(NSError *) = ^(NSError *error) { completion(error); };
        ((void (*)(id, SEL, id, id))objc_msgSend)(assertion, NSSelectorFromString(GLActivateSelector), configuration, handler);
        return assertion;
    } @catch (NSException *exception) {
        NSLog(@"Glance: menu bar assertion could not be made: %@", exception.reason);
        GLMenuBarHidingInvalidate(assertion);
        return nil;
    }
}
