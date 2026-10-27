#include "SMCClient.h"

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <os/lock.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <stddef.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} SMCVers;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimit;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfo;

/// Unpacked layout. On this OS AppleSMC rejects the packed 74-byte struct and
/// accepts this 80-byte one: the command byte sits at offset 42.
typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

_Static_assert(sizeof(SMCKeyData) == 80, "AppleSMC expects the 80-byte key struct");
_Static_assert(offsetof(SMCKeyData, data8) == 42, "SMC command byte must sit at offset 42");

#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9

static io_connect_t gConn = IO_OBJECT_NULL;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;

static uint32_t keycode(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8) | (uint8_t)s[3];
}

static void keystr(uint32_t key, char out[5]) {
    out[0] = (char)((key >> 24) & 0xff);
    out[1] = (char)((key >> 16) & 0xff);
    out[2] = (char)((key >> 8) & 0xff);
    out[3] = (char)(key & 0xff);
    out[4] = 0;
}

static void typestr(uint32_t type, char out[5]) {
    keystr(type, out);
}

static int call(const SMCKeyData *in, SMCKeyData *out) {
    SMCKeyData local = *in;
    size_t outSize = sizeof(*out);
    memset(out, 0, sizeof(*out));
    kern_return_t kr = IOConnectCallStructMethod(gConn, 2, &local, sizeof(local), out, &outSize);
    return kr == KERN_SUCCESS ? 0 : (int)kr;
}

int SMCOpen(void) {
    os_unfair_lock_lock(&gLock);
    int rc = 0;
    if (gConn == IO_OBJECT_NULL) {
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
        if (!service) {
            rc = -1;
        } else {
            kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &gConn);
            IOObjectRelease(service);
            if (kr != KERN_SUCCESS) {
                gConn = IO_OBJECT_NULL;
                rc = (int)kr;
            }
        }
    }
    os_unfair_lock_unlock(&gLock);
    return rc;
}

void SMCClose(void) {
    os_unfair_lock_lock(&gLock);
    if (gConn != IO_OBJECT_NULL) {
        IOServiceClose(gConn);
        gConn = IO_OBJECT_NULL;
    }
    os_unfair_lock_unlock(&gLock);
}

double SMCDecodeValue(const char *type, const uint8_t *bytes, uint32_t size, int *ok) {
    if (ok) *ok = 0;
    if (!type || !bytes || size == 0) return 0;
    if (strcmp(type, "flt ") == 0 && size >= 4) {
        float value = 0;
        memcpy(&value, bytes, 4);
        if (ok) *ok = 1;
        return value;
    }
    if ((strcmp(type, "ui8 ") == 0 || strcmp(type, "flag") == 0) && size >= 1) {
        if (ok) *ok = 1;
        return bytes[0];
    }
    if (strcmp(type, "si8 ") == 0 && size >= 1) {
        if (ok) *ok = 1;
        return (int8_t)bytes[0];
    }
    if (strcmp(type, "ui16") == 0 && size >= 2) {
        if (ok) *ok = 1;
        return ((uint32_t)bytes[0] << 8) | bytes[1];
    }
    if ((strcmp(type, "ui32") == 0 || strcmp(type, "hex_") == 0) && size >= 4) {
        if (ok) *ok = 1;
        return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3];
    }
    if (strcmp(type, "fpe2") == 0 && size >= 2) {
        if (ok) *ok = 1;
        return (((uint32_t)bytes[0] << 8) | bytes[1]) / 4.0;
    }
    if (strcmp(type, "sp78") == 0 && size >= 2) {
        int16_t raw = (int16_t)(((uint16_t)bytes[0] << 8) | bytes[1]);
        if (ok) *ok = 1;
        return raw / 256.0;
    }
    return 0;
}

static int readInfo(uint32_t key, SMCKeyData *out) {
    SMCKeyData in;
    memset(&in, 0, sizeof(in));
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (call(&in, out) != 0) return -1;
    return out->result == 0 ? 0 : (int)out->result;
}

