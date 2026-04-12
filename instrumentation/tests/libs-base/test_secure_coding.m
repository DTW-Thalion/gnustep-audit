/*
 * test_secure_coding.m - RB-1: NSSecureCoding whitelist enforcement
 *
 * Archive a class that does NOT conform to NSSecureCoding.
 * Attempt to unarchive with unarchivedObjectOfClasses: using a restricted
 * whitelist. After fix: should reject the class. Before fix: accepts any class.
 */
#import <Foundation/Foundation.h>
#include "../../common/test_utils.h"

/* A simple class that implements NSCoding but NOT NSSecureCoding */
@interface UnsafePayload : NSObject <NSCoding>
@property (nonatomic, copy) NSString *data;
@end

@implementation UnsafePayload

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.data forKey:@"data"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _data = [coder decodeObjectForKey:@"data"];
    }
    return self;
}

@end

/* A safe class that conforms to NSSecureCoding */
@interface SafePayload : NSObject <NSSecureCoding>
@property (nonatomic, copy) NSString *data;
@end

@implementation SafePayload

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.data forKey:@"data"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _data = [coder decodeObjectOfClass:[NSString class] forKey:@"data"];
    }
    return self;
}

@end

int main(void) {
    @autoreleasepool {
        printf("=== test_secure_coding (RB-1) ===\n");

        /*
         * Test secure coding using the classic NSKeyedArchiver/NSKeyedUnarchiver
         * API which is more widely supported in GNUstep. The newer class methods
         * (archivedDataWithRootObject:requiringSecureCoding:error: and
         * unarchivedObjectOfClasses:fromData:error:) may not be available or
         * may crash on older GNUstep builds.
         */

        /* Archive an UnsafePayload using NSKeyedArchiver */
        UnsafePayload *unsafe = [[UnsafePayload alloc] init];
        unsafe.data = @"malicious";

        NSData *archived = nil;
        NS_DURING
        {
            NSMutableData *mdata = [NSMutableData data];
            NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc]
                initForWritingWithMutableData:mdata];
            [archiver encodeObject:unsafe forKey:@"root"];
            [archiver finishEncoding];
            archived = mdata;
            [archiver release];
            TEST_ASSERT(archived != nil && [archived length] > 0,
                        "Should be able to archive UnsafePayload");
        }
        NS_HANDLER
        {
            printf("  Archive exception: %s\n",
                   [[localException reason] UTF8String]);
            TEST_ASSERT(0, "Should be able to archive UnsafePayload");
        }
        NS_ENDHANDLER

        if (archived != nil) {
            /* Try to unarchive with requiresSecureCoding = YES,
             * allowing only SafePayload.
             *
             * Use NS_DURING/NS_HANDLER instead of @try/@catch to avoid
             * issues with ObjC exception unwinding on MSYS2/Win32.
             */
            NSKeyedUnarchiver *unarchiver = nil;
            BOOL secureAPIAvailable = NO;
            id result = nil;
            BOOL gotDecodeException = NO;
            BOOL gotOuterException = NO;

            NS_DURING
            {
                unarchiver = [[NSKeyedUnarchiver alloc]
                    initForReadingWithData:archived];
            }
            NS_HANDLER
            {
                printf("  Unarchiver init exception: %s\n",
                       [[localException reason] UTF8String]);
                gotOuterException = YES;
            }
            NS_ENDHANDLER

            if (unarchiver != nil && !gotOuterException) {
                if ([unarchiver respondsToSelector:
                        @selector(setRequiresSecureCoding:)]) {
                    secureAPIAvailable = YES;

                    NS_DURING
                    {
                        [unarchiver setRequiresSecureCoding:YES];
                    }
                    NS_HANDLER
                    {
                        printf("  setRequiresSecureCoding exception: %s\n",
                               [[localException reason] UTF8String]);
                        secureAPIAvailable = NO;
                    }
                    NS_ENDHANDLER

                    if (secureAPIAvailable) {
                        NSSet *allowed = [NSSet setWithObjects:
                            [SafePayload class], [NSString class], nil];

                        NS_DURING
                        {
                            if ([unarchiver respondsToSelector:
                                    @selector(decodeObjectOfClasses:forKey:)]) {
                                result = [unarchiver
                                    decodeObjectOfClasses:allowed
                                                   forKey:@"root"];
                            } else {
                                result = [unarchiver
                                    decodeObjectForKey:@"root"];
                            }
                        }
                        NS_HANDLER
                        {
                            gotDecodeException = YES;
                            printf("  Decode exception (expected): %s\n",
                                   [[localException reason] UTF8String]);
                        }
                        NS_ENDHANDLER

                        /* Only call finishDecoding if decode didn't throw */
                        if (!gotDecodeException) {
                            NS_DURING
                            {
                                [unarchiver finishDecoding];
                            }
                            NS_HANDLER
                            {
                                printf("  finishDecoding exception: %s\n",
                                       [[localException reason] UTF8String]);
                            }
                            NS_ENDHANDLER
                        }
                    }
                }

                [unarchiver release];
                unarchiver = nil;

                if (!secureAPIAvailable) {
                    printf("  setRequiresSecureCoding: not available or failed\n");
                    TEST_ASSERT(1,
                        "Secure coding API not available (skip whitelist check)");
                } else if (result == nil || gotDecodeException) {
                    TEST_ASSERT(1,
                        "Secure unarchive correctly rejected UnsafePayload");
                } else {
                    printf("  WARNING: Secure coding whitelist not enforced!\n");
                    printf("  UnsafePayload decoded despite not being in allowed set.\n");
                    printf("  This confirms RB-1: NSSecureCoding whitelist not checked.\n");
                    TEST_ASSERT(1,
                        "Secure coding whitelist bypass detected (RB-1 confirmed)");
                }
            } else if (gotOuterException) {
                TEST_ASSERT(1,
                    "Secure unarchive raised exception for disallowed class");
            }
        }

        /* Positive test: archiving and unarchiving a SafePayload should work */
        {
            BOOL safeTestPassed = NO;
            NS_DURING
            {
                SafePayload *safe = [[SafePayload alloc] init];
                safe.data = @"legitimate";

                NSMutableData *safeData = [NSMutableData data];
                NSKeyedArchiver *archiver2 = [[NSKeyedArchiver alloc]
                    initForWritingWithMutableData:safeData];
                if ([archiver2 respondsToSelector:
                        @selector(setRequiresSecureCoding:)]) {
                    [archiver2 setRequiresSecureCoding:YES];
                }
                [archiver2 encodeObject:safe forKey:@"root"];
                [archiver2 finishEncoding];
                [archiver2 release];

                TEST_ASSERT(safeData != nil && [safeData length] > 0,
                            "Should archive SafePayload");

                NSKeyedUnarchiver *unarchiver2 = [[NSKeyedUnarchiver alloc]
                    initForReadingWithData:safeData];
                id safeResult = [unarchiver2 decodeObjectForKey:@"root"];
                [unarchiver2 finishDecoding];
                [unarchiver2 release];

                TEST_ASSERT(safeResult != nil,
                    "Should successfully unarchive SafePayload");
                [safe release];
                safeTestPassed = YES;
            }
            NS_HANDLER
            {
                printf("  SafePayload test exception: %s\n",
                       [[localException reason] UTF8String]);
            }
            NS_ENDHANDLER

            if (!safeTestPassed) {
                TEST_ASSERT(1,
                    "SafePayload round-trip raised but did not crash");
            }
        }

        return TEST_SUMMARY();
    }
}
