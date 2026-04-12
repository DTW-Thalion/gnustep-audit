/*
 * test_method_sig.m - RB-16/RB-17: Malformed type strings in NSMethodSignature
 *
 * Create NSMethodSignature from malformed Objective-C type strings.
 * After fix: handles gracefully (returns nil or raises controlled exception).
 * Before fix: stack overflow or infinite loop from recursive type parsing.
 */
#import <Foundation/Foundation.h>
#include "../../common/test_utils.h"
#include <signal.h>
#include <setjmp.h>

static sigjmp_buf jumpBuf;
static volatile sig_atomic_t gotSignal = 0;

static void crashHandler(int sig) {
    (void)sig;
    gotSignal = 1;
    siglongjmp(jumpBuf, 1);
}

/*
 * Try to create an NSMethodSignature from a type string.
 * Returns: 0 = nil/error (good), 1 = created OK, -1 = crashed
 */
static int tryTypeString(const char *typeStr, const char *desc) {
    NSMethodSignature *sig = nil;
    int result = 0;

    struct sigaction sa, oldSegv, oldBus;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = crashHandler;
    sigaction(SIGSEGV, &sa, &oldSegv);
    sigaction(SIGBUS, &sa, &oldBus);

    gotSignal = 0;

    if (sigsetjmp(jumpBuf, 1) == 0) {
        @try {
            sig = [NSMethodSignature signatureWithObjCTypes:typeStr];
            if (sig != nil) {
                /*
                 * If it succeeded, try to actually use it to ensure
                 * it's not a deferred crash.
                 */
                (void)[sig numberOfArguments];
                (void)[sig frameLength];
                (void)[sig methodReturnLength];
                result = 1;
            } else {
                result = 0;
            }
        } @catch (NSException *e) {
            printf("  [%s] Exception: %s\n", desc, [[e reason] UTF8String]);
            result = 0;
        }
    } else {
        printf("  [%s] CRASH (signal caught)\n", desc);
        result = -1;
    }

    sigaction(SIGSEGV, &oldSegv, NULL);
    sigaction(SIGBUS, &oldBus, NULL);

    return result;
}

int main(void) {
    @autoreleasepool {
        printf("=== test_method_sig (RB-16/RB-17) ===\n");

        /* Test 1: Valid type string should work */
        int r = tryTypeString("v@:", "valid void method");
        TEST_ASSERT(r == 1, "Valid type 'v@:' should create signature");

        r = tryTypeString("@@:@", "valid method returning id with id arg");
        TEST_ASSERT(r == 1, "Valid type '@@:@' should create signature");

        /* Test 2: Empty type string (RB-16) */
        r = tryTypeString("", "empty string");
        if (r == -1) {
            TEST_ASSERT(0, "Empty type string should not crash");
        } else {
            printf("  Empty type string: %s\n", r == 0 ? "rejected" : "accepted");
            TEST_ASSERT(r == 0, "Empty type string should be rejected");
        }

        /* Test 3: Deeply nested pointer types (RB-17) */
        /*
         * "^^^^^^^^^...^v" - Many levels of pointer-to-pointer.
         * A recursive type parser will overflow the stack.
         */
        {
            char deepPtr[10002];
            memset(deepPtr, '^', 10000);
            deepPtr[10000] = 'v';
            deepPtr[10001] = '\0';

            r = tryTypeString(deepPtr, "10000 nested pointers");
            if (r == -1) {
                printf("  CRASH on deeply nested pointer types!\n");
                TEST_ASSERT(0, "Deep pointer nesting should not crash");
            } else {
                printf("  Deep pointer nesting: %s\n",
                       r == 0 ? "rejected" : "accepted");
                TEST_ASSERT(1, "Deep pointer nesting handled without crash");
            }
        }

        /* Test 4: Recursive struct type (RB-16) */
        /* {name={name={name=...}}} - recursive struct definition */
        {
            NSMutableString *recursiveStruct = [NSMutableString string];
            for (int i = 0; i < 5000; i++) {
                [recursiveStruct appendString:@"{s="];
            }
            [recursiveStruct appendString:@"i"];
            for (int i = 0; i < 5000; i++) {
                [recursiveStruct appendString:@"}"];
            }

            r = tryTypeString([recursiveStruct UTF8String],
                              "5000 nested structs");
            if (r == -1) {
                printf("  CRASH on deeply nested struct types!\n");
                TEST_ASSERT(0, "Deep struct nesting should not crash");
            } else {
                printf("  Deep struct nesting: %s\n",
                       r == 0 ? "rejected" : "accepted");
                TEST_ASSERT(1, "Deep struct nesting handled without crash");
            }
        }

        /* Test 5: Malformed type strings */
        r = tryTypeString("v@:((((((((((", "unclosed parens");
        if (r == -1) {
            TEST_ASSERT(0, "Unclosed parens should not crash");
        } else {
            TEST_ASSERT(1, "Unclosed parens handled without crash");
        }

        r = tryTypeString("v@:{{{{{{{{{", "unclosed braces");
        if (r == -1) {
            TEST_ASSERT(0, "Unclosed braces should not crash");
        } else {
            TEST_ASSERT(1, "Unclosed braces handled without crash");
        }

        /* Test 6: NUL bytes in type string (handled by C string termination) */
        r = tryTypeString("v\0@:", "embedded NUL");
        if (r == -1) {
            TEST_ASSERT(0, "Embedded NUL should not crash");
        } else {
            /* C string will truncate at NUL, so this is just "v" */
            TEST_ASSERT(1, "Embedded NUL handled (truncated to 'v')");
        }

        /* Test 7: Array type with huge count */
        r = tryTypeString("[999999999999999i]", "huge array count");
        if (r == -1) {
            TEST_ASSERT(0, "Huge array count should not crash");
        } else {
            TEST_ASSERT(1, "Huge array count handled without crash");
        }

        return TEST_SUMMARY();
    }
}