int SMCRead(const char *key, SMCReading *out) {
    memset(out, 0, sizeof(*out));
    if (!key || strlen(key) != 4) return -1;
    if (SMCOpen() != 0) return -1;
    os_unfair_lock_lock(&gLock);
    SMCKeyData info;
    int rc = readInfo(keycode(key), &info);
    if (rc != 0) {
        os_unfair_lock_unlock(&gLock);
        return rc;
    }
    SMCKeyData in, got;
    memset(&in, 0, sizeof(in));
    in.key = keycode(key);
    in.keyInfo.dataSize = info.keyInfo.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    rc = call(&in, &got);
    os_unfair_lock_unlock(&gLock);
    if (rc != 0) return rc;
    if (got.result != 0) return (int)got.result;
    memcpy(out->key, key, 4);
    typestr(info.keyInfo.dataType, out->type);
    out->size = info.keyInfo.dataSize > 32 ? 32 : info.keyInfo.dataSize;
    memcpy(out->bytes, got.bytes, out->size);
    int decoded = 0;
    out->value = SMCDecodeValue(out->type, out->bytes, out->size, &decoded);
    out->ok = decoded;
    return 0;
}

int SMCWrite(const char *key, const uint8_t *bytes, uint32_t size) {
    if (!key || strlen(key) != 4 || !bytes) return -1;
    if (SMCOpen() != 0) return -1;
    os_unfair_lock_lock(&gLock);
    SMCKeyData info;
    int rc = readInfo(keycode(key), &info);
    if (rc != 0) {
        os_unfair_lock_unlock(&gLock);
        return rc;
    }
    uint32_t width = info.keyInfo.dataSize;
    if (width == 0 || width > 32 || width != size) {
        os_unfair_lock_unlock(&gLock);
        return -2;
    }
    SMCKeyData in, got;
    memset(&in, 0, sizeof(in));
    in.key = keycode(key);
    in.keyInfo.dataSize = width;
    in.keyInfo.dataType = info.keyInfo.dataType;
    in.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(in.bytes, bytes, width);
    rc = call(&in, &got);
    os_unfair_lock_unlock(&gLock);
    if (rc != 0) return rc;
    return got.result == 0 ? 0 : (int)got.result;
}

int SMCReadFloat(const char *key, double *out) {
    SMCReading reading;
    int rc = SMCRead(key, &reading);
    if (rc != 0 || !reading.ok) return rc == 0 ? -2 : rc;
    *out = reading.value;
    return 0;
}

int SMCWriteFloat(const char *key, double value) {
    float f = (float)value;
    uint8_t bytes[4];
    memcpy(bytes, &f, 4);
    return SMCWrite(key, bytes, 4);
}

int SMCReadUI8(const char *key, uint8_t *out) {
    SMCReading reading;
    int rc = SMCRead(key, &reading);
    if (rc != 0) return rc;
    *out = reading.bytes[0];
    return 0;
}

int SMCWriteUI8(const char *key, uint8_t value) {
    return SMCWrite(key, &value, 1);
}

int SMCCopyKeys(SMCKeyRecord *out, int capacity) {
    if (!out || capacity <= 0) return -1;
    if (SMCOpen() != 0) return -1;
    int count = 0;
    int misses = 0;
    for (uint32_t index = 0; index < 5000 && count < capacity; index++) {
        os_unfair_lock_lock(&gLock);
        SMCKeyData in, got;
        memset(&in, 0, sizeof(in));
        in.data8 = SMC_CMD_READ_INDEX;
        in.data32 = index;
        int rc = call(&in, &got);
        if (rc != 0 || got.result != 0) {
            os_unfair_lock_unlock(&gLock);
            if (++misses > 40) break;
            continue;
        }
        misses = 0;
        SMCKeyData info;
        rc = readInfo(got.key, &info);
        os_unfair_lock_unlock(&gLock);
        if (rc != 0) continue;
        keystr(got.key, out[count].key);
        typestr(info.keyInfo.dataType, out[count].type);
        count++;
    }
    return count;
}

