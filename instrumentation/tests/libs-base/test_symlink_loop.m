/*
 * test_symlink_loop.m - RB-15: Directory enumeration with symlink loops
 *
 * Create a directory containing a symlink that points back to its parent.
 * Enumerate it with NSFileManager / NSDirectoryEnumerator.
 * After fix: enumeration terminates. Before fix: infinite loop.
 */
#import <Foundation/Foundation.h>
#include "../../common/test_utils.h"
#include <signal.h>

#define MAX_ENUM_ITEMS 10000
#define TIMEOUT_SECONDS 10

static volatile sig_atomic_t timedOut = 0;

static void alarmHandler(int sig) {
    (void)sig;
    timedOut = 1;
}

int main(void) {
    @autoreleasepool {
        printf("=== test_symlink_loop (RB-15) ===\n");

        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *tmpBase = NSTemporaryDirectory();
        NSString *testDir = [tmpBase stringByAppendingPathComponent:
                             @"gnustep_symlink_test"];

        /* Clean up any previous test remnants */
        [fm removeItemAtPath:testDir error:nil];

        /* Create test directory structure */
        NSString *subDir = [testDir stringByAppendingPathComponent:@"subdir"];
        NSError *error = nil;
        BOOL created = [fm createDirectoryAtPath:subDir
                     withIntermediateDirectories:YES
                                      attributes:nil
                                           error:&error];
        TEST_ASSERT(created, "Created test directory structure");

        if (!created) {
            printf("  Could not create test dirs: %s\n",
                   [[error localizedDescription] UTF8String]);
            return TEST_SUMMARY();
        }

        /* Create a regular file in subdir */
        NSString *filePath = [subDir stringByAppendingPathComponent:@"file.txt"];
        [@"test content" writeToFile:filePath
                          atomically:YES
                            encoding:NSUTF8StringEncoding
                               error:nil];

        /* Create a symlink in subdir pointing back to the parent testDir */
        NSString *linkPath = [subDir stringByAppendingPathComponent:@"loop"];
        error = nil;
        BOOL linked = [fm createSymbolicLinkAtPath:linkPath
                               withDestinationPath:testDir
                                             error:&error];

        if (!linked) {
            printf("  Could not create symlink: %s\n",
                   [[error localizedDescription] UTF8String]);
            printf("  (May need elevated privileges on Windows)\n");
            /* Still test enumeration without symlink loop */
            TEST_ASSERT(1, "Symlink creation not supported, skip loop test");
            [fm removeItemAtPath:testDir error:nil];
            return TEST_SUMMARY();
        }

        TEST_ASSERT(linked, "Created symlink loop");
        printf("  Created symlink: %s -> %s\n",
               [linkPath UTF8String], [testDir UTF8String]);

        /*
         * Enumerate the directory tree. With a symlink loop and no
         * cycle detection, this will loop forever.
         * Set an alarm to catch infinite loops.
         */
        signal(SIGALRM, alarmHandler);
        alarm(TIMEOUT_SECONDS);

        NSDirectoryEnumerator *enumerator =
            [fm enumeratorAtPath:testDir];
        TEST_ASSERT_NOT_NULL(enumerator, "Directory enumerator created");

        int itemCount = 0;
        BOOL reachedLimit = NO;
        NSString *item;

        while ((item = [enumerator nextObject]) != nil && !timedOut) {
            itemCount++;
            if (itemCount > MAX_ENUM_ITEMS) {
                reachedLimit = YES;
                break;
            }
        }

        alarm(0); /* Cancel alarm */
        signal(SIGALRM, SIG_DFL);

        printf("  Enumerated %d items\n", itemCount);

        if (timedOut) {
            printf("  TIMEOUT: Enumeration did not terminate in %d seconds!\n",
                   TIMEOUT_SECONDS);
            printf("  This confirms RB-15: symlink loop causes infinite enumeration.\n");
            TEST_ASSERT(0, "Enumeration should terminate with symlink loop");
        } else if (reachedLimit) {
            printf("  Hit item limit (%d) - likely in a symlink loop.\n",
                   MAX_ENUM_ITEMS);
            TEST_ASSERT(0, "Enumeration should not follow symlink loops");
        } else {
            printf("  Enumeration completed normally with %d items.\n", itemCount);
            TEST_ASSERT(1, "Enumeration terminates with symlink loop (cycle detection works)");
        }

        /*
         * Also test with enumeratorAtURL:includingPropertiesForKeys:options:
         * which may have different symlink handling.
         */
        timedOut = 0;
        alarm(TIMEOUT_SECONDS);

        NSURL *testURL = [NSURL fileURLWithPath:testDir];
        NSDirectoryEnumerator *urlEnum =
            [fm enumeratorAtURL:testURL
     includingPropertiesForKeys:@[NSURLIsSymbolicLinkKey]
                        options:0
                   errorHandler:nil];

        itemCount = 0;
        reachedLimit = NO;
        NSURL *urlItem;

        while ((urlItem = [urlEnum nextObject]) != nil && !timedOut) {
            itemCount++;
            if (itemCount > MAX_ENUM_ITEMS) {
                reachedLimit = YES;
                break;
            }
        }

        alarm(0);
        signal(SIGALRM, SIG_DFL);

        printf("  URL enumerator: %d items\n", itemCount);

        if (timedOut || reachedLimit) {
            printf("  URL enumerator also stuck in symlink loop.\n");
            TEST_ASSERT(0, "URL enumerator should handle symlink loops");
        } else {
            TEST_ASSERT(1, "URL enumerator handles symlink loops correctly");
        }

        /* Clean up */
        /* Remove symlink first to avoid recursive issues */
        [fm removeItemAtPath:linkPath error:nil];
        [fm removeItemAtPath:testDir error:nil];

        return TEST_SUMMARY();
    }
}
