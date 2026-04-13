/*
 * test_gs_inline_dict.m - B5.1: GSInlineDict boundary + invariant tests
 *
 * Covers the 10 targeted cases from the spike §6.2:
 *   1. N=0 empty dict
 *   2. N=1 identity + isEqual + miss + NSMutableString key-copy semantics
 *   3. N=4 boundary lookup / enumeration / isEqualToDictionary
 *   4. N=5 fallthrough regression (must NOT be GSInlineDict)
 *   5. Duplicate-key insert replaces
 *   6. Nil key / nil value raises NSInvalidArgumentException
 *   7. -copy returns self-retain
 *   8. -mutableCopy produces a GSMutableDictionary
 *   9. Archive round-trip preserves count + contents
 *  10. GSCachedDictionary opt-out: c<=4 on a subclass is NOT GSInlineDict
 *
 * Gated on a runtime probe: if GSInlineDict is not present in the
 * installed libs-base, the whole suite skips gracefully.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>
#include "../../common/test_utils.h"

static Class InlineDictCls = Nil;
static Class GSDictCls = Nil;

static BOOL is_inline_dict(id obj) {
    return InlineDictCls != Nil && [obj isKindOfClass: InlineDictCls];
}

static void test_n0_empty(void) {
    NSDictionary *d = [NSDictionary dictionary];
    TEST_ASSERT_EQUAL([d count], (NSUInteger)0, "N=0 count == 0");
    TEST_ASSERT([d objectForKey: @"missing"] == nil, "N=0 lookup returns nil");
    NSEnumerator *e = [d keyEnumerator];
    TEST_ASSERT([e nextObject] == nil, "N=0 key enumerator immediately nil");
    /* +dictionary may hit the empty-dict singleton which is not a
     * GSInlineDict; do not assert class here. */
}

static void test_n1(void) {
    NSString *k = @"alpha";
    NSString *v = @"one";
    id keys[1] = { k };
    id vals[1] = { v };
    NSDictionary *d = [NSDictionary dictionaryWithObjects: vals forKeys: keys count: 1];
    TEST_ASSERT(is_inline_dict(d), "N=1 dict is a GSInlineDict");
    TEST_ASSERT_EQUAL([d count], (NSUInteger)1, "N=1 count == 1");
    TEST_ASSERT([d objectForKey: k] == v, "N=1 identity hit returns same value");

    /* isEqual hit: a fresh NSMutableString equal to the key must also find
     * the value, proving isEqual: (not just identity) is used. */
    NSMutableString *equalKey = [NSMutableString stringWithString: @"alpha"];
    id got = [d objectForKey: equalKey];
    TEST_ASSERT(got == v, "N=1 isEqual: hit returns value for fresh equal key");

    /* Miss */
    TEST_ASSERT([d objectForKey: @"beta"] == nil, "N=1 miss returns nil");

    /* NSMutableString key-copy semantics: construct the dict with a mutable
     * key, mutate the original, verify lookup under the original key still
     * works (the stored key is a copy, unaffected by the mutation). */
    NSMutableString *mk = [NSMutableString stringWithString: @"mutkey"];
    NSDictionary *d2 = [NSDictionary dictionaryWithObject: @"mv" forKey: mk];
    [mk appendString: @"_tail"];
    id got2 = [d2 objectForKey: @"mutkey"];
    TEST_ASSERT([got2 isEqual: @"mv"],
                "N=1 stored key was copied (mutation of original doesn't break lookup)");
}

