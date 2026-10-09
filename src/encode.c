/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "encode.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

/* 8x8 Bayer matrix, 0..63. Threshold uses darkness/255 > entry/64. */
static const uint8_t k_bayer8[8][8] = {
    {0, 32, 8, 40, 2, 34, 10, 42},
    {48, 16, 56, 24, 50, 18, 58, 26},
    {12, 44, 4, 36, 14, 46, 6, 38},
    {60, 28, 52, 20, 62, 30, 54, 22},
    {3, 35, 11, 43, 1, 33, 9, 41},
    {51, 19, 59, 27, 49, 17, 57, 25},
    {15, 47, 7, 39, 13, 45, 5, 37},
    {63, 31, 55, 23, 61, 29, 53, 21},
};

/* Clustered dot, center of the tile turns black first. */
static const uint8_t k_cluster8[8][8] = {
    {42, 43, 44, 45, 46, 47, 48, 49},
    {41, 20, 21, 22, 23, 24, 25, 50},
    {40, 19, 6, 7, 8, 9, 26, 51},
    {39, 18, 5, 0, 1, 10, 27, 52},
    {38, 17, 4, 3, 2, 11, 28, 53},
    {37, 16, 15, 14, 13, 12, 29, 54},
    {36, 35, 34, 33, 32, 31, 30, 55},
    {63, 62, 61, 60, 59, 58, 57, 56},
};

static const char k_hex[] = "0123456789ABCDEF";

void rt_options_init(rt_options_t *opt) {
    opt->darkness = 7;
    opt->speed = 5;
    opt->label_home_x = 20;
    opt->label_top = -20;
    opt->gap_mm = 2;
    opt->copies = 1;
    opt->invert = 0;
    opt->dither = RT_DITHER_THRESHOLD;
    opt->media = RT_MEDIA_GAP;
    opt->gfa = RT_GFA_Z64;
    opt->inset_left = 0;
    opt->inset_right = 0;
    opt->inset_top = 0;
    opt->inset_bottom = 0;
    opt->inset_set = 0;
}

void rt_options_finish(rt_options_t *opt, rt_lang_t lang) {
    if (opt == NULL || opt->inset_set) {
        return;
    }
    if (lang == RT_LANG_ZPL) {
        /*
         * RP425 print-head offset on every ZPL page, not only 4x6:
         * 1 mm left, 1 mm right, 4 mm top (sensor-to-head gap), bottom flush.
         * A 2x1 label is 406x203 dots, so 8+8 and 32 still leave a printable box.
         */
        opt->inset_left = 8;
        opt->inset_right = 8;
        opt->inset_top = 32;
        opt->inset_bottom = 0;
    }
}

static int eq_ci(const char *a, const char *b) {
    while (*a != '\0' && *b != '\0') {
        unsigned char ca = (unsigned char)*a;
        unsigned char cb = (unsigned char)*b;
        if (tolower(ca) != tolower(cb)) {
            return 0;
        }
        a++;
        b++;
    }
    return *a == *b;
}

static int parse_int(const char *value, int *out) {
    char *end = NULL;
    long v;

    if (value == NULL || value[0] == '\0') {
        return -1;
    }
    v = strtol(value, &end, 10);
    if (end == value || *end != '\0') {
        return -1;
    }
    if (v > 1000000 || v < -1000000) {
        return -1;
    }
    *out = (int)v;
    return 0;
}

