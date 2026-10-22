// Minimal AV1 bitstream handling for VideoToolbox: sequence header parsing (AV1 spec 5.5),
// 'av1C' construction (AV1 ISOBMFF binding 2.3) and temporal delimiter removal.

#include "TwilightKitC.h"

#include <string.h>

#define OBU_SEQUENCE_HEADER     1
#define OBU_TEMPORAL_DELIMITER  2

typedef struct {
    const uint8_t* data;
    size_t size;
    size_t bit;
    bool overrun;
} BitReader;

static uint32_t readBits(BitReader* r, int n) {
    uint32_t value = 0;
    for (int i = 0; i < n; i++) {
        if (r->bit >= r->size * 8) {
            r->overrun = true;
            return 0;
        }
        value = (value << 1) | ((r->data[r->bit >> 3] >> (7 - (r->bit & 7))) & 1);
        r->bit++;
    }
    return value;
}

static void skipUvlc(BitReader* r) {
    int leadingZeros = 0;
    while (!r->overrun && readBits(r, 1) == 0) {
        if (++leadingZeros >= 32) {
            r->overrun = true;
            return;
        }
    }
    if (leadingZeros > 0) {
        readBits(r, leadingZeros);
    }
}

// Reads a LEB128 value. Returns the number of bytes consumed, or 0 on error.
static size_t readLeb128(const uint8_t* p, size_t avail, uint64_t* value) {
    *value = 0;
    for (size_t i = 0; i < 8 && i < avail; i++) {
        *value |= (uint64_t)(p[i] & 0x7F) << (i * 7);
        if (!(p[i] & 0x80)) {
            return i + 1;
        }
    }
    return 0;
}

typedef struct {
    int type;
    const uint8_t* start;    // first byte of the OBU header
    size_t totalSize;        // header + size field + payload
    const uint8_t* payload;
    size_t payloadSize;
} Obu;

// Parses the OBU at p. Returns false if malformed.
static bool readObu(const uint8_t* p, size_t avail, Obu* obu) {
    if (avail < 1 || (p[0] & 0x80)) {
        return false;
    }
    size_t header = 1;
    bool hasExtension = (p[0] >> 2) & 1;
    bool hasSize = (p[0] >> 1) & 1;
    if (hasExtension) {
        header++;
    }
    if (avail < header) {
        return false;
    }

    uint64_t payloadSize;
    if (hasSize) {
        size_t lebBytes = readLeb128(p + header, avail - header, &payloadSize);
        if (lebBytes == 0) {
            return false;
        }
        header += lebBytes;
        if (payloadSize > avail - header) {
            return false;
        }
    }
    else {
        // Without a size field, the OBU runs to the end of the buffer
        payloadSize = avail - header;
    }

    obu->type = (p[0] >> 3) & 0xF;
    obu->start = p;
    obu->payload = p + header;
    obu->payloadSize = (size_t)payloadSize;
    obu->totalSize = header + (size_t)payloadSize;
    return true;
}

