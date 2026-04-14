//
//  hdr_interleave.c
//  QLVideo
//
//  NEON-vectorizable helpers for converting planar YUV to biplanar P010.
//  Written in C so that Clang's auto-vectorizer can emit st2.8h (structure store)
//  for the interleave, which the Swift compiler does not generate.
//

#include "hdr_interleave.h"

void hdr_shift_copy(
    const uint16_t *src, uint16_t *dst,
    int width, int srcStride, int dstStride,
    int height, int shift)
{
    for (int row = 0; row < height; row++) {
        const uint16_t *s = src + row * srcStride;
        uint16_t *d = dst + row * dstStride;
        for (int x = 0; x < width; x++) {
            d[x] = s[x] << shift;
        }
    }
}

void hdr_interleave_and_shift(
    const uint16_t *srcCb, const uint16_t *srcCr,
    uint16_t *dst,
    int uvWidth, int srcCbStride, int srcCrStride, int dstStride,
    int uvHeight, int shift)
{
    for (int row = 0; row < uvHeight; row++) {
        const uint16_t *cb = srcCb + row * srcCbStride;
        const uint16_t *cr = srcCr + row * srcCrStride;
        uint16_t *d = dst + row * dstStride;
        for (int x = 0; x < uvWidth; x++) {
            d[2*x]     = cb[x] << shift;
            d[2*x + 1] = cr[x] << shift;
        }
    }
}
