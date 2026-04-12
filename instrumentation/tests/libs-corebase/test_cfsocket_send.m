/*
 * test_cfsocket_send.m - BUG-1: CFSocketSendData sends zero bytes
 *
 * The sendto() call in CFSocketSendData had swapped arguments:
 *   sendto(sock, buf, 0, len, addr, addrlen)
 * instead of:
 *   sendto(sock, buf, len, 0, addr, addrlen)
 *
 * This caused zero bytes to be sent (third arg is length, fourth is flags).
 * This test creates a UDP socket pair and verifies data actually arrives.
 */

#import <Foundation/Foundation.h>
#include <CoreFoundation/CFSocket.h>
#include <CoreFoundation/CFData.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>

#include "../../common/test_utils.h"

int main(void)
{
    @autoreleasepool {
        printf("=== test_cfsocket_send (BUG-1) ===\n");
        printf("Validates CFSocketSendData actually transmits data.\n\n");

        /* Create a UDP receiver socket (plain BSD) */
        int recvSock = socket(AF_INET, SOCK_DGRAM, 0);
        TEST_ASSERT(recvSock >= 0, "receiver socket created");

        struct sockaddr_in recvAddr;
        memset(&recvAddr, 0, sizeof(recvAddr));
        recvAddr.sin_family = AF_INET;
        recvAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        recvAddr.sin_port = 0; /* kernel picks port */

        int rc = bind(recvSock, (struct sockaddr *)&recvAddr, sizeof(recvAddr));
        TEST_ASSERT(rc == 0, "bind receiver");

        /* Get the assigned port */
        socklen_t addrLen = sizeof(recvAddr);
        getsockname(recvSock, (struct sockaddr *)&recvAddr, &addrLen);

        /* Set receive timeout so we don't block forever */
        struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
        setsockopt(recvSock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        /* Create a CFSocket for sending (UDP) */
        CFSocketContext ctx = { 0, NULL, NULL, NULL, NULL };
        CFSocketRef sender = CFSocketCreate(
            kCFAllocatorDefault,
            AF_INET, SOCK_DGRAM, IPPROTO_UDP,
            0, /* no callbacks */
            NULL,
            &ctx);
        TEST_ASSERT_NOT_NULL(sender, "CFSocket created");

        /* Build destination address as CFData */
        CFDataRef destAddr = CFDataCreate(kCFAllocatorDefault,
                                          (const UInt8 *)&recvAddr,
                                          sizeof(recvAddr));
        TEST_ASSERT_NOT_NULL(destAddr, "destination address created");

        /* Build payload */
        const char *payload = "Hello from CFSocket";
        CFDataRef data = CFDataCreate(kCFAllocatorDefault,
                                      (const UInt8 *)payload,
                                      (CFIndex)strlen(payload));
        TEST_ASSERT_NOT_NULL(data, "payload created");

        /* Send via CFSocketSendData */
        CFSocketError err = CFSocketSendData(sender, destAddr, data, 5.0);
        TEST_ASSERT_EQUAL(err, kCFSocketSuccess, "CFSocketSendData returns success");

        /* Receive on the other end */
        char buf[256];
        memset(buf, 0, sizeof(buf));
        ssize_t received = recv(recvSock, buf, sizeof(buf), 0);

        /* Before fix: received == 0 (sendto sent 0 bytes due to swapped args)
         * After fix:  received == strlen(payload) */
        TEST_ASSERT(received > 0, "received more than zero bytes");
        TEST_ASSERT_EQUAL((int)received, (int)strlen(payload),
                          "received correct number of bytes");
        TEST_ASSERT(memcmp(buf, payload, strlen(payload)) == 0,
                    "received data matches sent payload");

        /* Cleanup */
        CFRelease(data);
        CFRelease(destAddr);
        CFSocketInvalidate(sender);
        CFRelease(sender);
        close(recvSock);

        return TEST_SUMMARY();
    }
}
