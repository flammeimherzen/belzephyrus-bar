#ifndef SMCClient_h
#define SMCClient_h

#include <stdint.h>

typedef struct {
    char key[5];
    char type[5];
    uint32_t size;
    uint8_t bytes[32];
    double value;
    int ok;
} SMCReading;

typedef struct {
    char key[5];
    char type[5];
} SMCKeyRecord;

int SMCOpen(void);
void SMCClose(void);
int SMCRead(const char *key, SMCReading *out);
int SMCWrite(const char *key, const uint8_t *bytes, uint32_t size);
int SMCReadFloat(const char *key, double *out);
int SMCWriteFloat(const char *key, double value);
int SMCReadUI8(const char *key, uint8_t *out);
int SMCWriteUI8(const char *key, uint8_t value);
int SMCCopyKeys(SMCKeyRecord *out, int capacity);
double SMCDecodeValue(const char *type, const uint8_t *bytes, uint32_t size, int *ok);

typedef struct {
    char name[16];
    uint64_t ibytes;
    uint64_t obytes;
} IFCounter;

int CopyInterfaceCounters(IFCounter *out, int capacity);

typedef struct {
    double cpuWatts;
    double gpuWatts;
} PowerWatts;

int PowerSample(PowerWatts *out);
void PowerReset(void);

int InterfaceIsUp(const char *name, int *up);
int InterfaceSetUp(const char *name, int up);

#endif
