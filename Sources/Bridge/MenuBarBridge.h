// Menu bar hiding on macOS 27 and later.
//
// macOS 27 draws the whole menu bar as one window, so status items can no longer be pushed aside with
// an oversized divider. Instead, the private MenuBarClientCore framework's "assessment mode" limits the
// menu bar to an allow-list of apps and system items. These functions reach it at run time (nothing is
// linked at build time), check every class and selector first, and catch exceptions, so a missing or
// changed framework only means hiding is unavailable.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The framework, both classes and the three methods are all present.
BOOL GLMenuBarHidingAvailable(void);

/// Limits the menu bar to the given apps and system items until the returned assertion is invalidated or
/// this process exits. The completion runs on an arbitrary queue with nil on success. Returns nil when
/// the request could not even be made.
id _Nullable GLMenuBarHidingActivate(NSArray<NSNumber *> *systemItems, NSArray<NSString *> *bundleIdentifiers,
                                     void (^completion)(NSError *_Nullable error));

/// Ends an assertion. Safe to call with nil or twice.
void GLMenuBarHidingInvalidate(id _Nullable assertion);

NS_ASSUME_NONNULL_END
