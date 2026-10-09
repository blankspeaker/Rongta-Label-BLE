/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "raster_page.h"

#include <cups/raster.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int write_page(const uint8_t *darkness, int width, int height,
                      const rt_options_t *opt, rt_lang_t lang) {
    if (lang == RT_LANG_TSPL) {
        return rt_encode_tspl(darkness, width, height, opt, stdout);
    }
    if (lang == RT_LANG_ZPL) {
        return rt_encode_zpl(darkness, width, height, opt, stdout);
    }
    fprintf(stderr, "ERROR: unknown printer language\n");
    return -1;
}

int rt_filter_main(int argc, char **argv, rt_lang_t lang) {
    rt_options_t opt;
    int fd = 0;
    int opened = 0;
    cups_raster_t *ras;
    cups_page_header2_t header;
    int pages = 0;
    const char *options = "";

    if (argc < 6) {
        fprintf(stderr, "Usage: %s job user title copies options [file]\n",
                argv[0] != NULL ? argv[0] : "rasterto-rt");
        return 1;
    }

    rt_options_init(&opt);
    if (argv[5] != NULL) {
        options = argv[5];
    }
    if (rt_options_parse(&opt, options) != 0) {
        fprintf(stderr, "ERROR: unsupported option value in \"%s\"\n", options);
        return 1;
    }
    rt_options_finish(&opt, lang);
    if (argc > 4 && argv[4] != NULL && argv[4][0] != '\0') {
        char *end = NULL;
        long copies = strtol(argv[4], &end, 10);
        if (end != argv[4] && *end == '\0' && copies > 0) {
            if (copies > 999) {
                copies = 999;
            }
            opt.copies = (int)copies;
        }
    }

    if (argc > 6 && argv[6] != NULL && argv[6][0] != '\0') {
        fd = open(argv[6], O_RDONLY);
        if (fd < 0) {
            fprintf(stderr, "ERROR: cannot open raster file\n");
            return 1;
        }
        opened = 1;
    }

    ras = cupsRasterOpen(fd, CUPS_RASTER_READ);
    if (ras == NULL) {
        fprintf(stderr, "ERROR: %s\n", cupsRasterErrorString());
        if (opened) {
            close(fd);
        }
        return 1;
    }

    while (cupsRasterReadHeader2(ras, &header)) {
        int width = (int)header.cupsWidth;
        int height = (int)header.cupsHeight;
        int y;
        uint8_t *darkness;
        unsigned char *row = NULL;
        const char *err = NULL;
        int failed = 0;

        pages++;
        if (width <= 0 || height <= 0 || header.cupsWidth > 20000 ||
            header.cupsHeight > 40000) {
            fprintf(stderr, "ERROR: page %d has an unsupported size\n", pages);
            failed = 1;
        }
        if (!failed && (size_t)width > (SIZE_MAX / (size_t)height)) {
            fprintf(stderr, "ERROR: page %d is too large\n", pages);
            failed = 1;
        }
        if (failed) {
            cupsRasterClose(ras);
            if (opened) {
                close(fd);
            }
            return 1;
        }

        darkness = malloc((size_t)width * (size_t)height);
        row = malloc(header.cupsBytesPerLine > 0 ? header.cupsBytesPerLine : 1);
        if (darkness == NULL || row == NULL) {
            fprintf(stderr, "ERROR: out of memory\n");
            free(darkness);
            free(row);
            cupsRasterClose(ras);
            if (opened) {
                close(fd);
            }
            return 1;
        }

        for (y = 0; y < height; y++) {
            if (cupsRasterReadPixels(ras, row, header.cupsBytesPerLine) <
                header.cupsBytesPerLine) {
                fprintf(stderr, "ERROR: short raster read on page %d\n", pages);
                free(darkness);
                free(row);
                cupsRasterClose(ras);
                if (opened) {
                    close(fd);
                }
                return 1;
            }
            if (rt_darkness_from_row(row, width, (int)header.cupsBytesPerLine,
                                     (int)header.cupsBitsPerColor,
                                     (int)header.cupsBitsPerPixel,
                                     (int)header.cupsColorSpace,
                                     (int)header.cupsColorOrder,
                                     darkness + (size_t)y * (size_t)width, &err) != 0) {
                fprintf(stderr, "ERROR: %s\n", err != NULL ? err : "bad raster row");
                free(darkness);
                free(row);
                cupsRasterClose(ras);
                if (opened) {
                    close(fd);
                }
                return 1;
            }
        }
        free(row);
        row = NULL;

        fprintf(stderr, "INFO: page %d %dx%d px inset %d,%d,%d,%d\n", pages, width, height,
                opt.inset_left, opt.inset_right, opt.inset_top, opt.inset_bottom);
        if (write_page(darkness, width, height, &opt, lang) != 0) {
            fprintf(stderr, "ERROR: failed to encode page %d\n", pages);
            free(darkness);
            cupsRasterClose(ras);
            if (opened) {
                close(fd);
            }
            return 1;
        }
        free(darkness);
    }

    cupsRasterClose(ras);
    if (opened) {
        close(fd);
    }
    if (pages == 0) {
        fprintf(stderr, "ERROR: no pages in raster stream\n");
        return 1;
    }
    fflush(stdout);
    return ferror(stdout) ? 1 : 0;
}
