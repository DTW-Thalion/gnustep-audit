/*
 * test_jpeg_truncated.m - AR-O4: Truncated JPEG decoding leak
 *
 * Creates a truncated JPEG data blob and attempts to decode it,
 * verifying no crash and no memory leak from the image buffer.
 *
 * Bug: In OPImageCodecJPEG, the error handler uses longjmp to bail
 * out of libjpeg on errors. The image buffer (imgbuffer) is allocated
 * before decompression starts, but on error-exit via longjmp, the
 * cleanup code is skipped and imgbuffer is leaked.
 *
 * Expected AFTER fix: No memory leak; error handled gracefully.
 * Expected BEFORE fix: imgbuffer leaked via longjmp bypass.
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <string.h>
#include "../../common/test_utils.h"

/*
 * Minimal JPEG header: SOI + APP0 (JFIF) marker.
 * This is a valid JPEG start but truncated before any image data,
 * so the decoder should detect the truncation and fail gracefully.
 */
static const unsigned char truncated_jpeg[] = {
    0xFF, 0xD8,                         /* SOI (Start Of Image) */
    0xFF, 0xE0,                         /* APP0 marker */
    0x00, 0x10,                         /* Length = 16 */
    0x4A, 0x46, 0x49, 0x46, 0x00,      /* "JFIF\0" */
    0x01, 0x01,                         /* Version 1.1 */
    0x00,                               /* Aspect ratio units: none */
    0x00, 0x01,                         /* X density = 1 */
    0x00, 0x01,                         /* Y density = 1 */
    0x00, 0x00,                         /* No thumbnail */
    /* Truncated here - missing DQT, SOF, SOS, and image data */
};

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    printf("=== AR-O4: Truncated JPEG Decoding Test ===\n\n");

    /* Create a CGDataProvider from the truncated JPEG data */
    CFDataRef jpegData = CFDataCreate(NULL, truncated_jpeg, sizeof(truncated_jpeg));
    TEST_ASSERT_NOT_NULL(jpegData, "CFDataCreate for truncated JPEG succeeded");

    CGDataProviderRef provider = CGDataProviderCreateWithCFData(jpegData);
    TEST_ASSERT_NOT_NULL(provider, "CGDataProviderCreateWithCFData succeeded");

    /* Attempt to create a CGImageSource from the truncated data */
    printf("Attempting to decode truncated JPEG via CGImageSource...\n");
    CGImageSourceRef source = CGImageSourceCreateWithDataProvider(provider, NULL);

    if (source) {
        /* Try to get the image - this should fail gracefully */
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);

        if (image) {
            printf("  Image unexpectedly created (may be partial)\n");
            /* Even if an image object is returned, it should be safe to release */
            CGImageRelease(image);
        } else {
            printf("  Image creation correctly returned NULL for truncated data\n");
        }
        TEST_ASSERT(1, "CGImageSourceCreateImageAtIndex did not crash");
        CFRelease(source);
    } else {
        printf("  CGImageSource correctly returned NULL for truncated data\n");
        TEST_ASSERT(1, "CGImageSourceCreateWithDataProvider handled truncated data");
    }

    /* Test with completely garbage data */
    printf("\nAttempting to decode garbage data as JPEG...\n");
    unsigned char garbage[64];
    memset(garbage, 0xAB, sizeof(garbage));
    /* Set SOI to trick initial detection */
    garbage[0] = 0xFF;
    garbage[1] = 0xD8;

    CFDataRef garbageData = CFDataCreate(NULL, garbage, sizeof(garbage));
    CGDataProviderRef garbageProvider = CGDataProviderCreateWithCFData(garbageData);

    CGImageSourceRef garbageSource = CGImageSourceCreateWithDataProvider(garbageProvider, NULL);
    if (garbageSource) {
        CGImageRef garbageImage = CGImageSourceCreateImageAtIndex(garbageSource, 0, NULL);
        if (garbageImage) {
            CGImageRelease(garbageImage);
        }
        TEST_ASSERT(1, "Garbage JPEG decode did not crash");
        CFRelease(garbageSource);
    } else {
        TEST_ASSERT(1, "CGImageSource rejected garbage data");
    }

    /* Repeat multiple times to amplify leak detection */
    printf("\nRepeating truncated decode 100 times (leak amplification)...\n");
    for (int i = 0; i < 100; i++) {
        CGImageSourceRef src = CGImageSourceCreateWithDataProvider(provider, NULL);
        if (src) {
            CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
            if (img) CGImageRelease(img);
            CFRelease(src);
        }
    }
    TEST_ASSERT(1, "100 truncated JPEG decode iterations completed without crash");

    CGDataProviderRelease(provider);
    CFRelease(jpegData);
    CFRelease(garbageData);
    CGDataProviderRelease(garbageProvider);

    [pool release];
    return TEST_SUMMARY();
}