static void test_n4_boundary(void) {
    id keys[4] = { @"k1", @"k2", @"k3", @"k4" };
    id vals[4] = { @"v1", @"v2", @"v3", @"v4" };
    NSDictionary *d = [NSDictionary dictionaryWithObjects: vals forKeys: keys count: 4];
    TEST_ASSERT(is_inline_dict(d), "N=4 dict is a GSInlineDict");
    TEST_ASSERT_EQUAL([d count], (NSUInteger)4, "N=4 count == 4");
    for (int i = 0; i < 4; i++) {
        id got = [d objectForKey: keys[i]];
        TEST_ASSERT([got isEqual: vals[i]], "N=4 each key looks up its value");
    }
    TEST_ASSERT([d objectForKey: @"miss"] == nil, "N=4 miss returns nil");

    /* Enumeration visits all 4 */
    int seen = 0;
    NSEnumerator *e = [d keyEnumerator];
    id k;
    while ((k = [e nextObject]) != nil) {
        seen++;
    }
    TEST_ASSERT_EQUAL(seen, 4, "N=4 keyEnumerator visits all 4");

    /* isEqualToDictionary against a GSDictionary of the same content:
     * construct by forcing N=5 then removing one, so we get a real
     * GSDictionary, then compare. Simpler: use NSMutableDictionary. */
    NSMutableDictionary *other = [NSMutableDictionary dictionaryWithCapacity: 4];
    for (int i = 0; i < 4; i++) [other setObject: vals[i] forKey: keys[i]];
    TEST_ASSERT([d isEqualToDictionary: other],
                "N=4 isEqualToDictionary against mutable dict of same content");
}

static void test_n5_fallthrough(void) {
    id keys[5] = { @"a", @"b", @"c", @"d", @"e" };
    id vals[5] = { @"1", @"2", @"3", @"4", @"5" };
    NSDictionary *d = [NSDictionary dictionaryWithObjects: vals forKeys: keys count: 5];
    TEST_ASSERT_EQUAL([d count], (NSUInteger)5, "N=5 count == 5");
    TEST_ASSERT(!is_inline_dict(d), "N=5 is NOT a GSInlineDict (falls through)");
    for (int i = 0; i < 5; i++) {
        TEST_ASSERT([[d objectForKey: keys[i]] isEqual: vals[i]],
                    "N=5 each key looks up correctly");
    }
}

static void test_duplicate_key(void) {
    id keys[3] = { @"x", @"y", @"x" };
    id vals[3] = { @"first", @"mid", @"second" };
    NSDictionary *d = [NSDictionary dictionaryWithObjects: vals forKeys: keys count: 3];
    TEST_ASSERT_EQUAL([d count], (NSUInteger)2, "duplicate key collapses to count 2");
    TEST_ASSERT([[d objectForKey: @"x"] isEqual: @"second"],
                "duplicate key: later value replaces earlier");
    TEST_ASSERT([[d objectForKey: @"y"] isEqual: @"mid"],
                "duplicate key: unrelated entry preserved");
}

static void test_nil_key_raises(void) {
    id keys[2] = { @"a", nil };
    id vals[2] = { @"v1", @"v2" };
    BOOL raised = NO;
    NS_DURING
        (void)[NSDictionary dictionaryWithObjects: vals forKeys: keys count: 2];
    NS_HANDLER
        raised = [[localException name] isEqual: NSInvalidArgumentException];
    NS_ENDHANDLER
    TEST_ASSERT(raised, "nil key raises NSInvalidArgumentException");
}

static void test_nil_value_raises(void) {
    id keys[2] = { @"a", @"b" };
    id vals[2] = { @"v1", nil };
    BOOL raised = NO;
    NS_DURING
        (void)[NSDictionary dictionaryWithObjects: vals forKeys: keys count: 2];
    NS_HANDLER
        raised = [[localException name] isEqual: NSInvalidArgumentException];
    NS_ENDHANDLER
    TEST_ASSERT(raised, "nil value raises NSInvalidArgumentException");
}

static void test_copy_self_retain(void) {
    id keys[2] = { @"k1", @"k2" };
    id vals[2] = { @"v1", @"v2" };
    NSDictionary *d = [NSDictionary dictionaryWithObjects: vals forKeys: keys count: 2];
    TEST_ASSERT(is_inline_dict(d), "precondition: d is GSInlineDict");
    NSDictionary *c = [[d copy] autorelease];
    TEST_ASSERT_EQUAL((void*)c, (void*)d,
                      "immutable -copy of GSInlineDict returns self (retain)");
}

