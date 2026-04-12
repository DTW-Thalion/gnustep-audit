/*
 * test_cfsocket_addr.m - BUG-2/3: CFSocketCopyAddress / CFSocketCopyPeerAddress
 *
 * BUG-2: CFSocketCopyPeerAddress writes to s->_address (the local address
 *        field) instead of a separate peer address field, so it overwrites
 *        the local address.
 * BUG-3: addrlen is uninitialized in both CFSocketCopyAddress and
 *        CFSocketCopyPeerAddress before being passed to getsockname/getpeername,
 *        causing undefined behavior.
 *
 * This test creates a connected TCP socket pair and verifies that
 * CFSocketCopyAddress and CFSocketCopyPeerAddress return distinct addresses.
 */

#import <Foundation/Foundation.h>
#include <CoreFoundation/CFSocket.h>
#include <CoreFoundation/CFData.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>

#include "../../common/test_utils.h"

int main(void)
{
    @autoreleasepool {
        printf("=== test_cfsocket_addr (BUG-2/3) ===\n");
        printf("Validates CFSocketCopyAddress vs CFSocketCopyPeerAddress.\n\n");

        /* Create a TCP listener */
        int listenSock = socket(AF_INET, SOCK_STREAM, 0);
        TEST_ASSERT(listenSock >= 0, "listener socket created");

        int opt = 1;
        setsockopt(listenSock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

        struct sockaddr_in listenAddr;
        memset(&listenAddr, 0, sizeof(listenAddr));
        listenAddr.sin_family = AF_INET;
        listenAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        listenAddr.sin_port = 0;

        int rc = bind(listenSock, (struct sockaddr *)&listenAddr,
                      sizeof(listenAddr));
        TEST_ASSERT(rc == 0, "bind listener");

        socklen_t addrLen = sizeof(listenAddr);
        getsockname(listenSock, (struct sockaddr *)&listenAddr, &addrLen);
        listen(listenSock, 1);

        /* Create a connecting socket */
        int clientSock = socket(AF_INET, SOCK_STREAM, 0);
        TEST_ASSERT(clientSock >= 0, "client socket created");

        rc = connect(clientSock, (struct sockaddr *)&listenAddr,
                     sizeof(listenAddr));
        TEST_ASSERT(rc == 0, "client connect");

        /* Accept to complete the connection */
        struct sockaddr_in peerAddr;
        addrLen = sizeof(peerAddr);
        int serverSock = accept(listenSock, (struct sockaddr *)&peerAddr,
                                &addrLen);
        TEST_ASSERT(serverSock >= 0, "accept succeeded");

        /* Wrap the server-side socket in CFSocket */
        CFSocketContext ctx = { 0, NULL, NULL, NULL, NULL };
        CFSocketRef cfSock = CFSocketCreateWithNative(
            kCFAllocatorDefault,
            (CFSocketNativeHandle)serverSock,
            0, NULL, &ctx);
        TEST_ASSERT_NOT_NULL(cfSock, "CFSocket wrapping native socket");

        /* Get both addresses */
        CFDataRef localAddr = CFSocketCopyAddress(cfSock);
        CFDataRef remoteAddr = CFSocketCopyPeerAddress(cfSock);

        TEST_ASSERT_NOT_NULL(localAddr, "CFSocketCopyAddress returns non-NULL");
        TEST_ASSERT_NOT_NULL(remoteAddr, "CFSocketCopyPeerAddress returns non-NULL");

        if (localAddr && remoteAddr) {
            /* The local and peer addresses should have valid lengths */
            CFIndex localLen = CFDataGetLength(localAddr);
            CFIndex remoteLen = CFDataGetLength(remoteAddr);

            TEST_ASSERT(localLen >= (CFIndex)sizeof(struct sockaddr_in),
                        "local address has valid length");
            TEST_ASSERT(remoteLen >= (CFIndex)sizeof(struct sockaddr_in),
                        "remote address has valid length");

            /* Extract ports - they should differ (local = listen port,
             * peer = client ephemeral port).
             * BUG-2: both would be the same because peer overwrites _address. */
            const struct sockaddr_in *localSA =
                (const struct sockaddr_in *)CFDataGetBytePtr(localAddr);
            const struct sockaddr_in *remoteSA =
                (const struct sockaddr_in *)CFDataGetBytePtr(remoteAddr);

            uint16_t localPort = ntohs(localSA->sin_port);
            uint16_t remotePort = ntohs(remoteSA->sin_port);

            printf("  Local port:  %u\n", localPort);
            printf("  Remote port: %u\n", remotePort);

            TEST_ASSERT(localPort != 0,
                        "local port is non-zero (addrlen was initialized)");
            TEST_ASSERT(remotePort != 0,
                        "remote port is non-zero (addrlen was initialized)");
            TEST_ASSERT(localPort != remotePort,
                        "local and peer ports differ (peer not overwriting address)");
        }

        /* Cleanup */
        if (localAddr) CFRelease(localAddr);
        if (remoteAddr) CFRelease(remoteAddr);
        CFSocketInvalidate(cfSock);
        CFRelease(cfSock);
        close(clientSock);
        close(listenSock);

        return TEST_SUMMARY();
    }
}
