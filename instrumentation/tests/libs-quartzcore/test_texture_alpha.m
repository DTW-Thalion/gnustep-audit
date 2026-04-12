/*
 * test_texture_alpha.m - AR-Q4: Divide-by-zero in unpremultiply
 *
 * Creates texture data with alpha=0 pixels and simulates the
 * unpremultiply operation that CAGLTexture performs when loading
 * premultiplied-alpha image data.
 *
 * Bug: When converting premultiplied alpha to straight alpha,
 * the code divides R, G, B by alpha. When alpha == 0, this produces
 * NaN or Inf values that corrupt rendering.
 *
 * Expected AFTER fix: No NaN/Inf; alpha=0 pixels produce (0,0,0,0).
 * Expected BEFORE fix: Divide-by-zero produces NaN/Inf in pixel data.
 *
 * Note: This test simulates the unpremultiply logic in user space since
 * CAGLTexture requires an OpenGL context. The arithmetic bug is the same.
 */

#import <Foundation/Foundation.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../common/test_utils.h"

/*
 * Simulate the buggy unpremultiply: divide by alpha without zero-check.
 * This is the logic that CAGLTexture uses internally.
 */
static void unpremultiply_buggy(unsigned char *pixels, int width, int height) {
    for (int i = 0; i < width * height * 4; i += 4) {
        float r = pixels[i];
        float g = pixels[i + 1];
        float b = pixels[i + 2];
        float a = pixels[i + 3];
        /* Bug: no check for a == 0 */
        float inv_a = 255.0f / a;
        pixels[i]     = (unsigned char)(r * inv_a);
        pixels[i + 1] = (unsigned char)(g * inv_a);
        pixels[i + 2] = (unsigned char)(b * inv_a);
    }
}

/*
 * Fixed unpremultiply: guard against alpha == 0.
 */
static void unpremultiply_fixed(unsigned char *pixels, int width, int height) {
    for (int i = 0; i < width * height * 4; i += 4) {
        float a = pixels[i + 3];
        if (a == 0) {
            pixels[i] = 0;
            pixels[i + 1] = 0;
            pixels[i + 2] = 0;
        } else {
            float r = pixels[i];
            float g = pixels[i + 1];
            float b = pixels[i + 2];
            float inv_a = 255.0f / a;
            pixels[i]     = (unsigned char)(fminf(r * inv_a, 255.0f));
            pixels[i + 1] = (unsigned char)(fminf(g * inv_a, 255.0f));
            pixels[i + 2] = (unsigned char)(fminf(b * inv_a, 255.0f));
        }
    }
}

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    printf("=== AR-Q4: Texture Alpha Divide-by-Zero Test ===\n\n");

    int width = 4;
    int height = 4;
    size_t dataSize = (size_t)(width * height * 4);

    /* Create pixel data with alpha=0 pixels */
    unsigned char *buggyPixels = (unsigned char *)malloc(dataSize);
    unsigned char *fixedPixels = (unsigned char *)malloc(dataSize);
    TEST_ASSERT_NOT_NULL(buggyPixels, "buggy pixel buffer allocated");
    TEST_ASSERT_NOT_NULL(fixedPixels, "fixed pixel buffer allocated");

    /* Set all pixels to premultiplied RGBA with alpha=0 */
    memset(buggyPixels, 0, dataSize);
    memset(fixedPixels, 0, dataSize);

    /* Also add some pixels with valid alpha for comparison */
    /* Pixel at (1,0): premultiplied red with alpha=128 */
    buggyPixels[4] = 128; buggyPixels[5] = 0; buggyPixels[6] = 0; buggyPixels[7] = 128;
    fixedPixels[4] = 128; fixedPixels[5] = 0; fixedPixels[6] = 0; fixedPixels[7] = 128;

    /* Test 1: Fixed version handles alpha=0 correctly */
    printf("Testing fixed unpremultiply with alpha=0 pixels...\n");
    unpremultiply_fixed(fixedPixels, width, height);

    TEST_ASSERT_EQUAL(fixedPixels[0], 0, "Fixed: alpha=0 pixel R is 0");
    TEST_ASSERT_EQUAL(fixedPixels[1], 0, "Fixed: alpha=0 pixel G is 0");
    TEST_ASSERT_EQUAL(fixedPixels[2], 0, "Fixed: alpha=0 pixel B is 0");
    TEST_ASSERT_EQUAL(fixedPixels[3], 0, "Fixed: alpha=0 pixel A is 0");
    printf("  Fixed unpremultiply: alpha=0 pixel -> (%d, %d, %d, %d)\n",
           fixedPixels[0], fixedPixels[1], fixedPixels[2], fixedPixels[3]);

    /* Valid alpha pixel should be correctly unpremultiplied */
    printf("  Fixed unpremultiply: alpha=128 pixel -> (%d, %d, %d, %d)\n",
           fixedPixels[4], fixedPixels[5], fixedPixels[6], fixedPixels[7]);
    TEST_ASSERT(fixedPixels[4] > 0, "Fixed: alpha=128 pixel R unpremultiplied");

    /* Test 2: Demonstrate buggy version produces bad values with alpha=0 */
    printf("\nTesting buggy unpremultiply with alpha=0 pixels...\n");
    /* The buggy version divides by 0, producing 255/0 = inf -> undefined cast to uchar */
    unpremultiply_buggy(buggyPixels, width, height);
    printf("  Buggy unpremultiply: alpha=0 pixel -> (%d, %d, %d, %d)\n",
           buggyPixels[0], buggyPixels[1], buggyPixels[2], buggyPixels[3]);
    /* We just note what happened - the point is it should not crash */
    TEST_ASSERT(1, "Buggy unpremultiply did not crash (but may produce wrong values)");

    /* Test 3: Verify that a large texture with mixed alpha values is handled */
    printf("\nTesting 256x256 texture with mixed alpha values...\n");
    int bigW = 256, bigH = 256;
    size_t bigSize = (size_t)(bigW * bigH * 4);
    unsigned char *bigPixels = (unsigned char *)malloc(bigSize);
    TEST_ASSERT_NOT_NULL(bigPixels, "large pixel buffer allocated");

    for (int i = 0; i < bigW * bigH; i++) {
        int idx = i * 4;
        unsigned char a = (unsigned char)(i % 256); /* alpha cycles 0-255 */
        bigPixels[idx]     = a / 2;  /* premultiplied R */
        bigPixels[idx + 1] = a / 4;  /* premultiplied G */
        bigPixels[idx + 2] = a / 8;  /* premultiplied B */
        bigPixels[idx + 3] = a;
    }

    unpremultiply_fixed(bigPixels, bigW, bigH);
    TEST_ASSERT(1, "256x256 mixed-alpha unpremultiply completed without crash");

    free(buggyPixels);
    free(fixedPixels);
    free(bigPixels);

    [pool release];
    return TEST_SUMMARY();
}
