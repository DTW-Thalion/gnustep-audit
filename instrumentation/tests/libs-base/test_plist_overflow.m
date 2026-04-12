/*
 * test_plist_overflow.m - RB-9: Binary plist integer overflow in header
 *
 * Create a malformed binary plist with an object_count that, when multiplied
 * by offset_size, causes an integer overflow. This could lead to a smaller
 * allocation and subsequent out-of-bounds read.
 *
 * After fix: rejected with error.
 * Before fix: OOB read or crash.
 */
#import <Foundation/Foundation.h>
#include "../../common/test_utils.h"
#include <string.h>

/*
 * Binary plist format (Apple):
 *   Header: "bplist00" (8 bytes)
 *   Objects: ...
 *   Offset table: ...
 *   Trailer (32 bytes):
 *     [0]     unused
 *     [1]     sort_version
 *     [2]     offset_size (bytes per offset table entry)
 *     [3]     object_ref_size
 *     [4-7]   padding (unused)
 *     [8-15]  num_objects (uint64 big-endian)
 *     [16-23] top_object (uint64 big-endian)
 *     [24-31] offset_table_offset (uint64 big-endian)
 */

static NSData *createMalformedBplist(void) {
    /*
     * Craft a binary plist where:
     *   offset_size = 8
     *   num_objects = 0x2000000000000001 (huge)
     *   offset_size * num_objects overflows 64-bit: 8 * 0x2000000000000001 = 0x8 (wraps)
     *   This means only 8 bytes get allocated for offset table,
     *   but the parser thinks there are billions of objects.
     */
    unsigned char bplist[64];
    memset(bplist, 0, sizeof(bplist));

    /* Header */
    memcpy(bplist, "bplist00", 8);

    /* A minimal object: a single boolean (true) at offset 8 */
    bplist[8] = 0x09; /* true */

    /* Offset table at offset 9: single entry pointing to offset 8 */
    bplist[9] = 0x00;
    bplist[10] = 0x00;
    bplist[11] = 0x00;
    bplist[12] = 0x00;
    bplist[13] = 0x00;
    bplist[14] = 0x00;
    bplist[15] = 0x00;
    bplist[16] = 0x08;

    /*
     * Trailer at the last 32 bytes.
     * For a 64-byte buffer, trailer starts at offset 32.
     */
    unsigned char *trailer = bplist + 32;
    memset(trailer, 0, 32);

    /* offset_size = 8 */
    trailer[6] = 8;
    /* object_ref_size = 1 */
    trailer[7] = 1;

    /*
     * num_objects = 0x2000000000000001
     * 8 * 0x2000000000000001 = 0x10000000000000008, which truncates to 0x8
     */
    trailer[8]  = 0x20;
    trailer[9]  = 0x00;
    trailer[10] = 0x00;
    trailer[11] = 0x00;
    trailer[12] = 0x00;
    trailer[13] = 0x00;
    trailer[14] = 0x00;
    trailer[15] = 0x01;

    /* top_object = 0 */
    memset(trailer + 16, 0, 8);

    /* offset_table_offset = 9 */
    trailer[24] = 0x00;
    trailer[25] = 0x00;
    trailer[26] = 0x00;
    trailer[27] = 0x00;
    trailer[28] = 0x00;
    trailer[29] = 0x00;
    trailer[30] = 0x00;
    trailer[31] = 0x09;

    return [NSData dataWithBytes:bplist length:sizeof(bplist)];
}

int main(void) {
    @autoreleasepool {
        printf("=== test_plist_overflow (RB-9) ===\n");

        NSData *malformed = createMalformedBplist();
        TEST_ASSERT_NOT_NULL(malformed, "Created malformed bplist data");
        printf("  Malformed bplist: %lu bytes\n", (unsigned long)[malformed length]);

        /* Try to parse the malformed plist */
        NSError *error = nil;
        NSPropertyListFormat format;
        id result = nil;

        @try {
            result = [NSPropertyListSerialization
                propertyListWithData:malformed
                             options:NSPropertyListImmutable
                              format:&format
                               error:&error];
        } @catch (NSException *e) {
            printf("  Exception: %s - %s\n",
                   [[e name] UTF8String], [[e reason] UTF8String]);
            result = nil;
            error = (NSError *)(id)e; /* just to mark non-nil */
        }

        /*
         * After fix: result should be nil, error should be set.
         * The parser should detect the integer overflow in
         * offset_size * num_objects and reject the file.
         */
        TEST_ASSERT(result == nil,
                    "Malformed bplist with overflow should be rejected");
        if (error) {
            printf("  Correctly rejected malformed bplist.\n");
            TEST_ASSERT(1, "Parser returned error for overflow bplist");
        } else if (result == nil) {
            printf("  Result is nil but no error returned.\n");
            TEST_ASSERT(0, "Should return an error when rejecting");
        }

        /* Test a second variant: offset_size = 255, num_objects = huge */
        unsigned char bplist2[64];
        memset(bplist2, 0, sizeof(bplist2));
        memcpy(bplist2, "bplist00", 8);
        bplist2[8] = 0x09;

        unsigned char *trailer2 = bplist2 + 32;
        memset(trailer2, 0, 32);
        trailer2[6] = 255;  /* offset_size = 255 */
        trailer2[7] = 1;
        /* num_objects = 0xFFFFFFFFFFFFFFFF */
        memset(trailer2 + 8, 0xFF, 8);
        trailer2[31] = 0x09;

        NSData *malformed2 = [NSData dataWithBytes:bplist2 length:sizeof(bplist2)];
        NSError *error2 = nil;
        id result2 = nil;

        @try {
            result2 = [NSPropertyListSerialization
                propertyListWithData:malformed2
                             options:NSPropertyListImmutable
                              format:&format
                               error:&error2];
        } @catch (NSException *e) {
            result2 = nil;
        }

        TEST_ASSERT(result2 == nil,
                    "Bplist with max num_objects should be rejected");

        /* Positive test: valid binary plist should work */
        NSDictionary *validDict = @{@"key": @"value"};
        NSData *validData = [NSPropertyListSerialization
            dataWithPropertyList:validDict
                          format:NSPropertyListBinaryFormat_v1_0
                         options:0
                           error:NULL];
        if (validData) {
            id parsed = [NSPropertyListSerialization
                propertyListWithData:validData
                             options:NSPropertyListImmutable
                              format:NULL
                               error:NULL];
            TEST_ASSERT(parsed != nil, "Valid binary plist should parse correctly");
        } else {
            TEST_ASSERT(1, "Binary plist serialization not available, skip positive test");
        }

        return TEST_SUMMARY();
    }
}
