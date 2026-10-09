/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * Raster encoding for Rongta-compatible ZPL and TSPL label printers.
 * 1-bit graphics, 203 dpi class devices.
 */
#ifndef RONGTA_ENCODE_H
#define RONGTA_ENCODE_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

typedef enum rt_dither {
    RT_DITHER_THRESHOLD = 0,
    RT_DITHER_FLOYD = 1,
    RT_DITHER_BAYER = 2,
    RT_DITHER_CLUSTER = 3
} rt_dither_t;

typedef enum rt_media {
    RT_MEDIA_GAP = 0,
    RT_MEDIA_CONTINUOUS = 1,
    RT_MEDIA_MARK = 2
} rt_media_t;

typedef enum rt_lang {
    RT_LANG_ZPL = 0,
    RT_LANG_TSPL = 1
} rt_lang_t;

/*
 * Defaults match a centered 4x6 label on an RP425:
 *   horizontal +20 dots (ZPL ^LH / TSPL REFERENCE)
 *   vertical   -20 dots (ZPL ^LT / TSPL OFFSET)
 * At 203 dpi, 8 dots is about 1 mm.
 */
typedef enum rt_gfa {
    RT_GFA_Z64 = 0, /* zlib + base64, the default ^GFA form */
    RT_GFA_HEX = 1  /* ASCII hex, one row per line */
} rt_gfa_t;

typedef struct rt_options {
    int darkness;     /* 0..15, sent to ZPL as ~SD (command range is 0..30) */
    int speed;        /* inches per second, 2..6 */
    int label_home_x; /* dots, may be negative */
    int label_top;    /* dots, -120..120 */
    int gap_mm;       /* gap or black-mark size, 0..10 */
    int copies;       /* 1..999 */
    int invert;       /* flip black and white */
    rt_dither_t dither;
    rt_media_t media;
    rt_gfa_t gfa;
    /*
     * Page inset in dots at 203 dpi (8 dots is about 1 mm). The full
     * raster is area-averaged into the box and the margins stay white.
     * Zero on every side is a pass-through. inset_set is 1 after any
     * rtInset* key is parsed. When it is still 0, rt_options_finish
     * applies the ZPL defaults (8, 8, 32, 0) on every page size and
     * leaves TSPL at 0. That default is the RP425 head offset
     * (1 mm, 1 mm, 4 mm, 0), including short labels.
     */
    int inset_left;
    int inset_right;
    int inset_top;
    int inset_bottom;
    int inset_set;
} rt_options_t;

void rt_options_init(rt_options_t *opt);

/* Fill ZPL inset defaults when the job did not set rtInset*. */
void rt_options_finish(rt_options_t *opt, rt_lang_t lang);

/*
 * Scale src into the inset box of a width*height buffer.
 * All-zero insets copy src to dst unchanged. Returns -1 when the box is empty.
 */
int rt_render_inset(const uint8_t *src, int width, int height, int left, int right, int top,
                    int bottom, uint8_t *dst);

/* Space-separated Key=Value list. Unknown keys are ignored.
 * Returns 0, or -1 when a known key has a value outside its range. */
int rt_options_parse(rt_options_t *opt, const char *text);
int rt_options_set(rt_options_t *opt, const char *key, const char *value);

/*
 * darkness is row-major, one byte per pixel, 0 = white, 255 = black.
 * On success *out is malloc'd packed bits (MSB = leftmost pixel) and
 * *bytes_per_row is set. Caller frees *out.
 */
int rt_pack_bits(const uint8_t *darkness, int width, int height,
                 rt_dither_t dither, int invert,
                 uint8_t **out, int *bytes_per_row);

/*
 * Convert one CUPS raster row into darkness samples.
 * color_space and color_order use the cups_cspace_t / cups_order_t values
 * (chunked = 0, W = 0, RGB = 1, K = 3, CMYK = 6, sRGB = 19, ...).
 * *err receives a static message on failure.
 */
int rt_darkness_from_row(const unsigned char *row, int width, int bytes_per_line,
                         int bits_per_color, int bits_per_pixel,
                         int color_space, int color_order,
                         uint8_t *dst, const char **err);

/* Write one label. Returns 0 on success. */
int rt_encode_zpl(const uint8_t *darkness, int width, int height,
                  const rt_options_t *opt, FILE *fp);
int rt_encode_tspl(const uint8_t *darkness, int width, int height,
                   const rt_options_t *opt, FILE *fp);

#endif
