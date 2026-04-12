/*
 * test_archive_bounds.m - RB-5: Out-of-bounds CF$UID in keyed archive
 *
 * Create a malformed NSKeyedArchiver plist with an out-of-bounds CF$UID
 * index referencing a non-existent object. Unarchive it.
 * After fix: returns error. Before fix: crash (OOB array access).
 */
#import <Foundation/Foundation.h>
#include "../../common/test_utils.h"

int main(void) {
    @autoreleasepool {
        printf("=== test_archive_bounds (RB-5) ===\n");

        /*
         * Craft a keyed archive plist with a CF$UID that points beyond
         * the $objects array. NSKeyedUnarchiver stores decoded objects
         * in an array indexed by CF$UID values. If a UID is larger than
         * the array, it causes an out-of-bounds access.
         *
         * A real keyed archive plist looks like:
         * {
         *   $archiver = NSKeyedArchiver;
         *   $version = 100000;
         *   $top = { root = {CF$UID = 1}; };
         *   $objects = ( "$null", <real objects...> );
         * }
         *
         * We'll set CF$UID = 9999 when $objects only has 2 entries.
         */

        NSString *plistXML =
            @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            @"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
            @"\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
            @"<plist version=\"1.0\">\n"
            @"<dict>\n"
            @"  <key>$archiver</key>\n"
            @"  <string>NSKeyedArchiver</string>\n"
            @"  <key>$version</key>\n"
            @"  <integer>100000</integer>\n"
            @"  <key>$top</key>\n"
            @"  <dict>\n"
            @"    <key>root</key>\n"
            @"    <dict>\n"
            @"      <key>CF$UID</key>\n"
            @"      <integer>9999</integer>\n"
            @"    </dict>\n"
            @"  </dict>\n"
            @"  <key>$objects</key>\n"
            @"  <array>\n"
            @"    <string>$null</string>\n"
            @"    <string>hello</string>\n"
            @"  </array>\n"
            @"</dict>\n"
            @"</plist>\n";

        NSData *plistData = [plistXML dataUsingEncoding:NSUTF8StringEncoding];
        TEST_ASSERT_NOT_NULL(plistData, "Plist data created");

        /* Deserialize the plist to get the dictionary */
        NSError *plistError = nil;
        NSDictionary *archiveDict = [NSPropertyListSerialization
            propertyListWithData:plistData
                         options:NSPropertyListImmutable
                          format:NULL
                           error:&plistError];

        TEST_ASSERT_NOT_NULL(archiveDict, "Plist XML parsed successfully");

        if (archiveDict == nil) {
            printf("  Could not parse crafted plist XML, skipping unarchive test.\n");
            return TEST_SUMMARY();
        }

        /* Re-serialize as binary plist for NSKeyedUnarchiver */
        NSData *binaryPlist = [NSPropertyListSerialization
            dataWithPropertyList:archiveDict
                          format:NSPropertyListBinaryFormat_v1_0
                         options:0
                           error:NULL];

        if (binaryPlist == nil) {
            /* Fall back to XML format */
            binaryPlist = plistData;
        }

        /* Try to unarchive the malformed archive */
        NSError *unarchiveError = nil;
        id result = nil;

        @try {
            /*
             * GNUstep provides -initForReadingWithData: (no error param).
             * Use @"root" as the key, which is the standard top-level key
             * in NSKeyedArchiver plists (equivalent to NSKeyedArchiveRootObjectKey).
             */
            NSKeyedUnarchiver *unarchiver =
                [[NSKeyedUnarchiver alloc] initForReadingWithData:binaryPlist];
            if (unarchiver) {
                result = [unarchiver decodeObjectForKey:@"root"];
                [unarchiver finishDecoding];
            }
        } @catch (NSException *e) {
            printf("  Exception: %s - %s\n",
                   [[e name] UTF8String], [[e reason] UTF8String]);
            result = nil;
            unarchiveError = [NSError errorWithDomain:@"TestDomain"
                                                 code:-1
                                             userInfo:@{
                NSLocalizedDescriptionKey: [e reason] ?: @"exception"
            }];
        }

        /*
         * After fix: result should be nil, error should be set.
         * The unarchiver should detect the out-of-bounds UID.
         */
        TEST_ASSERT(result == nil || unarchiveError != nil,
                    "Malformed archive with OOB UID should be rejected or error");

        if (result == nil) {
            printf("  Correctly rejected archive with OOB CF$UID.\n");
            TEST_ASSERT(1, "OOB CF$UID detected and rejected");
        } else {
            printf("  WARNING: Archive with OOB CF$UID was accepted!\n");
            printf("  Result: %s\n", [[result description] UTF8String]);
            TEST_ASSERT(0, "Should reject archive with OOB CF$UID index");
        }

        /* Positive test: valid keyed archive should work */
        NSString *testStr = @"valid_test_string";
        NSData *validArchive = [NSKeyedArchiver archivedDataWithRootObject:testStr
                                                    requiringSecureCoding:NO
                                                                    error:NULL];
        if (validArchive) {
            NSError *validErr = nil;
            id validResult = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSString class]
                                                               fromData:validArchive
                                                                  error:&validErr];
            TEST_ASSERT([testStr isEqual:validResult],
                        "Valid keyed archive round-trips correctly");
        }

        return TEST_SUMMARY();
    }
}
