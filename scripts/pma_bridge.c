#include <unistd.h>
#include <lhasa.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <compression.h>
#include <stdio.h>
#include <zlib.h>

typedef struct {
    LHAInputStream *input;
    LHAReader *reader;
} PMReader;

PMReader *pm_open(const char *name) {
    PMReader *p = calloc(1, sizeof(PMReader));
    if (!p) return NULL;
    p->input = lha_input_stream_from((char *)name);
    if (p->input) p->reader = lha_reader_new(p->input);
    if (!p->reader) {
        if (p->input) lha_input_stream_free(p->input);
        free(p);
        return NULL;
    }
    lha_reader_set_dir_policy(p->reader, LHA_READER_DIR_PLAIN);
    return p;
}
int pm_next(PMReader *p, const char **folder, const char **file,
            uint64_t *length, uint16_t *crc) {
    LHAFileHeader *h = lha_reader_next_file(p->reader);
    if (!h) return 0;
    if (h->symlink_target) return -1;
    *file = h->filename ? h->filename : "";
    *folder = h->path ? h->path : "";
    *length = h->length;
    *crc = h->crc;
    return strcmp(h->compress_method, "-lhd-") == 0 ? 2 : 1;
}
size_t pm_read(PMReader *p, char *buf, size_t n) {
    return lha_reader_read(p->reader, buf, n);
}
void pm_close(PMReader *p) {
    lha_reader_free(p->reader);
    lha_input_stream_free(p->input);
    free(p);
}

// Feed a Brotli or LZFSE stream to the system decoder, using bounded buffers.
int apple_stream(const char *source, int output, int algorithm, uint64_t *total) {
    FILE *in = fopen(source, "rb");
    if (!in) return -1;
    compression_stream s = {0};
    if (compression_stream_init(&s, COMPRESSION_STREAM_DECODE, algorithm) != COMPRESSION_STATUS_OK) {
        fclose(in); return -1;
    }
    uint8_t src[65536], dst[65536];
    int status = -1;
    while (1) {
        if (!s.src_size && !feof(in)) {
            s.src_size = fread(src, 1, sizeof(src), in);
            if (ferror(in)) break;
            s.src_ptr = src;
        }
        s.dst_ptr = dst; s.dst_size = sizeof(dst);
        size_t before = s.src_size;
        compression_status step = compression_stream_process(&s, feof(in) ? COMPRESSION_STREAM_FINALIZE : 0);
        size_t n = sizeof(dst) - s.dst_size;
        if (step == COMPRESSION_STATUS_ERROR) break;
        if (output >= 0) {
            size_t used=0;
            while (used<n) {
                ssize_t wrote=write(output,dst+used,n-used);
                if (wrote<=0) goto done;
                used+=(size_t)wrote;
            }
        }
        *total += n;
        if (step == COMPRESSION_STATUS_END) {
            if (!s.src_size && fgetc(in)==EOF && !ferror(in)) status=0;
            break;
        }
        if (!n && before==s.src_size) break;
    }
done:
    compression_stream_destroy(&s); fclose(in); return status;
}
