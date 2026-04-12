/*
 * test_cfstring_surrogate.m - BUG-6: CFStringGetSurrogatePairForLongCharacter
 *
 * The function uses "character > 0x10000" as the rejection condition,
 * but it should be "character > 0x10FFFF". The current code also fails
 * to accept exactly U+10000 because > should be >= for the lower bound
 * check (supplementary characters start at U+10000).
 *
 * Actually the bug is the opposite: the check rejects characters that
 * SHOULD be valid. Valid supplementary plane characters are U+10000..U+10FFFF.
 * The code says: if (character > 0x10000) return false — this incorrectly
 * rejects all supplementary characters except... wait, it rejects characters
 * ABOVE 0x10000, meaning U+10001 and above are rejected. And U+10000 itself
 * passes but is not actually a supplementary character needing surrogates
 * (it's the first one). The condition should be:
 *   if (character < 0x10000 || character > 0x10FFFF) return false;
 *
 * This test verifies U+10001 (a valid supplementary character) produces
 * a valid surrogate pair.
 */

#import <Foundation/Foundation.h>
#include <CoreFoundation/CFString.h>
#include <stdint.h>

#include "../../common/test_utils.h"

int main(void)
{
    @autoreleasepool {
        printf("=== test_cfstring_surrogate (BUG-6) ===\n");
        printf("Validates CFStringGetSurrogatePairForLongCharacter.\n\n");

        UniChar surrogates[2] = { 0, 0 };

        /* U+10001 = LINEAR B SYLLABLE B008 A
         * Valid supplementary character, needs surrogate pair.
         * Expected: high=0xD800, low=0xDC01 */
        UTF32Char testChar = 0x10001;
        Boolean result = CFStringGetSurrogatePairForLongCharacter(
            testChar, surrogates);

        /* Before fix: result == false (rejected by > 0x10000 check)
         * After fix:  result == true */
        TEST_ASSERT(result == true,
                    "U+10001 should be accepted as valid supplementary char");

        if (result) {
            /* Verify the surrogate pair values */
            TEST_ASSERT(CFStringIsSurrogateHighCharacter(surrogates[0]),
                        "first element is a high surrogate");
            TEST_ASSERT(CFStringIsSurrogateLowCharacter(surrogates[1]),
                        "second element is a low surrogate");

            /* Verify roundtrip: surrogates -> code point */
            UTF32Char roundtrip = CFStringGetLongCharacterForSurrogatePair(
                surrogates[0], surrogates[1]);
            TEST_ASSERT_EQUAL(roundtrip, testChar,
                              "surrogate pair round-trips to original");

            printf("  U+%05X -> surrogates: 0x%04X 0x%04X\n",
                   testChar, surrogates[0], surrogates[1]);
        }

        /* Also test U+10FFFF (maximum valid Unicode) */
        UTF32Char maxChar = 0x10FFFF;
        surrogates[0] = surrogates[1] = 0;
        result = CFStringGetSurrogatePairForLongCharacter(maxChar, surrogates);

        /* Before fix: result == false (rejected by > 0x10000)
         * After fix:  result == true */
        TEST_ASSERT(result == true,
                    "U+10FFFF should be accepted (max valid Unicode)");

        /* Test that BMP characters are rejected (they don't need surrogates) */
        surrogates[0] = surrogates[1] = 0;
        result = CFStringGetSurrogatePairForLongCharacter(0x0041, surrogates);
        /* U+0041 = 'A', a BMP character. Should be rejected. */
        TEST_ASSERT(result == false,
                    "U+0041 (BMP) should be rejected");

        /* Test that above U+10FFFF is rejected */
        surrogates[0] = surrogates[1] = 0;
        result = CFStringGetSurrogatePairForLongCharacter(0x110000, surrogates);
        TEST_ASSERT(result == false,
                    "U+110000 (above max) should be rejected");

        return TEST_SUMMARY();
    }
}
