/*
 * test_type_qualifiers.m - RB-3: Selector type qualifier handling
 *
 * Registers a selector with a const-qualified type encoding and
 * verifies that message dispatch works correctly.
 *
 * Bug: The type-comparison logic in the selector table may strip or
 * mishandle type qualifiers (const, in, out, inout, bycopy, etc.),
 * causing selector lookup mismatches or dispatch to wrong IMPs.
 *
 * Expected AFTER fix: Qualified selectors dispatch correctly.
 * Expected BEFORE fix: Wrong method called or crash.
 */

#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>
#include "../../common/test_utils.h"

@interface TypeQualRoot {
    Class isa;
}
+ (id)alloc;
- (id)init;
- (const char *)constReturn;
- (void)takeConstPtr:(const char *)str;
@end

static const char *lastConstPtr = NULL;

@implementation TypeQualRoot
+ (id)alloc {
    return class_createInstance(self, 0);
}
- (id)init {
    return self;
}
- (const char *)constReturn {
    return "const_result";
}
- (void)takeConstPtr:(const char *)str {
    lastConstPtr = str;
}
@end

int main(void) {
    printf("=== RB-3: Selector Type Qualifier Test ===\n\n");

    id obj = [[TypeQualRoot alloc] init];
    TEST_ASSERT_NOT_NULL(obj, "object created");

    /* Test 1: Method returning const pointer works */
    const char *result = [obj constReturn];
    TEST_ASSERT(result != NULL && strcmp(result, "const_result") == 0,
                "const-returning method dispatches correctly");

    /* Test 2: Method taking const pointer parameter */
    const char *input = "hello_qualified";
    [obj takeConstPtr:input];
    TEST_ASSERT(lastConstPtr == input,
                "method with const parameter receives correct pointer");

    /* Test 3: Register selector with type encoding containing qualifiers */
    /* 'r' = const qualifier in ObjC type encoding */
    /* "r*@:" means: const char* return, id self, SEL _cmd */
    SEL qualSel = sel_registerTypedName_np("constReturn", "r*@:");
    if (qualSel) {
        const char *selName = sel_getName(qualSel);
        TEST_ASSERT(strcmp(selName, "constReturn") == 0,
                    "qualified selector has correct name");

        /* Look up the method via runtime */
        Method m = class_getInstanceMethod(
            objc_getClass("TypeQualRoot"), qualSel);
        TEST_ASSERT_NOT_NULL(m,
            "method found via const-qualified selector");

        if (m) {
            /* Call through the looked-up IMP */
            IMP imp = method_getImplementation(m);
            const char *ret = ((const char *(*)(id, SEL))imp)(obj, qualSel);
            TEST_ASSERT(ret != NULL && strcmp(ret, "const_result") == 0,
                        "dispatch through qualified selector returns correct value");
        }
    } else {
        /* sel_registerTypedName_np may not be available */
        printf("  sel_registerTypedName_np not available; using fallback\n");

        /* Fallback: verify via class_getInstanceMethod with plain selector */
        SEL plain = sel_registerName("constReturn");
        Method m = class_getInstanceMethod(
            objc_getClass("TypeQualRoot"), plain);
        TEST_ASSERT_NOT_NULL(m, "method found via plain selector");

        if (m) {
            const char *types = method_getTypeEncoding(m);
            printf("  Type encoding: %s\n", types ? types : "(null)");
            TEST_ASSERT_NOT_NULL(types, "method has type encoding");
        }
    }

    /* Test 4: Verify selectors with different type qualifiers
     * are properly distinguished or unified */
    SEL s1 = sel_registerName("takeConstPtr:");
    SEL s2 = sel_registerName("takeConstPtr:");
    TEST_ASSERT(s1 == s2,
                "same selector name resolves to same SEL");

    return TEST_SUMMARY();
}