int rt_options_set(rt_options_t *opt, const char *key, const char *value) {
    int n = 0;

    if (key == NULL || value == NULL) {
        return -1;
    }
    if (eq_ci(key, "Darkness")) {
        if (parse_int(value, &n) != 0 || n < 0 || n > 15) {
            return -1;
        }
        opt->darkness = n;
        return 0;
    }
    if (eq_ci(key, "PrintSpeed")) {
        if (parse_int(value, &n) != 0 || n < 2 || n > 6) {
            return -1;
        }
        opt->speed = n;
        return 0;
    }
    if (eq_ci(key, "rtLabelHomeX")) {
        if (parse_int(value, &n) != 0 || n < -800 || n > 800) {
            return -1;
        }
        opt->label_home_x = n;
        return 0;
    }
    if (eq_ci(key, "rtLabelTop")) {
        if (parse_int(value, &n) != 0 || n < -120 || n > 120) {
            return -1;
        }
        opt->label_top = n;
        return 0;
    }
    if (eq_ci(key, "rtGapMm")) {
        if (parse_int(value, &n) != 0 || n < 0 || n > 10) {
            return -1;
        }
        opt->gap_mm = n;
        return 0;
    }
    if (eq_ci(key, "copies")) {
        if (parse_int(value, &n) != 0 || n < 1 || n > 999) {
            return -1;
        }
        opt->copies = n;
        return 0;
    }
    if (eq_ci(key, "MediaType")) {
        if (eq_ci(value, "Gap")) {
            opt->media = RT_MEDIA_GAP;
        } else if (eq_ci(value, "Continuous")) {
            opt->media = RT_MEDIA_CONTINUOUS;
        } else if (eq_ci(value, "BlackMark")) {
            opt->media = RT_MEDIA_MARK;
        } else {
            return -1;
        }
        return 0;
    }
    if (eq_ci(key, "rtDither")) {
        if (eq_ci(value, "Threshold")) {
            opt->dither = RT_DITHER_THRESHOLD;
        } else if (eq_ci(value, "FloydSteinberg")) {
            opt->dither = RT_DITHER_FLOYD;
        } else if (eq_ci(value, "Bayer")) {
            opt->dither = RT_DITHER_BAYER;
        } else if (eq_ci(value, "Clustered")) {
            opt->dither = RT_DITHER_CLUSTER;
        } else {
            return -1;
        }
        return 0;
    }
    if (eq_ci(key, "rtGfa")) {
        if (eq_ci(value, "Z64")) {
            opt->gfa = RT_GFA_Z64;
        } else if (eq_ci(value, "Hex") || eq_ci(value, "ASCII")) {
            opt->gfa = RT_GFA_HEX;
        } else {
            return -1;
        }
        return 0;
    }
    if (eq_ci(key, "rtInsetLeft") || eq_ci(key, "rtInsetRight") || eq_ci(key, "rtInsetTop") ||
        eq_ci(key, "rtInsetBottom")) {
        if (parse_int(value, &n) != 0 || n < 0 || n > 800) {
            return -1;
        }
        if (eq_ci(key, "rtInsetLeft")) {
            opt->inset_left = n;
        } else if (eq_ci(key, "rtInsetRight")) {
            opt->inset_right = n;
        } else if (eq_ci(key, "rtInsetTop")) {
            opt->inset_top = n;
        } else {
            opt->inset_bottom = n;
        }
        opt->inset_set = 1;
        return 0;
    }
    if (eq_ci(key, "rtInvert")) {
        if (eq_ci(value, "True") || eq_ci(value, "On") || eq_ci(value, "Yes") ||
            eq_ci(value, "1")) {
            opt->invert = 1;
        } else if (eq_ci(value, "False") || eq_ci(value, "Off") || eq_ci(value, "No") ||
                   eq_ci(value, "0")) {
            opt->invert = 0;
        } else {
            return -1;
        }
        return 0;
    }
    return 0;
}

int rt_options_parse(rt_options_t *opt, const char *text) {
    const char *p;

    if (text == NULL) {
        return 0;
    }
    p = text;
    while (*p != '\0') {
        const char *key_start;
        char key[64];
        char value[128];
        size_t klen;
        size_t vi;

        while (*p == ' ' || *p == '\t') {
            p++;
        }
        if (*p == '\0') {
            break;
        }
        key_start = p;
        while (*p != '\0' && *p != '=' && *p != ' ' && *p != '\t') {
            p++;
        }
        if (*p != '=') {
            while (*p != '\0' && *p != ' ' && *p != '\t') {
                p++;
            }
            continue;
        }
        klen = (size_t)(p - key_start);
        if (klen >= sizeof key) {
            klen = sizeof key - 1;
        }
        memcpy(key, key_start, klen);
        key[klen] = '\0';
        p++;
        vi = 0;
        if (*p == '"') {
            p++;
            while (*p != '\0' && *p != '"' && vi + 1 < sizeof value) {
                value[vi++] = *p++;
            }
            if (*p == '"') {
                p++;
            }
        } else {
            while (*p != '\0' && *p != ' ' && *p != '\t' && vi + 1 < sizeof value) {
                value[vi++] = *p++;
            }
        }
        value[vi] = '\0';
        if (rt_options_set(opt, key, value) != 0) {
            return -1;
        }
    }
    return 0;
}