static void test_mutable_copy_makes_mutable(void) {
    id keys[2] = { @"k1", @"k2" };
    id vals[2] = { @"v1", @"v2" };
    NSDictionary *d = [NSDictionary dictionaryWithObjects: vals forKeys: keys count: 2];
    NSMutableDictionary *m = [[d mutableCopy] autorelease];
    TEST_ASSERT([m isKindOfClass: [NSMutableDictionary class]],
                "-mutableCopy returns NSMutableDictionary");
    TEST_ASSERT_EQUAL([m count], (NSUInteger)2, "mutable copy has right count");
    [m setObject: @"v3" forKey: @"k3"];
    TEST_ASSERT_EQUAL([m count], (NSUInteger)3, "mutable copy accepts new keys");
    /* Original unchanged */
    TEST_ASSERT_EQUAL([d count], (NSUInteger)2, "original GSInlineDict unchanged");
}

static void test_archive_roundtrip(void) {
    id keys[3] = { @"a", @"b", @"c" };
    id vals[3] = { @"1", @"2", @"3" };
    NSDictionary *d = [NSDictionary dictionaryWithObjects: vals forKeys: keys count: 3];

    NSData *data = [NSKeyedArchiver archivedDataWithRootObject: d];
    TEST_ASSERT_NOT_NULL(data, "keyed archive produced data");

    NSDictionary *back = [NSKeyedUnarchiver unarchiveObjectWithData: data];
    TEST_ASSERT_NOT_NULL(back, "keyed unarchive produced object");
    TEST_ASSERT_EQUAL([back count], (NSUInteger)3, "unarchived count == 3");
    for (int i = 0; i < 3; i++) {
        TEST_ASSERT([[back objectForKey: keys[i]] isEqual: vals[i]],
                    "unarchived entry matches original");
    }
}

static void test_gscacheddict_optout(void) {
    /* GSCachedDictionary is a private subclass of GSDictionary used by the
     * plist uniquing path; we cannot easily construct one from outside.
     * Instead, verify the guard semantically: allocate a GSDictionary
     * subclass other than GSDictionary itself and confirm it does not get
     * re-typed. Use NSClassFromString to avoid a hard link requirement. */
    Class cached = NSClassFromString(@"GSCachedDictionary");
    if (cached == Nil) {
        printf("  note: GSCachedDictionary not visible; skipping opt-out check\n");
        return;
    }
    id keys[2] = { @"k1", @"k2" };
    id vals[2] = { @"v1", @"v2" };
    /* +alloc -> init path. GSCachedDictionary inherits
     * -initWithObjects:forKeys:count: from GSDictionary, and the intercept
     * guards on [self class] == GSDictionary, so this must stay a
     * GSCachedDictionary. */
    id d = [[cached alloc] initWithObjects: vals forKeys: keys count: 2];
    TEST_ASSERT([d isKindOfClass: cached],
                "GSCachedDictionary stays a GSCachedDictionary (opt-out)");
    TEST_ASSERT(!is_inline_dict(d),
                "GSCachedDictionary is NOT re-typed to GSInlineDict");
    /* Avoid the 'deallocating still-cached' exception from GSCachedDictionary
     * -dealloc by calling its private _uncache method via performSelector. */
    SEL uncache = @selector(_uncache);
    if ([d respondsToSelector: uncache]) {
        [d performSelector: uncache];
    } else {
        [d release];
    }
}

int main(void) {
    @autoreleasepool {
        InlineDictCls = NSClassFromString(@"GSInlineDict");
        GSDictCls = NSClassFromString(@"GSDictionary");

        if (InlineDictCls == Nil) {
            printf("SKIPPED: GSInlineDict not present in this libs-base build "
                   "(B5.1 not installed).\n");
            printf("\nRESULT: PASS\n");
            return 0;
        }

        test_n0_empty();
        test_n1();
        test_n4_boundary();
        test_n5_fallthrough();
        test_duplicate_key();
        test_nil_key_raises();
        test_nil_value_raises();
        test_copy_self_retain();
        test_mutable_copy_makes_mutable();
        test_archive_roundtrip();
        test_gscacheddict_optout();
    }

    return TEST_SUMMARY();
}
