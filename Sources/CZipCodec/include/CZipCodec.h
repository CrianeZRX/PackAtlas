#include <stdint.h>
// The callback returns nonzero to cancel; all buffers are bounded and local.
int qu_zip_extract(int input, uint64_t offset, uint64_t packed, uint64_t size,
                   uint32_t crc, int method, int output,
                   int (*check)(void *, uint64_t), void *context);