static int clamp8(int v) {
    if (v < 0) {
        return 0;
    }
    if (v > 255) {
        return 255;
    }
    return v;
}

static int screen_black(int darkness, int x, int y, const uint8_t screen[8][8]) {
    return darkness * 64 > (int)screen[y & 7][x & 7] * 255;
}

static void set_bit(uint8_t *bits, int bpr, int x, int y, int black) {
    if (black) {
        bits[(size_t)y * (size_t)bpr + (size_t)(x >> 3)] |=
            (uint8_t)(0x80u >> (x & 7));
    }
}

static int floyd_pack(const uint8_t *darkness, int width, int height, int invert,
                      uint8_t *bits, int bpr) {
    int *px;
    int y;
    size_t count = (size_t)width * (size_t)height;

    px = malloc(count * sizeof(int));
    if (px == NULL) {
        return -1;
    }
    for (size_t i = 0; i < count; i++) {
        px[i] = darkness[i];
    }
    for (y = 0; y < height; y++) {
        int x;
        for (x = 0; x < width; x++) {
            int v = clamp8(px[(size_t)y * (size_t)width + (size_t)x]);
            int black = v >= 128;
            int quant = black ? 255 : 0;
            int err = v - quant;
            if (invert) {
                black = !black;
            }
            set_bit(bits, bpr, x, y, black);
            if (x + 1 < width) {
                px[(size_t)y * (size_t)width + (size_t)(x + 1)] += err * 7 / 16;
            }
            if (y + 1 < height && x > 0) {
                px[(size_t)(y + 1) * (size_t)width + (size_t)(x - 1)] += err * 3 / 16;
            }
            if (y + 1 < height) {
                px[(size_t)(y + 1) * (size_t)width + (size_t)x] += err * 5 / 16;
            }
            if (y + 1 < height && x + 1 < width) {
                px[(size_t)(y + 1) * (size_t)width + (size_t)(x + 1)] += err * 1 / 16;
            }
        }
    }
    free(px);
    return 0;
}

int rt_pack_bits(const uint8_t *darkness, int width, int height, rt_dither_t dither,
                 int invert, uint8_t **out, int *bytes_per_row) {
    int bpr;
    uint8_t *bits;

    if (darkness == NULL || out == NULL || bytes_per_row == NULL || width <= 0 ||
        height <= 0 || width > 20000 || height > 40000) {
        return -1;
    }
    if ((size_t)width > (SIZE_MAX / (size_t)height)) {
        return -1;
    }
    bpr = (width + 7) / 8;
    if ((size_t)bpr > (SIZE_MAX / (size_t)height)) {
        return -1;
    }
    bits = calloc((size_t)bpr * (size_t)height, 1);
    if (bits == NULL) {
        return -1;
    }
    if (dither == RT_DITHER_FLOYD) {
        if (floyd_pack(darkness, width, height, invert, bits, bpr) != 0) {
            free(bits);
            return -1;
        }
    } else {
        int y;
        for (y = 0; y < height; y++) {
            int x;
            for (x = 0; x < width; x++) {
                int sample = darkness[(size_t)y * (size_t)width + (size_t)x];
                int black = 0;
                switch (dither) {
                case RT_DITHER_THRESHOLD:
                    black = sample >= 128;
                    break;
                case RT_DITHER_BAYER:
                    black = screen_black(sample, x, y, k_bayer8);
                    break;
                case RT_DITHER_CLUSTER:
                    black = screen_black(sample, x, y, k_cluster8);
                    break;
                case RT_DITHER_FLOYD:
                    black = sample >= 128;
                    break;
                default:
                    black = sample >= 128;
                    break;
                }
                if (invert) {
                    black = !black;
                }
                set_bit(bits, bpr, x, y, black);
            }
        }
    }
    *out = bits;
    *bytes_per_row = bpr;
    return 0;
}

