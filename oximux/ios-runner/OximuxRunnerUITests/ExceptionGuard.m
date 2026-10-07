#import "ExceptionGuard.h"

NSException *_Nullable OXRunCatchingException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
