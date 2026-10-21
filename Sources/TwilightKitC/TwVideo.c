#include "TwilightKitC.h"

#include <string.h>

// Returns a pointer to the next 00 00 01 start code at or after p, or end if there is none.
static const uint8_t* twFindStartCode(const uint8_t* p, const uint8_t* end) {
    while (end - p >= 3) {
        // Find the 01, then check the two bytes before it. memchr is vectorised, so most
        // of a frame is skipped without looking at each byte in a loop.
        const uint8_t* one = memchr(p + 2, 1, (size_t)(end - (p + 2)));
        if (one == NULL) {
            return end;
        }
        if (one[-1] == 0 && one[-2] == 0) {
            return one - 2;
        }
        p = one - 1;
    }
    return end;
}

static size_t twEmit(const uint8_t* start, const uint8_t* end, uint8_t* out) {
    // Trailing zeros belong to the next (4-byte) start code. A NAL unit always ends in
    // a non-zero byte (rbsp_stop_one_bit), so this never trims real payload.
    while (end > start && end[-1] == 0) {
        end--;
    }
    size_t nalLen = (size_t)(end - start);
    if (nalLen == 0) {
        return 0;
    }
    if (out != NULL) {
        out[0] = (uint8_t)(nalLen >> 24);
        out[1] = (uint8_t)(nalLen >> 16);
        out[2] = (uint8_t)(nalLen >> 8);
        out[3] = (uint8_t)nalLen;
        memcpy(out + 4, start, nalLen);
    }
    return 4 + nalLen;
}

size_t TwAnnexBToLengthPrefixed(const uint8_t* in, size_t len, uint8_t* out) {
    const uint8_t* end = in + len;
    const uint8_t* sc = twFindStartCode(in, end);
    size_t written = 0;

    if (sc == end) {
        // No start codes: treat the whole buffer as one NAL unit
        return twEmit(in, end, out);
    }

    while (sc < end) {
        const uint8_t* nal = sc + 3;
        const uint8_t* next = twFindStartCode(nal, end);
        written += twEmit(nal, next, out ? out + written : NULL);
        sc = next;
    }
    return written;
}