static int luma(int r, int g, int b) {
    int y = (r * 299 + g * 587 + b * 114) / 1000;
    return clamp8(y);
}

int rt_darkness_from_row(const unsigned char *row, int width, int bytes_per_line,
                         int bits_per_color, int bits_per_pixel, int color_space,
                         int color_order, uint8_t *dst, const char **err) {
    int x;
    int bpp;

    if (err != NULL) {
        *err = NULL;
    }
    if (row == NULL || dst == NULL || width <= 0 || bytes_per_line < 0) {
        if (err != NULL) {
            *err = "empty raster row";
        }
        return -1;
    }
    /* cups_order_t: chunked is 0. Banded and planar are not produced by our PPDs. */
    if (color_order != 0) {
        if (err != NULL) {
            *err = "only chunked raster color order is supported";
        }
        return -1;
    }
    if (bits_per_color != 1 && bits_per_color != 8) {
        if (err != NULL) {
            *err = "only 1-bit and 8-bit raster are supported";
        }
        return -1;
    }

    if (bits_per_color == 1 || bits_per_pixel == 1) {
        if (bytes_per_line < (width + 7) / 8) {
            if (err != NULL) {
                *err = "raster row is shorter than the page width";
            }
            return -1;
        }
        for (x = 0; x < width; x++) {
            int bit = (row[x >> 3] >> (7 - (x & 7))) & 1;
            /* K (3) and white-ink (12): a set bit is ink. W (0) and SW (18): 0 is black. */
            if (color_space == 0 || color_space == 18) {
                dst[x] = bit ? 0 : 255;
            } else {
                dst[x] = bit ? 255 : 0;
            }
        }
        return 0;
    }

    bpp = bits_per_pixel / 8;
    if (bpp < 1) {
        if (err != NULL) {
            *err = "unsupported pixel width";
        }
        return -1;
    }
    if (bytes_per_line < width * bpp) {
        if (err != NULL) {
            *err = "raster row is shorter than the page width";
        }
        return -1;
    }

    for (x = 0; x < width; x++) {
        const unsigned char *p = row + (size_t)x * (size_t)bpp;
        switch (color_space) {
        case 3:  /* K */
        case 12: /* WHITE ink, treated as coverage */
            dst[x] = p[0];
            break;
        case 0:  /* W */
        case 18: /* SW */
            dst[x] = (uint8_t)(255 - p[0]);
            break;
        case 1:  /* RGB */
        case 19: /* sRGB */
        case 20: /* Adobe RGB */
            if (bpp < 3) {
                if (err != NULL) {
                    *err = "RGB raster row is too narrow";
                }
                return -1;
            }
            dst[x] = (uint8_t)(255 - luma(p[0], p[1], p[2]));
            break;
        case 2: /* RGBA */
        case 17: /* RGBW, alpha/white ignored */
            if (bpp < 3) {
                if (err != NULL) {
                    *err = "RGBA raster row is too narrow";
                }
                return -1;
            }
            dst[x] = (uint8_t)(255 - luma(p[0], p[1], p[2]));
            break;
        case 6: /* CMYK */
        case 7: /* YMCK */
        case 8: /* KCMY */
            if (bpp < 4) {
                if (err != NULL) {
                    *err = "CMYK raster row is too narrow";
                }
                return -1;
            }
            {
                int c = p[0];
                int m = p[1];
                int yv = p[2];
                int k = p[3];
                int cmy;
                int dark;
                if (color_space == 8) {
                    k = p[0];
                    c = p[1];
                    m = p[2];
                    yv = p[3];
                } else if (color_space == 7) {
                    yv = p[0];
                    m = p[1];
                    c = p[2];
                    k = p[3];
                }
                cmy = (c + m + yv) / 3;
                dark = k + (cmy * (255 - k)) / 255;
                dst[x] = (uint8_t)clamp8(dark);
            }
            break;
        default:
            if (err != NULL) {
                *err = "unsupported raster color space";
            }
            return -1;
        }
    }
    return 0;
}

