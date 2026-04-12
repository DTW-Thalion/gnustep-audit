/*
 * test_category_order.m - RB-10: Category method loading order
 *
 * Defines a class and a category that adds a method.  Verifies the
 * category method is callable after loading.
 *
 * Bug: Category methods may not be properly linked into the class
 * method list if the category is loaded before/after the class in
 * certain link orders.
 *
 * Expected AFTER fix: Category method is found and callable.
 * Expected BEFORE fix: Unrecognized selector or crash.
 */

#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>
#include "../../common/test_utils.h"

/* ---- Base class ---- */
@interface CatTestClass {
    Class isa;
}
+ (id)alloc;
- (id)init;
- (const char *)baseMethod;
@end

@implementation CatTestClass
+ (id)alloc {
    return class_createInstance(self, 0);
}
- (id)init {
    return self;
}
- (const char *)baseMethod {
    return "base";
}
@end

/* ---- Category ---- */
@interface CatTestClass (TestCategory)
- (const char *)categoryMethod;
- (int)categoryValue;
@end

@implementation CatTestClass (TestCategory)
- (const char *)categoryMethod {
    return "category";
}
- (int)categoryValue {
    return 42;
}
@end

int main(void) {
    printf("=== RB-10: Category Method Loading Order Test ===\n\n");

    id obj = [[CatTestClass alloc] init];
    TEST_ASSERT_NOT_NULL(obj, "object created");

    /* Test 1: Base method works */
    const char *base = [obj baseMethod];
    TEST_ASSERT(base != NULL && strcmp(base, "base") == 0,
                "base method returns correct value");

    /* Test 2: Category method is callable */
    const char *cat = [obj categoryMethod];
    TEST_ASSERT(cat != NULL && strcmp(cat, "category") == 0,
                "category method returns correct value");

    /* Test 3: Second category method */
    int val = [obj categoryValue];
    TEST_ASSERT_EQUAL(val, 42,
                      "category method returning int works correctly");

    /* Test 4: Runtime introspection finds category methods */
    Class cls = objc_getClass("CatTestClass");
    BOOL hasCatMethod = class_respondsToSelector(cls,
                            sel_registerName("categoryMethod"));
    TEST_ASSERT(hasCatMethod,
                "class_respondsToSelector finds category method");

    BOOL hasCatValue = class_respondsToSelector(cls,
                            sel_registerName("categoryValue"));
    TEST_ASSERT(hasCatValue,
                "class_respondsToSelector finds second category method");

    /* Test 5: Method list contains both base and category methods */
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    int foundBase = 0, foundCat = 0;
    for (unsigned int i = 0; i < count; i++) {
        const char *name = sel_getName(method_getName(methods[i]));
        if (strcmp(name, "baseMethod") == 0) foundBase++;
        if (strcmp(name, "categoryMethod") == 0) foundCat++;
    }
    free(methods);

    TEST_ASSERT(foundBase > 0, "baseMethod found in method list");
    TEST_ASSERT(foundCat > 0, "categoryMethod found in method list");

    return TEST_SUMMARY();
}
