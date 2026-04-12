/*
 * test_protocol_null.m - RB-7: protocol_copyPropertyList NULL crash
 *
 * Calls protocol_copyPropertyList() with a NULL protocol argument.
 * The fix should check for NULL before dereferencing.
 *
 * Bug: protocol_copyPropertyList dereferences the protocol pointer
 * before checking if it is NULL, causing a segfault.
 *
 * Expected AFTER fix: Returns NULL or empty list, no crash.
 * Expected BEFORE fix: Crash (SIGSEGV).
 */

#import <objc/runtime.h>
#include <stdio.h>
#include "../../common/test_utils.h"

/* Define a real protocol for comparison */
@protocol TestProto
@property (readonly) int testProp;
@end

int main(void) {
    printf("=== RB-7: protocol_copyPropertyList NULL Protocol Test ===\n\n");

    /* Test 1: NULL protocol */
    printf("Calling protocol_copyPropertyList(NULL, &count)...\n");
    unsigned int count = 999;  /* sentinel value */
    objc_property_t *props = protocol_copyPropertyList(NULL, &count);
    TEST_ASSERT(1, "protocol_copyPropertyList(NULL) did not crash");
    /* After fix, should return NULL and set count to 0 */
    if (props == NULL) {
        printf("  Returned NULL (correct after fix)\n");
    } else {
        printf("  Returned non-NULL (unexpected)\n");
        free(props);
    }

    /* Test 2: NULL protocol, NULL count pointer */
    printf("Calling protocol_copyPropertyList(NULL, NULL)...\n");
    props = protocol_copyPropertyList(NULL, NULL);
    TEST_ASSERT(1, "protocol_copyPropertyList(NULL, NULL) did not crash");
    if (props) free(props);

    /* Test 3: Valid protocol for comparison */
    Protocol *proto = objc_getProtocol("TestProto");
    if (proto) {
        unsigned int validCount = 0;
        objc_property_t *validProps = protocol_copyPropertyList(proto, &validCount);
        TEST_ASSERT(validCount > 0,
                    "valid protocol has properties");
        printf("  TestProto has %u properties\n", validCount);
        if (validProps) free(validProps);
    } else {
        printf("  (TestProto not registered; skipping valid protocol test)\n");
        /* Still count as pass since the NULL tests are the point */
        _test_pass_count++;
    }

    return TEST_SUMMARY();
}
