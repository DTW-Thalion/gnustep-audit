/*
 * test_tiff_write.m - AR-O7: TIFF write via CGImageDestination
 *
 * Creates a simple CGImage and writes it as TIFF via CGImageDestination.
 *
 * Bug: In OPImageCodecTIFF, an init condition is inverted, causing
 * CGImageDestinationFinalize to always fail when writing TIFF output.
 *
 * Expected AFTER fix: Produces valid TIFF data (non-empty output).
 * Expected BEFORE fix: init condition inverted, always fails.
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include "../../common/test_utils.h"

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    printf("=== AR-O7: TIFF Write via CGImageDestination Test ===\n\n");

    /* Create a small 4x4 RGBA bitmap context */
    size_t width = 4;
    size_t height = 4;
    size_t bitsPerComponent = 8;
    size_t bytesPerRow = width * 4;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    TEST_ASSERT_NOT_NULL(colorSpace, "CGColorSpaceCreateDeviceRGB succeeded");

    CGContextRef ctx = CGBitmapContextCreate(
        NULL, width, height, bitsPerComponent, bytesPerRow,
        colorSpace, kCGImageAlphaPremultipliedLast);
    TEST_ASSERT_NOT_NULL(ctx, "CGBitmapContextCreate succeeded");

    /* Fill the bitmap with a solid color so we have real pixel data */
    CGContextSetRGBFillColor(ctx, 1.0, 0.0, 0.0, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, width, height));

    /* Extract CGImage from bitmap context */
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    TEST_ASSERT_NOT_NULL(image, "CGBitmapContextCreateImage succeeded");

    /* Write TIFF to an in-memory NSMutableData via CGImageDestination */
    NSMutableData *tiffData = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(
        (CFMutableDataRef)tiffData,
        (CFStringRef)@"public.tiff",
        1, NULL);
    TEST_ASSERT_NOT_NULL(dest, "CGImageDestinationCreateWithData succeeded for TIFF");

    if (dest) {
        CGImageDestinationAddImage(dest, image, NULL);
        bool finalized = CGImageDestinationFinalize(dest);
        TEST_ASSERT(finalized, "CGImageDestinationFinalize returned true");

        /* Verify output is non-empty */
        TEST_ASSERT([tiffData length] > 0,
                     "TIFF output data is non-empty");

        /* Check for TIFF magic bytes: 0x49 0x49 (little-endian) or 0x4D 0x4D (big-endian) */
        if ([tiffData length] >= 2) {
            const unsigned char *bytes = (const unsigned char *)[tiffData bytes];
            BOOL validMagic = (bytes[0] == 0x49 && bytes[1] == 0x49) ||
                              (bytes[0] == 0x4D && bytes[1] == 0x4D);
            TEST_ASSERT(validMagic, "TIFF data has valid magic bytes");
            printf("  TIFF magic: 0x%02X 0x%02X (length: %lu)\n",
                   bytes[0], bytes[1], (unsigned long)[tiffData length]);
        }

        CFRelease(dest);
    }

    /* Cleanup */
    CGImageRelease(image);
    CGContextRelease(ctx);
    CGColorSpaceRelease(colorSpace);

    [pool release];
    return TEST_SUMMARY();
}