static int prepare(const uint8_t *darkness, int width, int height, const rt_options_t *opt,
                   uint8_t **bits, int *bpr, rt_options_t *local) {
    if (opt == NULL) {
        return -1;
    }
    *local = *opt;
    if (local->copies < 1) {
        local->copies = 1;
    }
    if (local->copies > 999) {
        local->copies = 999;
    }
    if (local->speed < 2) {
        local->speed = 2;
    }
    if (local->speed > 6) {
        local->speed = 6;
    }
    if (local->darkness < 0) {
        local->darkness = 0;
    }
    if (local->darkness > 15) {
        local->darkness = 15;
    }
    if (local->label_top < -120) {
        local->label_top = -120;
    }
    if (local->label_top > 120) {
        local->label_top = 120;
    }
    if (local->gap_mm < 0) {
        local->gap_mm = 0;
    }
    if (local->inset_left < 0) {
        local->inset_left = 0;
    }
    if (local->inset_right < 0) {
        local->inset_right = 0;
    }
    if (local->inset_top < 0) {
        local->inset_top = 0;
    }
    if (local->inset_bottom < 0) {
        local->inset_bottom = 0;
    }
    if (local->inset_left != 0 || local->inset_right != 0 || local->inset_top != 0 ||
        local->inset_bottom != 0) {
        uint8_t *scaled;
        int rc;

        if (local->inset_left + local->inset_right >= width ||
            local->inset_top + local->inset_bottom >= height) {
            fprintf(stderr, "ERROR: page inset is larger than the %dx%d raster\n", width, height);
            return -1;
        }
        scaled = malloc((size_t)width * (size_t)height);
        if (scaled == NULL) {
            return -1;
        }
        if (rt_render_inset(darkness, width, height, local->inset_left, local->inset_right,
                            local->inset_top, local->inset_bottom, scaled) != 0) {
            free(scaled);
            return -1;
        }
        rc = rt_pack_bits(scaled, width, height, local->dither, local->invert, bits, bpr);
        free(scaled);
        return rc;
    }
    return rt_pack_bits(darkness, width, height, local->dither, local->invert, bits, bpr);
}

static int64_t i64_min(int64_t a, int64_t b) {
    return a < b ? a : b;
}

static int64_t i64_max(int64_t a, int64_t b) {
    return a > b ? a : b;
}

int rt_render_inset(const uint8_t *src, int width, int height, int left, int right, int top,
                    int bottom, uint8_t *dst) {
    int dest_w;
    int dest_h;
    int j;

    if (src == NULL || dst == NULL || width <= 0 || height <= 0) {
        return -1;
    }
    if (left < 0 || right < 0 || top < 0 || bottom < 0) {
        return -1;
    }
    if (left == 0 && right == 0 && top == 0 && bottom == 0) {
        memcpy(dst, src, (size_t)width * (size_t)height);
        return 0;
    }
    if (left + right >= width || top + bottom >= height) {
        return -1;
    }
    dest_w = width - left - right;
    dest_h = height - top - bottom;
    memset(dst, 0, (size_t)width * (size_t)height);
    for (j = 0; j < dest_h; j++) {
        int64_t y0 = (int64_t)j * height;
        int64_t y1 = (int64_t)(j + 1) * height;
        int iy0 = (int)(y0 / dest_h);
        int iy1 = (int)((y1 - 1) / dest_h);
        int i;

        for (i = 0; i < dest_w; i++) {
            int64_t x0 = (int64_t)i * width;
            int64_t x1 = (int64_t)(i + 1) * width;
            int ix0 = (int)(x0 / dest_w);
            int ix1 = (int)((x1 - 1) / dest_w);
            uint64_t acc = 0;
            uint64_t area = 0;
            int y;

            for (y = iy0; y <= iy1; y++) {
                int64_t y_over = i64_min((int64_t)(y + 1) * dest_h, y1) - i64_max((int64_t)y * dest_h, y0);
                int x;

                if (y_over <= 0) {
                    continue;
                }
                for (x = ix0; x <= ix1; x++) {
                    int64_t x_over =
                        i64_min((int64_t)(x + 1) * dest_w, x1) - i64_max((int64_t)x * dest_w, x0);
                    uint64_t weight;

                    if (x_over <= 0) {
                        continue;
                    }
                    weight = (uint64_t)x_over * (uint64_t)y_over;
                    acc += weight * src[(size_t)y * (size_t)width + (size_t)x];
                    area += weight;
                }
            }
            if (area > 0) {
                dst[(size_t)(top + j) * (size_t)width + (size_t)(left + i)] =
                    (uint8_t)((acc + area / 2) / area);
            }
        }
    }
    return 0;
}

