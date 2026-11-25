#include "CZipCodec.h"
#include <zlib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#define BUFFER_SIZE (256 * 1024)

static int write_all(int fd, const unsigned char *data, size_t count) {
    while (count) {
        ssize_t n = write(fd, data, count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 1;
        data += n; count -= (size_t)n;
    }
    return 0;
}
int qu_zip_extract(int input, uint64_t offset, uint64_t packed, uint64_t size,
                   uint32_t expected_crc, int method, int output,
                   int (*check)(void *, uint64_t), void *context) {
    unsigned char *in = malloc(BUFFER_SIZE), *out = malloc(BUFFER_SIZE);
    if (!in || !out) { free(in); free(out); return 1; }
    z_stream stream; memset(&stream, 0, sizeof(stream));
    int initialized = 0, code = 0, ended = method == 0;
    uint64_t remaining = packed, produced = 0;
    uLong crc = crc32(0, Z_NULL, 0);
    if (method == 8) {
        if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) { code = 2; goto finish; }
        initialized = 1;
    } else if (method != 0) { code = 2; goto finish; }
    if (check(context, 0)) { code = 4; goto finish; }
    while (remaining || (method == 8 && stream.avail_in)) {
        if (!stream.avail_in) {
            size_t count = remaining > BUFFER_SIZE ? BUFFER_SIZE : (size_t)remaining;
            ssize_t n = pread(input, in, count, (off_t)offset);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { code = 1; goto finish; }
            offset += (uint64_t)n; remaining -= (uint64_t)n;
            stream.next_in = in; stream.avail_in = (uInt)n;
        }
        size_t count;
        const unsigned char *data;
        if (method == 0) { count = stream.avail_in; data = in; stream.avail_in = 0; }
        else {
            stream.next_out = out; stream.avail_out = BUFFER_SIZE;
            int status = inflate(&stream, Z_NO_FLUSH);
            if (status != Z_OK && status != Z_STREAM_END) { code = 2; goto finish; }
            count = BUFFER_SIZE - stream.avail_out; data = out;
            if (status == Z_STREAM_END) ended = 1;
        }
        if (produced > size || count > size - produced) { code = 5; goto finish; }
        if (write_all(output, data, count)) { code = 1; goto finish; }
        crc = crc32(crc, data, (uInt)count); produced += count;
        if (check(context, produced)) { code = 4; goto finish; }
        if (method == 8 && ended) break;
    }
    // A deflate stream may need one final zero-input call when its output
    // buffer was filled exactly on the final input byte.
    if (method == 8 && !ended) {
        stream.next_out = out; stream.avail_out = BUFFER_SIZE;
        int status = inflate(&stream, Z_FINISH);
        size_t count = BUFFER_SIZE - stream.avail_out;
        if (status != Z_STREAM_END || produced > size || count > size - produced) { code = 2; goto finish; }
        if (write_all(output, out, count)) { code = 1; goto finish; }
        crc = crc32(crc, out, (uInt)count); produced += count; ended = 1;
        if (check(context, produced)) { code = 4; goto finish; }
    }
    if (!ended || remaining || stream.avail_in || produced != size) code = 5;
    else if ((uint32_t)crc != expected_crc) code = 3;
finish:
    if (initialized) inflateEnd(&stream);
    free(in); free(out);
    return code;
}
