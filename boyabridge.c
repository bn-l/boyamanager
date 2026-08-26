/*
 * boyabridge - take only interface 0 of the BOYA mini 2 receiver, leaving the
 * device's USB-audio interfaces attached so the mic keeps working.
 *
 * libusb's detach_kernel_driver on macOS *captures the whole device* (it
 * re-enumerates it with kUSBReEnumerateCaptureDeviceMask), which knocks the
 * receiver off the audio device list for as long as the tool holds it.
 * IOUSBLib's USBInterfaceOpenSeize is supposed to take a single interface away
 * from its driver and leave every other interface alone.
 *
 * STATUS: on macOS 26 this does NOT work for this device - the seize is
 * refused with kIOReturnExclusiveAccess (0xe00002c5) even as root, because the
 * interface is held by AppleUserHIDDevice (a DriverKit driver).  Kept because
 * the technique is correct for interfaces whose driver honours seizing; use
 * boyactl.py's default libusb transport instead.
 *
 * It speaks a trivial line protocol on stdio so boyactl.py can drive it:
 *     stdin :  "<hex>\n"        -> written to the interrupt OUT pipe
 *     stdout:  "<hex>\n"        -> a packet read from the interrupt IN pipe
 *              "# ..."          -> log/diagnostic lines
 *
 * Build:  make boyabridge      (or see the cc line in the Makefile)
 * Run:    sudo ./boyabridge
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USBSpec.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define BOYA_VID 0x2F05
#define BOYA_PID 0x003B
#define IFACE_NUMBER 0
#define PKT 64

static int prop_int(io_service_t svc, const char *key, int *out) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(svc, CFStringCreateWithCString(
            kCFAllocatorDefault, key, kCFStringEncodingUTF8),
            kCFAllocatorDefault, 0);
    if (!v) return 0;
    int ok = 0;
    if (CFGetTypeID(v) == CFNumberGetTypeID())
        ok = CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, out);
    CFRelease(v);
    return ok;
}

/* Find the IOUSBHostInterface for our vid/pid/interface-number. */
static io_service_t find_interface(void) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("IOUSBHostInterface"), &it) != KERN_SUCCESS)
        return 0;
    io_service_t svc, found = 0;
    while ((svc = IOIteratorNext(it))) {
        int vid = 0, pid = 0, num = -1;
        if (prop_int(svc, "idVendor", &vid) && prop_int(svc, "idProduct", &pid) &&
            prop_int(svc, "bInterfaceNumber", &num) &&
            vid == BOYA_VID && pid == BOYA_PID && num == IFACE_NUMBER) {
            found = svc;
            break;
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    return found;
}

static IOUSBInterfaceInterface942 **open_seized(io_service_t svc) {
    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(svc, kIOUSBInterfaceUserClientTypeID,
            kIOCFPlugInInterfaceID, &plug, &score) != KERN_SUCCESS || !plug) {
        fprintf(stderr, "# could not create plugin for interface\n");
        return NULL;
    }
    IOUSBInterfaceInterface942 **intf = NULL;
    HRESULT hr = (*plug)->QueryInterface(plug,
            CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID942), (LPVOID *)&intf);
    IODestroyPlugInInterface(plug);
    if (hr != S_OK || !intf) {
        fprintf(stderr, "# QueryInterface failed\n");
        return NULL;
    }
    IOReturn r = (*intf)->USBInterfaceOpenSeize(intf);
    if (r != kIOReturnSuccess) {
        fprintf(stderr, "# USBInterfaceOpenSeize failed: 0x%08x%s\n", r,
                r == kIOReturnNotPermitted || r == kIOReturnNoResources
                    ? " (needs root)" : "");
        (*intf)->Release(intf);
        return NULL;
    }
    return intf;
}

int main(void) {
    io_service_t svc = find_interface();
    if (!svc) {
        fprintf(stderr, "# BOYA mini 2 interface %d not found\n", IFACE_NUMBER);
        return 1;
    }
    IOUSBInterfaceInterface942 **intf = open_seized(svc);
    IOObjectRelease(svc);
    if (!intf) return 1;

    UInt8 nep = 0;
    (*intf)->GetNumEndpoints(intf, &nep);
    UInt8 pipe_in = 0, pipe_out = 0;
    for (UInt8 i = 1; i <= nep; i++) {
        UInt8 dir, num, tt, interval;
        UInt16 maxsz;
        if ((*intf)->GetPipeProperties(intf, i, &dir, &num, &tt, &maxsz,
                                       &interval) != kIOReturnSuccess)
            continue;
        if (tt != kUSBInterrupt) continue;
        if (dir == kUSBIn && !pipe_in) pipe_in = i;
        if (dir == kUSBOut && !pipe_out) pipe_out = i;
    }
    if (!pipe_in || !pipe_out) {
        fprintf(stderr, "# interrupt pipes not found (in=%d out=%d)\n",
                pipe_in, pipe_out);
        return 1;
    }
    fprintf(stderr, "# seized interface %d, pipes in=%u out=%u\n",
            IFACE_NUMBER, pipe_in, pipe_out);
    printf("# ready\n");
    fflush(stdout);

    fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK);
    char line[4096];
    size_t used = 0;

    for (;;) {
        /* drain any complete command lines from stdin */
        ssize_t n = read(STDIN_FILENO, line + used, sizeof(line) - used - 1);
        if (n > 0) {
            used += (size_t)n;
            line[used] = 0;
            char *start = line, *nl;
            while ((nl = memchr(start, '\n', used - (size_t)(start - line)))) {
                *nl = 0;
                size_t hexlen = strlen(start);
                if (hexlen >= 2 && hexlen % 2 == 0 && hexlen / 2 <= PKT) {
                    UInt8 buf[PKT];
                    for (size_t i = 0; i < hexlen / 2; i++) {
                        unsigned byte;
                        sscanf(start + i * 2, "%2x", &byte);
                        buf[i] = (UInt8)byte;
                    }
                    IOReturn w = (*intf)->WritePipeTO(intf, pipe_out, buf,
                                                      (UInt32)(hexlen / 2), 200, 400);
                    if (w != kIOReturnSuccess)
                        fprintf(stderr, "# write failed 0x%08x\n", w);
                }
                start = nl + 1;
            }
            size_t left = used - (size_t)(start - line);
            memmove(line, start, left);
            used = left;
        } else if (n == 0) {
            break;                      /* stdin closed - shut down */
        }

        /* poll the interrupt IN pipe */
        UInt8 rbuf[PKT];
        UInt32 rlen = sizeof(rbuf);
        IOReturn r = (*intf)->ReadPipeTO(intf, pipe_in, rbuf, &rlen, 40, 80);
        if (r == kIOReturnSuccess && rlen > 0) {
            for (UInt32 i = 0; i < rlen; i++) printf("%02x", rbuf[i]);
            printf("\n");
            fflush(stdout);
        } else if (r != kIOReturnSuccess && r != kIOUSBTransactionTimeout &&
                   r != kIOReturnTimeout && r != kIOReturnAborted) {
            fprintf(stderr, "# read failed 0x%08x\n", r);
            (*intf)->ClearPipeStallBothEnds(intf, pipe_in);
        }
    }

    (*intf)->USBInterfaceClose(intf);
    (*intf)->Release(intf);
    return 0;
}
