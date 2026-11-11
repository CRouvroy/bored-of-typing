#ifndef BOARD_NATIVE_TRACKER_H
#define BOARD_NATIVE_TRACKER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BNTTracker BNTTracker;

enum BNTRejectionCode {
    BNT_REJECTION_NONE = 0,
    BNT_REJECTION_ARGUMENT = 1,
    BNT_REJECTION_UNSEEDED = 2,
    BNT_REJECTION_FEATURES = 3,
    BNT_REJECTION_MATCHES = 4,
    BNT_REJECTION_HOMOGRAPHY = 5,
    BNT_REJECTION_INLIERS = 6,
    BNT_REJECTION_COVERAGE = 7,
    BNT_REJECTION_ERROR = 8,
    BNT_REJECTION_GEOMETRY = 9,
    BNT_REJECTION_EXCEPTION = 10
};

typedef struct BNTResult {
    int32_t status; /* 1: verified current frame; 0: unavailable. */
    int32_t rejectionCode;
    int32_t inliers;
    int32_t matches;
    int32_t featureCount;
    int32_t referenceFeatureCount;
    double corners[8]; /* Normalized TOP LEFT: TL, TR, BR, BL; zero on rejection. */
    double confidence;
    double medianError; /* Symmetric transfer error, reduced-image pixels. */
    double p95Error;
    double coverage; /* Reference inlier convex hull / selected board area. */
    double analysisMilliseconds;
} BNTResult;

/* Single serial caller per handle. Input buffers are borrowed only during each call.
 * Input images use top-left rows, BGRA8; analysis is capped at a 960-pixel edge.
 * A successful seed retains only a bounded, immutable feature reference. */
BNTTracker *BNTCreate(void);
void BNTDestroy(BNTTracker *tracker);
void BNTReset(BNTTracker *tracker);

/* corners8 is ordered TL, TR, BR, BL and must be inside the seed image.
 * excludeMask is optional, top-left grayscale8: nonzero excludes a pixel.
 * maskStride must be >= width when the mask is present. */
BNTResult BNTSeed(BNTTracker *tracker, const uint8_t *bgra, int32_t width,
                  int32_t height, size_t stride, const double *corners8,
                  const uint8_t *excludeMask, size_t maskStride);
BNTResult BNTProcess(BNTTracker *tracker, const uint8_t *bgra, int32_t width,
                     int32_t height, size_t stride);

#ifdef __cplusplus
}
#endif
#endif