int TwAV1ParseSequenceHeader(const uint8_t* data, size_t len, TwAV1Info* info, uint8_t* av1c, size_t av1cCap) {
    Obu obu;
    size_t offset = 0;
    bool found = false;
    while (offset < len) {
        if (!readObu(data + offset, len - offset, &obu)) {
            return -1;
        }
        if (obu.type == OBU_SEQUENCE_HEADER) {
            found = true;
            break;
        }
        offset += obu.totalSize;
    }
    if (!found) {
        return 0;
    }

    BitReader r = { obu.payload, obu.payloadSize, 0, false };

    int seqProfile = readBits(&r, 3);
    readBits(&r, 1); // still_picture
    bool reducedStillPictureHeader = readBits(&r, 1);
    int seqLevelIdx0 = 0;
    int seqTier0 = 0;
    bool initialDisplayDelayPresentForOp0 = false;
    int initialDisplayDelayMinusOne0 = 0;

    if (reducedStillPictureHeader) {
        seqLevelIdx0 = readBits(&r, 5);
    }
    else {
        bool decoderModelInfoPresent = false;
        int bufferDelayLengthMinus1 = 0;
        if (readBits(&r, 1)) { // timing_info_present_flag
            readBits(&r, 32); // num_units_in_display_tick
            readBits(&r, 32); // time_scale
            if (readBits(&r, 1)) { // equal_picture_interval
                skipUvlc(&r);
            }
            decoderModelInfoPresent = readBits(&r, 1);
            if (decoderModelInfoPresent) {
                bufferDelayLengthMinus1 = readBits(&r, 5);
                readBits(&r, 32); // num_units_in_decoding_tick
                readBits(&r, 5);  // buffer_removal_time_length_minus_1
                readBits(&r, 5);  // frame_presentation_time_length_minus_1
            }
        }
        bool initialDisplayDelayPresent = readBits(&r, 1);
        int operatingPoints = readBits(&r, 5) + 1;
        for (int i = 0; i < operatingPoints; i++) {
            readBits(&r, 12); // operating_point_idc
            int levelIdx = readBits(&r, 5);
            int tier = levelIdx > 7 ? (int)readBits(&r, 1) : 0;
            if (decoderModelInfoPresent && readBits(&r, 1)) {
                int n = bufferDelayLengthMinus1 + 1;
                readBits(&r, n); // decoder_buffer_delay
                readBits(&r, n); // encoder_buffer_delay
                readBits(&r, 1); // low_delay_mode_flag
            }
            bool delayPresentForOp = false;
            int delayMinusOne = 0;
            if (initialDisplayDelayPresent && readBits(&r, 1)) {
                delayPresentForOp = true;
                delayMinusOne = readBits(&r, 4);
            }
            if (i == 0) {
                seqLevelIdx0 = levelIdx;
                seqTier0 = tier;
                initialDisplayDelayPresentForOp0 = delayPresentForOp;
                initialDisplayDelayMinusOne0 = delayMinusOne;
            }
        }
    }

    int frameWidthBits = readBits(&r, 4) + 1;
    int frameHeightBits = readBits(&r, 4) + 1;
    int width = readBits(&r, frameWidthBits) + 1;
    int height = readBits(&r, frameHeightBits) + 1;

    bool frameIdNumbersPresent = reducedStillPictureHeader ? false : readBits(&r, 1);
    if (frameIdNumbersPresent) {
        readBits(&r, 4); // delta_frame_id_length_minus_2
        readBits(&r, 3); // additional_frame_id_length_minus_1
    }
    readBits(&r, 1); // use_128x128_superblock
    readBits(&r, 1); // enable_filter_intra
    readBits(&r, 1); // enable_intra_edge_filter
    if (!reducedStillPictureHeader) {
        readBits(&r, 1); // enable_interintra_compound
        readBits(&r, 1); // enable_masked_compound
        readBits(&r, 1); // enable_warped_motion
        readBits(&r, 1); // enable_dual_filter
        bool enableOrderHint = readBits(&r, 1);
        if (enableOrderHint) {
            readBits(&r, 1); // enable_jnt_comp
            readBits(&r, 1); // enable_ref_frame_mvs
        }
        int seqForceScreenContentTools = 2; // SELECT_SCREEN_CONTENT_TOOLS
        if (!readBits(&r, 1)) { // seq_choose_screen_content_tools
            seqForceScreenContentTools = readBits(&r, 1);
        }
        if (seqForceScreenContentTools > 0) {
            if (!readBits(&r, 1)) { // seq_choose_integer_mv
                readBits(&r, 1); // seq_force_integer_mv
            }
        }
        if (enableOrderHint) {
            readBits(&r, 3); // order_hint_bits_minus_1
        }
    }
    readBits(&r, 1); // enable_superres
    readBits(&r, 1); // enable_cdef
    readBits(&r, 1); // enable_restoration

    // color_config()
    bool highBitdepth = readBits(&r, 1);
    bool twelveBit = false;
    if (seqProfile == 2 && highBitdepth) {
        twelveBit = readBits(&r, 1);
    }
    int bitDepth = twelveBit ? 12 : (highBitdepth ? 10 : 8);
    bool monochrome = seqProfile == 1 ? false : readBits(&r, 1);
    int colorPrimaries = 2, transfer = 2, matrix = 2; // unspecified
    if (readBits(&r, 1)) { // color_description_present_flag
        colorPrimaries = readBits(&r, 8);
        transfer = readBits(&r, 8);
        matrix = readBits(&r, 8);
    }
    bool fullRange;
    int subsamplingX, subsamplingY, chromaSamplePosition = 0;
    if (monochrome) {
        fullRange = readBits(&r, 1);
        subsamplingX = subsamplingY = 1;
    }
    else if (colorPrimaries == 1 && transfer == 13 && matrix == 0) {
        // sRGB / identity
        fullRange = true;
        subsamplingX = subsamplingY = 0;
    }
    else {
        fullRange = readBits(&r, 1);
        if (seqProfile == 0) {
            subsamplingX = subsamplingY = 1;
        }
        else if (seqProfile == 1) {
            subsamplingX = subsamplingY = 0;
        }
        else if (bitDepth == 12) {
            subsamplingX = readBits(&r, 1);
            subsamplingY = subsamplingX ? (int)readBits(&r, 1) : 0;
        }
        else {
            subsamplingX = 1;
            subsamplingY = 0;
        }
        if (subsamplingX && subsamplingY) {
            chromaSamplePosition = readBits(&r, 2);
        }
    }

    if (r.overrun) {
        return -1;
    }

    size_t av1cLength = 4 + obu.totalSize;
    if (av1cLength > av1cCap) {
        return -1;
    }
    av1c[0] = 0x81; // marker (1) + version (1)
    av1c[1] = (uint8_t)((seqProfile << 5) | (seqLevelIdx0 & 0x1F));
    av1c[2] = (uint8_t)((seqTier0 << 7) | (highBitdepth << 6) | (twelveBit << 5) | (monochrome << 4) |
                        (subsamplingX << 3) | (subsamplingY << 2) | (chromaSamplePosition & 3));
    av1c[3] = initialDisplayDelayPresentForOp0 ? (uint8_t)(0x10 | (initialDisplayDelayMinusOne0 & 0xF)) : 0;
    memcpy(av1c + 4, obu.start, obu.totalSize);

    if (info != NULL) {
        info->width = width;
        info->height = height;
        info->bitDepth = bitDepth;
        info->colorPrimaries = colorPrimaries;
        info->transferCharacteristics = transfer;
        info->matrixCoefficients = matrix;
        info->fullRange = fullRange;
    }
    return (int)av1cLength;
}

size_t TwAV1StripTemporalDelimiters(const uint8_t* data, size_t len, uint8_t* out) {
    size_t offset = 0;
    size_t written = 0;
    Obu obu;
    while (offset < len) {
        if (!readObu(data + offset, len - offset, &obu)) {
            // Malformed tail: pass it through untouched and let the decoder judge
            if (out != NULL) {
                memcpy(out + written, data + offset, len - offset);
            }
            return written + (len - offset);
        }
        if (obu.type != OBU_TEMPORAL_DELIMITER) {
            if (out != NULL) {
                memcpy(out + written, obu.start, obu.totalSize);
            }
            written += obu.totalSize;
        }
        offset += obu.totalSize;
    }
    return written;
}
