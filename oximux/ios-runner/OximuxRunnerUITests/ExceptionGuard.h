#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, or nil.
/// XCTest raises some (an element that vanished mid-query, say); uncaught,
/// one would end the runner.
NSException *_Nullable OXRunCatchingException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
