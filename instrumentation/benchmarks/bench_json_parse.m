/*
 * bench_json_parse.m - JSON parse throughput benchmark
 *
 * Generates a representative JSON document (1000 objects with mixed types)
 * and measures parse throughput in MB/s using NSJSONSerialization.
 *
 * Targets: buffer size, integer detection optimizations
 *
 * Usage: ./bench_json_parse [--json]
 */

#import <Foundation/Foundation.h>
#include "bench_harness.h"

#define NUM_OBJECTS 1000
#define ITERATIONS  1000

static NSData *generateJSON(void) {
    NSMutableString *json = [NSMutableString stringWithString:@"["];
    for (int i = 0; i < NUM_OBJECTS; i++) {
        if (i > 0) [json appendString:@","];
        [json appendFormat:
            @"{\"id\":%d,"
            @"\"name\":\"object_%d\","
            @"\"value\":%d.%d,"
            @"\"active\":%@,"
            @"\"tags\":[\"tag_a\",\"tag_b\",\"tag_c\"],"
            @"\"nested\":{\"x\":%d,\"y\":%d,\"label\":\"nested_%d\"}}",
            i, i,
            i * 17, i % 100,
            (i % 2 == 0) ? @"true" : @"false",
            i % 1000, (i * 7) % 1000, i];
    }
    [json appendString:@"]"];
    return [json dataUsingEncoding:NSUTF8StringEncoding];
}

int main(int argc, char *argv[]) {
    int json_flag = (argc > 1 && strcmp(argv[1], "--json") == 0);

    @autoreleasepool {
        NSData *jsonData = [generateJSON() retain];
        NSUInteger dataLen = [jsonData length];

        printf("JSON document size: %lu bytes (%.1f KB)\n",
               (unsigned long)dataLen, (double)dataLen / 1024.0);

        /* Benchmark 1: Full parse */
        if (json_flag) {
            BENCH_JSON("json_parse_full", ITERATIONS, {
                @autoreleasepool {
                    id result = [NSJSONSerialization JSONObjectWithData:jsonData
                                                               options:0
                                                                 error:NULL];
                    (void)result;
                }
            });
        } else {
            BENCH("json_parse_full", ITERATIONS, {
                @autoreleasepool {
                    id result = [NSJSONSerialization JSONObjectWithData:jsonData
                                                               options:0
                                                                 error:NULL];
                    (void)result;
                }
            });
        }

        /* Compute MB/s */
        {
            double start = bench_time_ns();
            for (int i = 0; i < ITERATIONS; i++) {
                @autoreleasepool {
                    id result = [NSJSONSerialization JSONObjectWithData:jsonData
                                                               options:0
                                                                 error:NULL];
                    (void)result;
                }
            }
            double elapsed_s = (bench_time_ns() - start) / 1e9;
            double total_mb = (double)dataLen * ITERATIONS / (1024.0 * 1024.0);
            double mb_per_sec = total_mb / elapsed_s;
            if (json_flag) {
                printf("{\"bench\":\"json_parse_throughput_mb_s\","
                       "\"value\":%.1f}\n", mb_per_sec);
            } else {
                printf("JSON parse throughput: %.1f MB/s\n", mb_per_sec);
            }
        }

        /* Benchmark 2: Parse mutable containers */
        if (json_flag) {
            BENCH_JSON("json_parse_mutable", ITERATIONS, {
                @autoreleasepool {
                    id result = [NSJSONSerialization
                        JSONObjectWithData:jsonData
                                   options:NSJSONReadingMutableContainers
                                     error:NULL];
                    (void)result;
                }
            });
        } else {
            BENCH("json_parse_mutable", ITERATIONS, {
                @autoreleasepool {
                    id result = [NSJSONSerialization
                        JSONObjectWithData:jsonData
                                   options:NSJSONReadingMutableContainers
                                     error:NULL];
                    (void)result;
                }
            });
        }

        /* Benchmark 3: Serialization (write) */
        id parsed = [[NSJSONSerialization JSONObjectWithData:jsonData
                                                     options:0
                                                       error:NULL] retain];
        if (json_flag) {
            BENCH_JSON("json_serialize", ITERATIONS, {
                @autoreleasepool {
                    NSData *out = [NSJSONSerialization dataWithJSONObject:parsed
                                                                 options:0
                                                                   error:NULL];
                    (void)out;
                }
            });
        } else {
            BENCH("json_serialize", ITERATIONS, {
                @autoreleasepool {
                    NSData *out = [NSJSONSerialization dataWithJSONObject:parsed
                                                                 options:0
                                                                   error:NULL];
                    (void)out;
                }
            });
        }

        [parsed release];
        [jsonData release];
    }

    return 0;
}