int CopyInterfaceCounters(IFCounter *out, int capacity) {
    if (!out || capacity <= 0) return -1;
    int mib[6] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
    size_t length = 0;
    if (sysctl(mib, 6, NULL, &length, NULL, 0) != 0 || length == 0) return -1;
    uint8_t *buffer = malloc(length);
    if (!buffer) return -1;
    if (sysctl(mib, 6, buffer, &length, NULL, 0) != 0) {
        free(buffer);
        return -1;
    }
    int count = 0;
    uint8_t *cursor = buffer;
    uint8_t *end = buffer + length;
    while (cursor + 4 <= end && count < capacity) {
        struct if_msghdr *header = (struct if_msghdr *)cursor;
        if (header->ifm_msglen < 4 || cursor + header->ifm_msglen > end) break;
        if (header->ifm_type == RTM_IFINFO2 && header->ifm_msglen >= sizeof(struct if_msghdr2)) {
            struct if_msghdr2 *header2 = (struct if_msghdr2 *)cursor;
            struct sockaddr_dl *address = (struct sockaddr_dl *)(cursor + sizeof(struct if_msghdr2));
            // Tunnel interfaces have no hardware address, so the sockaddr is shorter than sizeof(sockaddr_dl).
            if ((uint8_t *)address + offsetof(struct sockaddr_dl, sdl_data) <= cursor + header->ifm_msglen) {
                unsigned nameLength = address->sdl_nlen;
                if (nameLength > 0 && nameLength < sizeof(out[count].name)
                    && (uint8_t *)address->sdl_data + nameLength <= cursor + header->ifm_msglen) {
                    memset(&out[count], 0, sizeof(out[count]));
                    memcpy(out[count].name, address->sdl_data, nameLength);
                    out[count].ibytes = header2->ifm_data.ifi_ibytes;
                    out[count].obytes = header2->ifm_data.ifi_obytes;
                    count++;
                }
            }
        }
        cursor += header->ifm_msglen;
    }
    free(buffer);
    return count;
}

typedef void *PowerSubscription;
static CFMutableDictionaryRef (*gCopyChannels)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
static PowerSubscription (*gCreateSub)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
static CFDictionaryRef (*gCreateSamples)(PowerSubscription, CFMutableDictionaryRef, CFTypeRef);
static CFDictionaryRef (*gCreateDelta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
static CFStringRef (*gChannelName)(CFDictionaryRef);
static CFStringRef (*gChannelUnit)(CFDictionaryRef);
static int64_t (*gSimpleInt)(CFDictionaryRef, int);
static int (*gIterate)(CFDictionaryRef, int (^)(CFDictionaryRef));
static PowerSubscription gPowerSub = NULL;
static CFMutableDictionaryRef gPowerChannels = NULL;
static CFDictionaryRef gPrevious = NULL;
static uint64_t gPreviousTime = 0;
static int gPowerReady = 0;

static int powerOpen(void) {
    if (gPowerReady) return gPowerSub ? 0 : -1;
    gPowerReady = 1;
    void *library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY);
    if (!library) return -1;
    gCopyChannels = dlsym(library, "IOReportCopyChannelsInGroup");
    gCreateSub = dlsym(library, "IOReportCreateSubscription");
    gCreateSamples = dlsym(library, "IOReportCreateSamples");
    gCreateDelta = dlsym(library, "IOReportCreateSamplesDelta");
    gChannelName = dlsym(library, "IOReportChannelGetChannelName");
    gChannelUnit = dlsym(library, "IOReportChannelGetUnitLabel");
    gSimpleInt = dlsym(library, "IOReportSimpleGetIntegerValue");
    gIterate = dlsym(library, "IOReportIterate");
    if (!gCopyChannels || !gCreateSub || !gCreateSamples || !gCreateDelta || !gChannelName || !gSimpleInt || !gIterate) {
        return -1;
    }
    CFMutableDictionaryRef channels = (CFMutableDictionaryRef)gCopyChannels(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!channels) return -1;
    CFMutableDictionaryRef subscribed = NULL;
    gPowerSub = gCreateSub(NULL, channels, &subscribed, 0, NULL);
    CFRelease(channels);
    gPowerChannels = subscribed;
    return gPowerSub && gPowerChannels ? 0 : -1;
}

