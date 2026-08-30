// libsmc.h - public interface for libsmc.c

#ifndef QLIMIT_LIBSMC_H
#define QLIMIT_LIBSMC_H

#include <IOKit/IOKitLib.h>

// Open the SMC connection once before any read/write calls.
IOReturn smc_open(void);

// Write `size` bytes to SMC key `key` (e.g. 'CH0I').
IOReturn smc_write_safe(uint32_t key, void *bytes, uint32_t size);

// Read into `bytes`, `*size` in as buffer capacity, out as actual data size.
IOReturn smc_read_safe(uint32_t key, void *bytes, int32_t *size);

// Convenience: read exactly `size` bytes.
IOReturn smc_read_n(uint32_t key, void *bytes, int32_t size);

#endif
