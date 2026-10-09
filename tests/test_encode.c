/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "encode.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static int g_fails = 0;

static void check(int cond, const char *msg) {
    if (!cond) {
        fprintf(stderr, "FAIL %s\n", msg);
        g_fails++;
    }
}

static int read_file(const char *path, unsigned char **out, size_t *len) {
    FILE *fp = fopen(path, "rb");
    long n;
    unsigned char *buf;

    if (fp == NULL) {
        return -1;
    }
    if (fseek(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return -1;
    }
    n = ftell(fp);
    if (n < 0) {
        fclose(fp);
        return -1;
    }
    if (fseek(fp, 0, SEEK_SET) != 0) {
        fclose(fp);
        return -1;
    }
    buf = malloc((size_t)n + 1);
    if (buf == NULL) {
        fclose(fp);
        return -1;
    }
    if (fread(buf, 1, (size_t)n, fp) != (size_t)n) {
        free(buf);
        fclose(fp);
        return -1;
    }
    buf[n] = 0;
    fclose(fp);
    *out = buf;
    *len = (size_t)n;
    return 0;
}

static int capture(int (*fn)(const uint8_t *, int, int, const rt_options_t *, FILE *),
                   const uint8_t *dark, int w, int h, const rt_options_t *opt,
                   unsigned char **out, size_t *len) {
    FILE *fp = tmpfile();
    long n;
    unsigned char *buf;

    if (fp == NULL) {
        return -1;
    }
    if (fn(dark, w, h, opt, fp) != 0) {
        fclose(fp);
        return -1;
    }
    if (fflush(fp) != 0) {
        fclose(fp);
        return -1;
    }
    n = ftell(fp);
    if (n < 0) {
        fclose(fp);
        return -1;
    }
    if (fseek(fp, 0, SEEK_SET) != 0) {
        fclose(fp);
        return -1;
    }
    buf = malloc((size_t)n + 1);
    if (buf == NULL) {
        fclose(fp);
        return -1;
    }
    if (fread(buf, 1, (size_t)n, fp) != (size_t)n) {
        free(buf);
        fclose(fp);
        return -1;
    }
    buf[n] = 0;
    fclose(fp);
    *out = buf;
    *len = (size_t)n;
    return 0;
}

static void expect_file(const unsigned char *got, size_t glen, const char *path) {
    unsigned char *exp = NULL;
    size_t elen = 0;

    if (read_file(path, &exp, &elen) != 0) {
        fprintf(stderr, "FAIL cannot read %s\n", path);
        g_fails++;
        return;
    }
    if (glen != elen || memcmp(got, exp, glen) != 0) {
        fprintf(stderr, "FAIL mismatch against %s (got %zu bytes, expected %zu)\n", path, glen,
                elen);
        if (memchr(got, 0, glen) == NULL && memchr(exp, 0, elen) == NULL) {
            fprintf(stderr, "--- got ---\n%s--- expected ---\n%s", got, exp);
        }
        g_fails++;
    }
    free(exp);
}

static const uint8_t k_pat[16] = {255, 0, 255, 0, 255, 0, 255, 0, 0, 0, 0, 0, 255, 255, 255, 255};

static void test_pack(void) {
    uint8_t *bits = NULL;
    int bpr = 0;
    uint8_t *inv = NULL;
    int ibpr = 0;
    uint8_t wide[10];
    uint8_t *wbits = NULL;
    int wbpr = 0;
    int i;

    check(rt_pack_bits(k_pat, 8, 2, RT_DITHER_THRESHOLD, 0, &bits, &bpr) == 0, "pack");
    check(bpr == 1 && bits != NULL && bits[0] == 0xAA && bits[1] == 0x0F, "threshold bits");
    free(bits);

    check(rt_pack_bits(k_pat, 8, 2, RT_DITHER_THRESHOLD, 1, &inv, &ibpr) == 0, "invert pack");
    check(inv != NULL && inv[0] == 0x55 && inv[1] == 0xF0, "inverted bits");
    free(inv);

    for (i = 0; i < 10; i++) {
        wide[i] = 255;
    }
    check(rt_pack_bits(wide, 10, 1, RT_DITHER_THRESHOLD, 0, &wbits, &wbpr) == 0, "wide pack");
    check(wbpr == 2 && wbits != NULL && wbits[0] == 0xFF && wbits[1] == 0xC0, "wide bits");
    free(wbits);
}

static void test_floyd(void) {
    /* Hand-computed Floyd-Steinberg, integer truncation toward zero.
     * 200  40
     *  40  40
     * Only the first pixel is black. Packed MSB-first in one byte: 0x80, 0x00.
     */
    const uint8_t px[4] = {200, 40, 40, 40};
    uint8_t *bits = NULL;
    int bpr = 0;
    uint8_t white[4] = {0, 0, 0, 0};
    uint8_t black[4] = {255, 255, 255, 255};
    uint8_t *wb = NULL;
    uint8_t *bb = NULL;

    check(rt_pack_bits(px, 2, 2, RT_DITHER_FLOYD, 0, &bits, &bpr) == 0, "floyd pack");
    check(bpr == 1 && bits != NULL && bits[0] == 0x80 && bits[1] == 0x00, "floyd bits");
    free(bits);

    check(rt_pack_bits(white, 2, 2, RT_DITHER_FLOYD, 0, &wb, &bpr) == 0, "floyd white");
    check(wb != NULL && wb[0] == 0x00 && wb[1] == 0x00, "floyd white bits");
    free(wb);
    check(rt_pack_bits(black, 2, 2, RT_DITHER_BAYER, 0, &bb, &bpr) == 0, "bayer black");
    check(bb != NULL && (bb[0] & 0xC0) == 0xC0 && (bb[1] & 0xC0) == 0xC0, "bayer black bits");
    free(bb);
}

static void test_rows(void) {
    const char *err = NULL;
    unsigned char krow[4] = {255, 0, 128, 127};
    unsigned char wrow[4] = {255, 0, 255, 0};
    unsigned char rgb[6] = {255, 255, 255, 0, 0, 0};
    unsigned char red[3] = {255, 0, 0};
    unsigned char cmyk_k[4] = {0, 0, 0, 255};
    unsigned char cmyk_w[4] = {0, 0, 0, 0};
    unsigned char bit = 0x80;
    uint8_t dst[8];

    check(rt_darkness_from_row(krow, 4, 4, 8, 8, 3, 0, dst, &err) == 0, "K row");
    check(dst[0] == 255 && dst[1] == 0 && dst[2] == 128 && dst[3] == 127, "K values");

    check(rt_darkness_from_row(wrow, 4, 4, 8, 8, 0, 0, dst, &err) == 0, "W row");
    check(dst[0] == 0 && dst[1] == 255 && dst[2] == 0 && dst[3] == 255, "W inverted");

    check(rt_darkness_from_row(rgb, 2, 6, 8, 24, 1, 0, dst, &err) == 0, "RGB row");
    check(dst[0] == 0 && dst[1] == 255, "RGB black and white");

    check(rt_darkness_from_row(red, 1, 3, 8, 24, 19, 0, dst, &err) == 0, "sRGB red");
    check(dst[0] == (uint8_t)(255 - (255 * 299) / 1000), "red luma");

    check(rt_darkness_from_row(cmyk_k, 1, 4, 8, 32, 6, 0, dst, &err) == 0, "CMYK black");
    check(dst[0] == 255, "CMYK K");
    check(rt_darkness_from_row(cmyk_w, 1, 4, 8, 32, 6, 0, dst, &err) == 0, "CMYK white");
    check(dst[0] == 0, "CMYK paper");

    check(rt_darkness_from_row(&bit, 8, 1, 1, 1, 3, 0, dst, &err) == 0, "1-bit K");
    check(dst[0] == 255 && dst[1] == 0 && dst[7] == 0, "1-bit MSB");

    check(rt_darkness_from_row(krow, 4, 4, 8, 8, 3, 2, dst, &err) != 0, "reject planar");
    check(rt_darkness_from_row(krow, 4, 4, 16, 16, 3, 0, dst, &err) != 0, "reject 16-bit");
}

static void test_options(void) {
    rt_options_t opt;

    rt_options_init(&opt);
    check(opt.label_home_x == 20 && opt.label_top == -20, "calibrated defaults");
    check(opt.darkness == 7 && opt.speed == 5 && opt.media == RT_MEDIA_GAP, "other defaults");
    check(opt.gfa == RT_GFA_Z64, "z64 default");
    check(rt_options_parse(&opt, "PageSize=4x6in Darkness=10 PrintSpeed=3 "
                                  "rtLabelHomeX=-20 rtLabelTop=0 MediaType=Continuous "
                                  "rtDither=\"Bayer\" rtInvert=On rtGapMm=3") == 0,
          "parse");
    check(opt.darkness == 10 && opt.speed == 3 && opt.label_home_x == -20 && opt.label_top == 0,
          "parsed numbers");
    check(opt.media == RT_MEDIA_CONTINUOUS && opt.dither == RT_DITHER_BAYER && opt.invert == 1 &&
              opt.gap_mm == 3,
          "parsed enums");
    check(rt_options_parse(&opt, "Darkness=99") != 0, "reject darkness");
    check(rt_options_parse(&opt, "PrintSpeed=1") != 0, "reject speed");
    check(rt_options_parse(&opt, "rtLabelTop=-121") != 0, "reject label top");
    check(rt_options_parse(&opt, "MediaType=Roll") != 0, "reject media");
    check(rt_options_parse(&opt, "rtDither=None") != 0, "reject dither");
    check(rt_options_parse(&opt, "rtGfa=Hex") == 0 && opt.gfa == RT_GFA_HEX, "hex option");
    check(rt_options_parse(&opt, "rtGfa=Z64") == 0 && opt.gfa == RT_GFA_Z64, "z64 option");
    check(rt_options_parse(&opt, "rtGfa=Raw") != 0, "reject gfa");
    check(opt.inset_left == 0 && opt.inset_set == 0, "inset unset");
    check(rt_options_parse(&opt, "rtInsetLeft=0 rtInsetRight=0 rtInsetTop=0 rtInsetBottom=0") == 0,
          "parse zero inset");
    check(opt.inset_set == 1 && opt.inset_left == 0 && opt.inset_top == 0, "explicit zero inset");
    rt_options_finish(&opt, RT_LANG_ZPL);
    check(opt.inset_left == 0 && opt.inset_right == 0 && opt.inset_top == 0 && opt.inset_bottom == 0,
          "explicit zero stays");
    rt_options_init(&opt);
    rt_options_finish(&opt, RT_LANG_ZPL);
    check(opt.inset_left == 8 && opt.inset_right == 8 && opt.inset_top == 32 && opt.inset_bottom == 0,
          "zpl inset default");
    rt_options_init(&opt);
    rt_options_finish(&opt, RT_LANG_TSPL);
    check(opt.inset_left == 0 && opt.inset_top == 0 && opt.inset_bottom == 0, "tspl inset default");
    check(rt_options_parse(&opt, "rtInsetTop=801") != 0, "reject inset");
}

static void test_inset(void) {
    uint8_t src[8] = {0, 0, 255, 255, 0, 0, 255, 255};
    uint8_t dst[8];
    uint8_t ident[16];
    uint8_t *page;
    uint8_t *copy;
    int x;
    int y;
    rt_options_t opt;
    unsigned char *buf = NULL;
    size_t len = 0;
    const int width = 40;
    const int height = 40;

    check(rt_render_inset(k_pat, 8, 2, 0, 0, 0, 0, ident) == 0, "inset 0 render");
    check(memcmp(k_pat, ident, sizeof k_pat) == 0, "inset 0 bytes");

    rt_options_init(&opt);
    opt.gfa = RT_GFA_HEX;
    check(rt_options_parse(&opt, "rtInsetLeft=0 rtInsetRight=0 rtInsetTop=0 rtInsetBottom=0") == 0,
          "zero inset options");
    check(capture(rt_encode_zpl, k_pat, 8, 2, &opt, &buf, &len) == 0, "encode inset 0");
    expect_file(buf, len, "tests/expected/tiny-8x2.zpl");
    free(buf);

    check(rt_render_inset(src, 4, 2, 1, 1, 0, 0, dst) == 0, "area average");
    check(dst[0] == 0 && dst[1] == 0 && dst[2] == 255 && dst[3] == 0, "scaled row 0");
    check(dst[4] == 0 && dst[5] == 0 && dst[6] == 255 && dst[7] == 0, "scaled row 1");
    check(rt_render_inset(src, 4, 2, 3, 3, 0, 0, dst) != 0, "inset larger than page");

    page = malloc((size_t)width * (size_t)height);
    copy = malloc((size_t)width * (size_t)height);
    check(page != NULL && copy != NULL, "inset page");
    if (page == NULL || copy == NULL) {
        free(page);
        free(copy);
        return;
    }
    memset(page, 255, (size_t)width * (size_t)height);
    check(rt_render_inset(page, width, height, 8, 8, 32, 0, copy) == 0, "rp425 inset");
    for (y = 0; y < height; y++) {
        for (x = 0; x < width; x++) {
            uint8_t expect = 0;
            if (y >= 32 && x >= 8 && x < width - 8) {
                expect = 255;
            }
            if (copy[(size_t)y * (size_t)width + (size_t)x] != expect) {
                check(0, "rp425 inset pixel");
                free(page);
                free(copy);
                return;
            }
        }
    }
    check(1, "rp425 inset pixels");
    free(page);
    free(copy);

    {
        const int w2 = 406;
        const int h2 = 203;
        uint8_t *src2 = calloc((size_t)w2 * (size_t)h2, 1);
        uint8_t *dst2 = calloc((size_t)w2 * (size_t)h2, 1);
        uint8_t short_src[32];
        uint8_t short_dst[32];

        check(src2 != NULL && dst2 != NULL, "2x1 buffers");
        if (src2 != NULL && dst2 != NULL) {
            memset(src2, 255, (size_t)w2 * (size_t)h2);
            check(rt_render_inset(src2, w2, h2, 8, 8, 32, 0, dst2) == 0, "2x1 default inset fits");
            check(dst2[0] == 0, "2x1 top margin stays white");
            check(dst2[(size_t)32 * (size_t)w2 + 8] == 255, "2x1 printable origin");
        }
        free(src2);
        free(dst2);
        memset(short_src, 255, sizeof short_src);
        check(rt_render_inset(short_src, 1, 32, 0, 0, 32, 0, short_dst) != 0, "height 32 rejects top inset");
    }
}

static uint16_t crc16_xmodem(const unsigned char *data, size_t len) {
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

static int b64_val(int c) {
    if (c >= 'A' && c <= 'Z') {
        return c - 'A';
    }
    if (c >= 'a' && c <= 'z') {
        return c - 'a' + 26;
    }
    if (c >= '0' && c <= '9') {
        return c - '0' + 52;
    }
    if (c == '+') {
        return 62;
    }
    if (c == '/') {
        return 63;
    }
    return -1;
}

static int b64_decode(const char *text, size_t len, unsigned char **out, size_t *out_len) {
    unsigned char *buf;
    size_t cap = len / 4 * 3;
    size_t n = 0;
    size_t i = 0;

    buf = malloc(cap + 2);
    if (buf == NULL) {
        return -1;
    }
    while (i < len) {
        int v[4];
        int k;
        int pad = 0;
        for (k = 0; k < 4; k++) {
            if (i >= len) {
                free(buf);
                return -1;
            }
            if (text[i] == '=') {
                v[k] = 0;
                pad++;
            } else {
                v[k] = b64_val((unsigned char)text[i]);
                if (v[k] < 0) {
                    free(buf);
                    return -1;
                }
            }
            i++;
        }
        buf[n++] = (unsigned char)((v[0] << 2) | (v[1] >> 4));
        if (pad < 2) {
            buf[n++] = (unsigned char)(((v[1] & 15) << 4) | (v[2] >> 2));
        }
        if (pad < 1) {
            buf[n++] = (unsigned char)(((v[2] & 3) << 6) | v[3]);
        }
    }
    *out = buf;
    *out_len = n;
    return 0;
}

static void test_z64(void) {
    rt_options_t opt;
    unsigned char *buf = NULL;
    size_t len = 0;
    const char *job;
    const char *z64;
    const char *crc_at;
    char crc_text[5];
    unsigned int file_crc = 0;
    unsigned char *comp = NULL;
    size_t comp_len = 0;
    unsigned char raw[8];
    uLongf raw_len = sizeof raw;
    const unsigned char known[] = "123456789";

    check(crc16_xmodem(known, 9) == 0x31C3, "crc16 xmodem vector");

    rt_options_init(&opt);
    check(capture(rt_encode_zpl, k_pat, 8, 2, &opt, &buf, &len) == 0, "encode z64");
    check(buf != NULL, "z64 buffer");
    if (buf == NULL) {
        return;
    }
    job = (const char *)buf;
    check(strstr(job, "^MMT\r\n") != NULL, "mmt");
    check(strstr(job, "~SD7\r\n") != NULL, "sd7");
    check(strstr(job, "^MD") == NULL, "no md");
    check(strstr(job, "\n") != NULL && strstr(job, "\r\n") != NULL, "crlf");
    z64 = strstr(job, "^GFA,2,2,1,:Z64:");
    check(z64 != NULL, "gfa z64 header");
    if (z64 == NULL) {
        free(buf);
        return;
    }
    z64 += strlen("^GFA,2,2,1,:Z64:");
    crc_at = strchr(z64, ':');
    check(crc_at != NULL && crc_at - z64 > 0, "z64 colon");
    if (crc_at == NULL) {
        free(buf);
        return;
    }
    check(crc16_xmodem((const unsigned char *)z64, (size_t)(crc_at - z64)) ==
              (uint16_t)strtoul(crc_at + 1, NULL, 16),
          "z64 crc matches base64");
    memcpy(crc_text, crc_at + 1, 4);
    crc_text[4] = '\0';
    check(sscanf(crc_text, "%4X", &file_crc) == 1, "crc hex");
    check(b64_decode(z64, (size_t)(crc_at - z64), &comp, &comp_len) == 0, "b64 decode");
    check(comp != NULL && uncompress(raw, &raw_len, comp, (uLong)comp_len) == Z_OK, "inflate");
    check(raw_len == 2 && raw[0] == 0xAA && raw[1] == 0x0F, "inflated bits");
    free(comp);
    free(buf);
}

static void test_golden(void) {
    rt_options_t opt;
    unsigned char *buf = NULL;
    size_t len = 0;

    rt_options_init(&opt);
    opt.gfa = RT_GFA_HEX;
    check(capture(rt_encode_zpl, k_pat, 8, 2, &opt, &buf, &len) == 0, "encode zpl");
    expect_file(buf, len, "tests/expected/tiny-8x2.zpl");
    free(buf);

    check(capture(rt_encode_tspl, k_pat, 8, 2, &opt, &buf, &len) == 0, "encode tspl");
    expect_file(buf, len, "tests/expected/tiny-8x2.tspl");
    free(buf);

    rt_options_init(&opt);
    check(rt_options_parse(&opt, "rtLabelHomeX=-20 rtLabelTop=0 Darkness=10 PrintSpeed=3 "
                                  "MediaType=Continuous rtGfa=Hex") == 0,
          "shift parse");
    opt.copies = 2;
    check(opt.gfa == RT_GFA_HEX, "shift hex");
    check(capture(rt_encode_zpl, k_pat, 8, 2, &opt, &buf, &len) == 0, "encode shift zpl");
    expect_file(buf, len, "tests/expected/tiny-8x2-shift.zpl");
    free(buf);
    check(capture(rt_encode_tspl, k_pat, 8, 2, &opt, &buf, &len) == 0, "encode shift tspl");
    expect_file(buf, len, "tests/expected/tiny-8x2-shift.tspl");
    free(buf);
}

static void test_blackmark(void) {
    rt_options_t opt;
    unsigned char *buf = NULL;
    size_t len = 0;
    const uint8_t px[1] = {255};

    rt_options_init(&opt);
    check(rt_options_set(&opt, "MediaType", "BlackMark") == 0, "mark");
    check(capture(rt_encode_tspl, px, 1, 1, &opt, &buf, &len) == 0, "mark encode");
    check(buf != NULL && strstr((char *)buf, "BLINE 2 mm,0 mm\r\n") != NULL, "bline");
    check(buf != NULL && strstr((char *)buf, "GAP ") == NULL, "no gap on mark");
    check(buf != NULL && strstr((char *)buf, "REFERENCE 20,0\r\n") != NULL, "reference");
    check(buf != NULL && strstr((char *)buf, "OFFSET -20 dot\r\n") != NULL, "offset");
    free(buf);
}

int main(void) {
    test_pack();
    test_floyd();
    test_rows();
    test_options();
    test_z64();
    test_golden();
    test_inset();
    test_blackmark();
    if (g_fails != 0) {
        fprintf(stderr, "%d failure(s)\n", g_fails);
        return 1;
    }
    printf("encode tests ok\n");
    return 0;
}