/* CRC-16/CCITT, XMODEM: poly 0x1021, init 0, no reflection, no final xor. */
static uint16_t crc16_xmodem(const uint8_t *data, size_t len) {
    uint16_t crc = 0;
    size_t i;

    for (i = 0; i < len; i++) {
        int bit;
        crc ^= (uint16_t)data[i] << 8;
        for (bit = 0; bit < 8; bit++) {
            if (crc & 0x8000) {
                crc = (uint16_t)((crc << 1) ^ 0x1021);
            } else {
                crc <<= 1;
            }
        }
    }
    return crc;
}

static char *b64_encode(const uint8_t *data, size_t len, size_t *out_len) {
    static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t olen = 4 * ((len + 2) / 3);
    char *out;
    size_t i;
    size_t o = 0;

    out = malloc(olen + 1);
    if (out == NULL) {
        return NULL;
    }
    for (i = 0; i < len; i += 3) {
        unsigned int n = (unsigned int)data[i] << 16;
        int remain = 1;
        if (i + 1 < len) {
            n |= (unsigned int)data[i + 1] << 8;
            remain = 2;
        }
        if (i + 2 < len) {
            n |= data[i + 2];
            remain = 3;
        }
        out[o++] = tbl[(n >> 18) & 63];
        out[o++] = tbl[(n >> 12) & 63];
        out[o++] = remain >= 2 ? tbl[(n >> 6) & 63] : '=';
        out[o++] = remain == 3 ? tbl[n & 63] : '=';
    }
    out[o] = '\0';
    *out_len = o;
    return out;
}

static int write_gfa_z64(FILE *fp, const uint8_t *bits, int total, int bpr) {
    uLongf bound;
    uLongf clen;
    uint8_t *comp;
    char *b64;
    size_t b64_len = 0;
    uint16_t crc;
    int rc;

    if (total < 0) {
        return -1;
    }
    bound = compressBound((uLong)total);
    comp = malloc(bound);
    if (comp == NULL) {
        return -1;
    }
    clen = bound;
    if (compress2(comp, &clen, bits, (uLong)total, Z_BEST_COMPRESSION) != Z_OK) {
        free(comp);
        return -1;
    }
    b64 = b64_encode(comp, (size_t)clen, &b64_len);
    free(comp);
    if (b64 == NULL) {
        return -1;
    }
    crc = crc16_xmodem((const uint8_t *)b64, b64_len);
    rc = fprintf(fp, "^GFA,%d,%d,%d,:Z64:%s:%04X\r\n", total, total, bpr, b64, crc);
    free(b64);
    return rc < 0 ? -1 : 0;
}

static int write_gfa_hex(FILE *fp, const uint8_t *bits, int total, int bpr, int height) {
    int y;

    if (fprintf(fp, "^GFA,%d,%d,%d,\r\n", total, total, bpr) < 0) {
        return -1;
    }
    for (y = 0; y < height; y++) {
        const uint8_t *row = bits + (size_t)y * (size_t)bpr;
        int i;
        for (i = 0; i < bpr; i++) {
            if (fputc(k_hex[row[i] >> 4], fp) == EOF || fputc(k_hex[row[i] & 0x0f], fp) == EOF) {
                return -1;
            }
        }
        if (fputs("\r\n", fp) == EOF) {
            return -1;
        }
    }
    return 0;
}

