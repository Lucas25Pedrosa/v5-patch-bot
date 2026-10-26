#import <Foundation/Foundation.h>

static NSString *const kVersion = @"2.8";

@interface XLGV28Bootstrap : NSObject
@end

@implementation XLGV28Bootstrap

+ (void)load {
    @autoreleasepool {
        NSLog(@"[XLiquidGlass1238ProbeV28] NEW_SESSION version=%@ target=X_12.38 bootstrap=+load", kVersion);
    }
}

@end
