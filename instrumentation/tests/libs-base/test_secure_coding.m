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

        /* Archive an UnsafePayload using NSKeyedArchiver */
        UnsafePayload *unsafe = [[UnsafePayload alloc] init];
        unsafe.data = @"malicious";

        NSError *archiveError = nil;
        NSData *archived = nil;

        /* Use requiringSecureCoding:NO to actually produce the archive */
        archived = [NSKeyedArchiver archivedDataWithRootObject:unsafe
                                         requiringSecureCoding:NO
                                                         error:&archiveError];

        TEST_ASSERT(archived != nil, "Should be able to archive UnsafePayload");
        TEST_ASSERT(archiveError == nil, "No error archiving UnsafePayload");

        /* Now try to unarchive with secure coding, allowing only SafePayload */
        NSError *unarchiveError = nil;
        NSSet *allowedClasses = [NSSet setWithObjects:[SafePayload class],
                                                      [NSString class], nil];

        id result = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowedClasses
                                                        fromData:archived
                                                           error:&unarchiveError];

        /*
         * After fix: result should be nil and unarchiveError should be set,
         * because UnsafePayload is not in the allowed whitelist.
         * Before fix: might succeed (accepts any class regardless of whitelist).
         */
        TEST_ASSERT(result == nil,
                    "Secure unarchive should reject UnsafePayload not in whitelist");
        TEST_ASSERT(unarchiveError != nil,
                    "Should get error when unarchiving disallowed class");

        if (result != nil) {
            printf("  WARNING: Secure coding whitelist not enforced!\n");
            printf("  UnsafePayload was decoded despite not being in allowed set.\n");
        }

        /* Positive test: archiving and unarchiving a SafePayload should work */
        SafePayload *safe = [[SafePayload alloc] init];
        safe.data = @"legitimate";

        NSData *safeArchived = [NSKeyedArchiver archivedDataWithRootObject:safe
                                                     requiringSecureCoding:YES
                                                                     error:&archiveError];
        TEST_ASSERT(safeArchived != nil, "Should archive SafePayload with secure coding");

        NSError *safeError = nil;
        id safeResult = [NSKeyedUnarchiver unarchivedObjectOfClasses:
                            [NSSet setWithObjects:[SafePayload class],
                                                  [NSString class], nil]
                                                            fromData:safeArchived
                                                               error:&safeError];
        TEST_ASSERT(safeResult != nil,
                    "Should successfully unarchive SafePayload with correct whitelist");
        TEST_ASSERT(safeError == nil, "No error unarchiving SafePayload");

        return TEST_SUMMARY();
    }
}
