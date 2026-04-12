/*
 * test_nscfstring_recurse.m - BUG-8: NSCFString infinite recursion
 *
 * In NSCFString.m, lengthOfBytesUsingEncoding: is implemented as:
 *   - (NSUInteger) lengthOfBytesUsingEncoding: (NSStringEncoding) encoding
 *   {
 *     return [self lengthOfBytesUsingEncoding: encoding];
 *   }
 *
 * This calls itself infinitely, causing a stack overflow.
 * It should convert the encoding and delegate to CFStringGetBytes or similar.
 *
 * This test calls lengthOfBytesUsingEncoding: on a toll-free bridged
 * CFString (which becomes an NSCFString). Before fix: stack overflow crash.
 * After fix: returns valid byte length.
 *
 * NOTE: We set a stack size limit and use a signal handler to catch the
 * stack overflow gracefully if the bug is present.
 */

#import <Foundation/Foundation.h>
#include <CoreFoundation/CFString.h>
#include <signal.h>
#include <setjmp.h>

#include "../../common/test_utils.h"

static jmp_buf jumpBuf;
static volatile int caughtOverflow = 0;

static void segfault_handler(int sig)
{
    (void)sig;
    caughtOverflow = 1;
    longjmp(jumpBuf, 1);
}

int main(void)
{
    @autoreleasepool {
        printf("=== test_nscfstring_recurse (BUG-8) ===\n");
        printf("Tests lengthOfBytesUsingEncoding: on NSCFString.\n\n");

        /* Create a CFString and toll-free bridge to NSString */
        CFStringRef cfStr = CFStringCreateWithCString(
            kCFAllocatorDefault,
            "Hello, World!",
            kCFStringEncodingUTF8);
        TEST_ASSERT_NOT_NULL(cfStr, "CFString created");

        NSString *nsStr = (__bridge NSString *)cfStr;
        TEST_ASSERT_NOT_NULL(nsStr, "toll-free bridged to NSString");

        /* Install signal handler to catch stack overflow (SIGSEGV/SIGBUS) */
        struct sigaction sa, oldSA, oldBus;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = segfault_handler;
        sa.sa_flags = 0;
        sigaction(SIGSEGV, &sa, &oldSA);
        sigaction(SIGBUS, &sa, &oldBus);

        NSUInteger byteLen = 0;

        if (setjmp(jumpBuf) == 0) {
            /* Try calling the potentially recursive method */
            byteLen = [nsStr lengthOfBytesUsingEncoding: NSUTF8StringEncoding];

            /* If we get here, no infinite recursion */
            TEST_ASSERT(byteLen > 0,
                        "lengthOfBytesUsingEncoding returned non-zero");
            TEST_ASSERT_EQUAL((int)byteLen, 13,
                              "byte length correct for 'Hello, World!'");
            printf("  lengthOfBytesUsingEncoding: returned %lu\n",
                   (unsigned long)byteLen);
        } else {
            /* We caught a stack overflow via signal handler */
            TEST_ASSERT(0,
                        "lengthOfBytesUsingEncoding caused stack overflow "
                        "(infinite recursion BUG-8)");
        }

        /* Restore signal handlers */
        sigaction(SIGSEGV, &oldSA, NULL);
        sigaction(SIGBUS, &oldBus, NULL);

        CFRelease(cfStr);

        return TEST_SUMMARY();
    }
}