static double wattsFromUnit(int64_t energy, const char *unit, double seconds) {
    if (seconds <= 0 || energy < 0 || !unit) return -1;
    double joules = 0;
    if (strcmp(unit, "nJ") == 0) joules = (double)energy / 1e9;
    else if (strcmp(unit, "uJ") == 0) joules = (double)energy / 1e6;
    else if (strcmp(unit, "mJ") == 0) joules = (double)energy / 1e3;
    else if (strcmp(unit, "J") == 0) joules = (double)energy;
    else return -1;
    return joules / seconds;
}

void PowerReset(void) {
    if (gPrevious) CFRelease(gPrevious);
    gPrevious = NULL;
    gPreviousTime = 0;
}

int PowerSample(PowerWatts *out) {
    if (!out) return -1;
    out->cpuWatts = -1;
    out->gpuWatts = -1;
    if (powerOpen() != 0) return -1;
    CFDictionaryRef sample = gCreateSamples(gPowerSub, gPowerChannels, NULL);
    if (!sample) return -1;
    uint64_t now = mach_continuous_time();
    if (!gPrevious) {
        gPrevious = sample;
        gPreviousTime = now;
        return 0;
    }
    mach_timebase_info_data_t scale;
    mach_timebase_info(&scale);
    double seconds = (double)(now - gPreviousTime) * (double)scale.numer / (double)scale.denom / 1e9;
    CFDictionaryRef delta = gCreateDelta(gPrevious, sample, NULL);
    CFRelease(gPrevious);
    gPrevious = sample;
    gPreviousTime = now;
    if (!delta || seconds < 0.1 || seconds > 10) {
        if (delta) CFRelease(delta);
        return 0;
    }
    __block double cpu = -1;
    __block double gpu = -1;
    gIterate(delta, ^int(CFDictionaryRef channel) {
        char name[64] = {0};
        char unit[16] = {0};
        CFStringRef nameRef = gChannelName(channel);
        CFStringRef unitRef = gChannelUnit ? gChannelUnit(channel) : NULL;
        if (!nameRef || !CFStringGetCString(nameRef, name, sizeof(name), kCFStringEncodingUTF8)) return 0;
        if (unitRef) CFStringGetCString(unitRef, unit, sizeof(unit), kCFStringEncodingUTF8);
        int64_t energy = gSimpleInt(channel, 0);
        if (strcmp(name, "CPU Energy") == 0) cpu = wattsFromUnit(energy, unit, seconds);
        else if (strcmp(name, "GPU Energy") == 0) gpu = wattsFromUnit(energy, unit, seconds);
        return 0;
    });
    CFRelease(delta);
    out->cpuWatts = cpu;
    out->gpuWatts = gpu;
    return 0;
}

static int interfaceRequest(const char *name, struct ifreq *req) {
    if (!name || !req) return -1;
    memset(req, 0, sizeof(*req));
    strlcpy(req->ifr_name, name, sizeof(req->ifr_name));
    return 0;
}

int InterfaceIsUp(const char *name, int *up) {
    struct ifreq req;
    int fd;
    if (!up || interfaceRequest(name, &req) != 0) return -1;
    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    if (ioctl(fd, SIOCGIFFLAGS, &req) < 0) {
        close(fd);
        return -1;
    }
    close(fd);
    *up = (req.ifr_flags & IFF_UP) != 0;
    return 0;
}

int InterfaceSetUp(const char *name, int up) {
    struct ifreq req;
    int fd;
    if (interfaceRequest(name, &req) != 0) return -1;
    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    if (ioctl(fd, SIOCGIFFLAGS, &req) < 0) {
        close(fd);
        return -1;
    }
    if (up) req.ifr_flags |= IFF_UP;
    else req.ifr_flags &= ~IFF_UP;
    if (ioctl(fd, SIOCSIFFLAGS, &req) < 0) {
        close(fd);
        return -1;
    }
    close(fd);
    return 0;
}
