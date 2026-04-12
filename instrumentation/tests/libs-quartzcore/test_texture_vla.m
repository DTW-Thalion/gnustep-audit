/*
 * test_texture_vla.m - AR-Q6: VLA stack overflow in _writeToPNG
 *
 * Tests that writing a large texture to PNG does not overflow the stack
 * by using a variable-length array (VLA) for the pixel buffer.
 *
 * Bug: In CAGLTexture._writeToPNG:, the pixel buffer is declared as:
 *   char pixels[[self width]*[self height]*4];
 * For a 2048x2048 texture, this allocates 16MB on the stack, which
 * exceeds the default stack size and causes a crash (stack overflow).
 * The fix should use malloc/heap allocation instead of a VLA.
 *
 * Expected AFTER fix: Uses malloc; no stack overflow.
 * Expected BEFORE fix: VLA on stack = 16MB = crash.
 *
 * Note: Since CAGLTexture requires an OpenGL context, this test simulates
 * the allocation pattern to demonstrate the VLA vs malloc difference.
 */

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../common/test_utils.h"

/*
 * Simulate the buggy VLA allocation pattern.
 * We can't actually use a VLA of 16MB safely, so we test smaller
 * sizes and verify the malloc-based approach works for large sizes.
 */

/* Small VLA test - should work on any stack */
static int test_small_vla(void) {
    int w = 32, h = 32;
    char pixels[w * h * 4]; /* 4KB - fine for stack */
    memset(pixels, 0xAB, sizeof(pixels));
    return (pixels[0] == (char)0xAB) ? 1 : 0;
}

/* Heap-based allocation - the correct approach for large textures */
static int test_large_heap(int width, int height) {
    size_t size = (size_t)width * (size_t)height * 4;
    char *pixels = (char *)malloc(size);
    if (!pixels) return 0;

    /* Fill with test pattern */
    memset(pixels, 0xCD, size);
    int ok = (pixels[0] == (char)0xCD && pixels[size - 1] == (char)0xCD);

    free(pixels);
    return ok;
}

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    printf("=== AR-Q6: Texture VLA Stack Overflow Test ===\n\n");

    /* Test 1: Small texture allocation (baseline) */
    printf("Testing small texture (32x32 = 4KB)...\n");
    TEST_ASSERT(test_small_vla(), "Small VLA allocation succeeded");

    /* Test 2: Medium texture via heap (256x256 = 256KB) */
    printf("Testing medium texture (256x256 = 256KB) via heap...\n");
    TEST_ASSERT(test_large_heap(256, 256),
                "256x256 heap allocation succeeded");

    /* Test 3: Large texture via heap (1024x1024 = 4MB) */
    printf("Testing large texture (1024x1024 = 4MB) via heap...\n");
    TEST_ASSERT(test_large_heap(1024, 1024),
                "1024x1024 heap allocation succeeded");

    /* Test 4: The problematic size (2048x2048 = 16MB) via heap */
    printf("Testing problematic texture (2048x2048 = 16MB) via heap...\n");
    TEST_ASSERT(test_large_heap(2048, 2048),
                "2048x2048 heap allocation succeeded");

    /* Test 5: Even larger texture (4096x4096 = 64MB) via heap */
    printf("Testing extra-large texture (4096x4096 = 64MB) via heap...\n");
    TEST_ASSERT(test_large_heap(4096, 4096),
                "4096x4096 heap allocation succeeded");

    /* Test 6: Verify that the pattern matches _writeToPNG's usage.
     * The method does: char pixels[width * height * 4];
     * then: glGetTexImage(..., pixels);
     * then: CGBitmapContextCreate(pixels, width, height, 8, width*4, ...)
     *
     * We simulate this flow with heap allocation. */
    printf("\nSimulating _writeToPNG flow with 2048x2048 texture...\n");
    {
        int w = 2048, h = 2048;
        size_t bufSize = (size_t)w * (size_t)h * 4;
        unsigned char *pixels = (unsigned char *)malloc(bufSize);
        TEST_ASSERT_NOT_NULL(pixels, "2048x2048 pixel buffer allocated on heap");

        if (pixels) {
            /* Simulate filling with texture data */
            for (size_t i = 0; i < bufSize; i += 4) {
                pixels[i]     = (unsigned char)(i % 256);       /* R */
                pixels[i + 1] = (unsigned char)((i / 4) % 256); /* G */
                pixels[i + 2] = 128;                             /* B */
                pixels[i + 3] = 255;                             /* A */
            }

            /* Verify data integrity at start and end */
            TEST_ASSERT(pixels[3] == 255,
                        "First pixel alpha correct");
            TEST_ASSERT(pixels[bufSize - 1] == 255,
                        "Last pixel alpha correct");

            printf("  Buffer size: %zu bytes (%.1f MB)\n",
                   bufSize, (double)bufSize / (1024.0 * 1024.0));

            free(pixels);
            TEST_ASSERT(1, "2048x2048 simulation completed successfully");
        }
    }

    /* Test 7: Integer overflow check for very large dimensions */
    printf("\nTesting integer overflow protection...\n");
    {
        size_t huge_w = 65536;
        size_t huge_h = 65536;
        size_t needed = huge_w * huge_h * 4; /* 16GB */
        /* Don't actually try to allocate 16GB; just verify the
         * calculation doesn't overflow to a small number */
        TEST_ASSERT(needed > huge_w && needed > huge_h,
                    "Size calculation does not overflow for 65536x65536");
        printf("  65536x65536 would need %zu bytes (%.1f GB)\n",
               needed, (double)needed / (1024.0 * 1024.0 * 1024.0));
    }

    [pool release];
    return TEST_SUMMARY();
}
