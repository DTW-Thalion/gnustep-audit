/*
 * test_null_selector.m - RB-2: NULL selector handling
 *
 * Validates that passing a NULL selector to objc_msg_lookup() and
 * class_respondsToSelector() does not crash.
 *
 * Bug: The runtime dereferences the selector pointer without checking
 * for NULL, causing a segfault.
 *
 * Expected AFTER fix: No crash; functions return safely.
 * Expected BEFORE fix: Crash (SIGSEGV).
 */

#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include "../../common/test_utils.h"

/* Minimal root class so we don't need Foundation */
@interface NullSelTestRoot {
    Class isa;
}
+ (id)alloc;
- (id)init;
- (void)doSomething;
@end

@implementation NullSelTestRoot
+ (id)alloc {
    return class_createInstance(self, 0);
}
- (id)init {
    return self;
}
- (void)doSomething {
    /* no-op */
}
@end

int main(void) {
    printf("=== RB-2: NULL Selector Handling Test ===\n\n");

    Class cls = objc_getClass("NullSelTestRoot");
    TEST_ASSERT_NOT_NULL(cls, "NullSelTestRoot class loaded");

    id obj = [[NullSelTestRoot alloc] init];
    TEST_ASSERT_NOT_NULL(obj, "object allocated");

    /* Test 1: class_respondsToSelector with NULL selector */
    printf("Testing class_respondsToSelector(cls, NULL)...\n");
    BOOL responds = class_respondsToSelector(cls, (SEL)0);
    TEST_ASSERT(responds == NO,
                "class_respondsToSelector(cls, NULL) returns NO without crash");

    /* Test 2: class_respondsToSelector with valid selector */
    SEL doSel = sel_registerName("doSomething");
    responds = class_respondsToSelector(cls, doSel);
    TEST_ASSERT(responds == YES,
                "class_respondsToSelector(cls, doSomething) returns YES");

    /* Test 3: objc_msg_lookup with NULL selector
     * Note: This is the dangerous path -- before fix this crashes. */
    printf("Testing objc_msg_lookup(obj, NULL)...\n");
    IMP imp = objc_msg_lookup(obj, (SEL)0);
    /* After fix, should return a forwarding IMP or the nil-handler, not crash */
    TEST_ASSERT(1, "objc_msg_lookup(obj, NULL) did not crash");
    (void)imp;

    /* Test 4: sel_getName with NULL */
    printf("Testing sel_getName(NULL)...\n");
    const char *name = sel_getName((SEL)0);
    /* Should either return NULL, empty string, or "<null selector>" -- not crash */
    TEST_ASSERT(1, "sel_getName(NULL) did not crash");
    if (name) {
        printf("  sel_getName(NULL) returned: \"%s\"\n", name);
    } else {
        printf("  sel_getName(NULL) returned: NULL\n");
    }

    return TEST_SUMMARY();
}
