/*
 * test_json_depth.m - RB-8: Deeply nested JSON causes stack overflow
 *
 * Create deeply nested JSON (10000 levels of [[[...]]]).
 * Parse it with NSJSONSerialization.
 * After fix: returns nil with error (depth limit exceeded).
 * Before fix: stack overflow / crash from recursive descent.
 */
#import <Foundation/Foundation.h>
#include "../../common/test_utils.h"
#include <signal.h>
#include <setjmp.h>

#define NESTING_DEPTH 10000

static sigjmp_buf jumpBuf;
static volatile sig_atomic_t gotSignal = 0;

static void segfaultHandler(int sig) {
    (void)sig;
    gotSignal = 1;
    siglongjmp(jumpBuf, 1);
}

int main(void) {
    @autoreleasepool {
        printf("=== test_json_depth (RB-8) ===\n");

        /*
         * Build deeply nested JSON: [[[...[null]...]]]
         * 10000 levels of nesting should exceed any reasonable stack.
         */
        NSMutableString *json = [NSMutableString stringWithCapacity:NESTING_DEPTH * 2 + 4];
        for (int i = 0; i < NESTING_DEPTH; i++) {
            [json appendString:@"["];
        }
        [json appendString:@"null"];
        for (int i = 0; i < NESTING_DEPTH; i++) {
            [json appendString:@"]"];
        }

        NSData *jsonData = [json dataUsingEncoding:NSUTF8StringEncoding];
        TEST_ASSERT_NOT_NULL(jsonData, "JSON data should be created");

        printf("  Created JSON with %d levels of nesting (%lu bytes)\n",
               NESTING_DEPTH, (unsigned long)[jsonData length]);

        /*
         * Install signal handler to catch stack overflow (SIGSEGV/SIGBUS).
         * If the parser has no depth limit, it will recurse until stack
         * overflow, causing a crash.
         */
        struct sigaction sa, oldSa, oldBus;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = segfaultHandler;
        sa.sa_flags = 0;
        sigaction(SIGSEGV, &sa, &oldSa);
        sigaction(SIGBUS, &sa, &oldBus);

        NSError *error = nil;
        id result = nil;
        BOOL crashed = NO;

        if (sigsetjmp(jumpBuf, 1) == 0) {
            result = [NSJSONSerialization JSONObjectWithData:jsonData
                                                    options:0
                                                      error:&error];
        } else {
            crashed = YES;
        }

        /* Restore signal handlers */
        sigaction(SIGSEGV, &oldSa, NULL);
        sigaction(SIGBUS, &oldBus, NULL);

        if (crashed) {
            printf("  DETECTED: Stack overflow during JSON parsing!\n");
            printf("  This confirms RB-8: no depth limit on JSON parsing.\n");
            TEST_ASSERT(0, "JSON parser should not crash on deep nesting");
        } else if (result == nil && error != nil) {
            printf("  JSON parser correctly rejected deeply nested input.\n");
            printf("  Error: %s\n", [[error localizedDescription] UTF8String]);
            TEST_ASSERT(1, "Deep JSON rejected with error (depth limit works)");
        } else if (result != nil) {
            /*
             * Parser succeeded without crashing on 10000 levels.
             * This might be OK if using iterative parsing, but suspicious.
             */
            printf("  Parser succeeded on %d levels of nesting.\n", NESTING_DEPTH);
            printf("  If iterative parser: OK. If recursive: lucky stack.\n");
            TEST_ASSERT(1, "Parser handled deep nesting without crash");
        } else {
            /* result == nil, error == nil: unusual */
            printf("  Parser returned nil with no error.\n");
            TEST_ASSERT(0, "Parser should return error, not silent nil");
        }

        /* Also test a moderately nested JSON that should succeed */
        NSMutableString *moderate = [NSMutableString stringWithCapacity:200];
        for (int i = 0; i < 20; i++) {
            [moderate appendString:@"["];
        }
        [moderate appendString:@"42"];
        for (int i = 0; i < 20; i++) {
            [moderate appendString:@"]"];
        }
        NSData *modData = [moderate dataUsingEncoding:NSUTF8StringEncoding];
        NSError *modError = nil;
        id modResult = [NSJSONSerialization JSONObjectWithData:modData
                                                      options:0
                                                        error:&modError];
        TEST_ASSERT(modResult != nil,
                    "Moderately nested JSON (20 levels) should parse OK");

        return TEST_SUMMARY();
    }
}