int rt_encode_zpl(const uint8_t *darkness, int width, int height, const rt_options_t *opt,
                  FILE *fp) {
    rt_options_t local;
    uint8_t *bits = NULL;
    int bpr = 0;
    int total;
    const char *mn = "W";

    if (fp == NULL || prepare(darkness, width, height, opt, &bits, &bpr, &local) != 0) {
        return -1;
    }
    total = bpr * height;
    switch (local.media) {
    case RT_MEDIA_GAP:
        mn = "W";
        break;
    case RT_MEDIA_CONTINUOUS:
        mn = "N";
        break;
    case RT_MEDIA_MARK:
        mn = "M";
        break;
    default: {
        rt_media_t unexpected = local.media;
        (void)unexpected;
        mn = "W";
        break;
    }
    }

    if (fprintf(fp, "^XA\r\n^MN%s\r\n^LT%d\r\n", mn, local.label_top) < 0) {
        free(bits);
        return -1;
    }
    if (local.label_home_x >= 0) {
        if (fprintf(fp, "^LH%d,0\r\n^LS0\r\n", local.label_home_x) < 0) {
            free(bits);
            return -1;
        }
    } else {
        if (fprintf(fp, "^LH0,0\r\n^LS%d\r\n", -local.label_home_x) < 0) {
            free(bits);
            return -1;
        }
    }
    if (fprintf(fp, "^MMT\r\n^PW%d\r\n^PON\r\n^LL%d\r\n^PR%d\r\n~SD%d\r\n^FO0,0,0\r\n", width,
                height, local.speed, local.darkness) < 0) {
        free(bits);
        return -1;
    }
    if (local.gfa == RT_GFA_HEX) {
        if (write_gfa_hex(fp, bits, total, bpr, height) != 0) {
            free(bits);
            return -1;
        }
    } else if (write_gfa_z64(fp, bits, total, bpr) != 0) {
        free(bits);
        return -1;
    }
    fprintf(fp, "^FS\r\n^PQ%d\r\n^XZ\r\n", local.copies);
    free(bits);
    return ferror(fp) ? -1 : 0;
}

int rt_encode_tspl(const uint8_t *darkness, int width, int height, const rt_options_t *opt,
                   FILE *fp) {
    rt_options_t local;
    uint8_t *bits = NULL;
    int bpr = 0;
    size_t nbytes;

    if (fp == NULL || prepare(darkness, width, height, opt, &bits, &bpr, &local) != 0) {
        return -1;
    }
    fprintf(fp, "SIZE %d dot,%d dot\r\n", width, height);
    if (local.media == RT_MEDIA_MARK) {
        fprintf(fp, "BLINE %d mm,0 mm\r\n", local.gap_mm);
    } else if (local.media == RT_MEDIA_CONTINUOUS) {
        fprintf(fp, "GAP 0 mm,0 mm\r\n");
    } else {
        fprintf(fp, "GAP %d mm,0 mm\r\n", local.gap_mm);
    }
    fprintf(fp, "DIRECTION 1\r\n");
    fprintf(fp, "REFERENCE %d,0\r\n", local.label_home_x);
    fprintf(fp, "OFFSET %d dot\r\n", local.label_top);
    fprintf(fp, "SPEED %d\r\n", local.speed);
    fprintf(fp, "DENSITY %d\r\n", local.darkness);
    fprintf(fp, "CLS\r\n");
    fprintf(fp, "BITMAP 0,0,%d,%d,0,", bpr, height);
    nbytes = (size_t)bpr * (size_t)height;
    if (fwrite(bits, 1, nbytes, fp) != nbytes) {
        free(bits);
        return -1;
    }
    fprintf(fp, "\r\nPRINT %d,1\r\n", local.copies);
    free(bits);
    return ferror(fp) ? -1 : 0;
}
