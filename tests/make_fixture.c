/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * Write a tiny uncompressed CUPS raster: 8x2 pixels, 8-bit black (K).
 * Row 0: 255 0 255 0 255 0 255 0
 * Row 1:   0 0   0 0 255 255 255 255
 *
 * Usage: make_fixture OUTPUT.raster [pages]
 */
#include <cups/raster.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    int fd;
    int pages = 1;
    int p;
    cups_raster_t *ras;
    cups_page_header2_t header;
    static const unsigned char row0[8] = {255, 0, 255, 0, 255, 0, 255, 0};
    static const unsigned char row1[8] = {0, 0, 0, 0, 255, 255, 255, 255};

    if (argc < 2) {
        fprintf(stderr, "Usage: %s OUTPUT.raster [pages]\n", argv[0]);
        return 1;
    }
    if (argc > 2) {
        pages = atoi(argv[2]);
        if (pages < 1 || pages > 8) {
            fprintf(stderr, "pages must be 1..8\n");
            return 1;
        }
    }
    fd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        perror(argv[1]);
        return 1;
    }
    ras = cupsRasterOpen(fd, CUPS_RASTER_WRITE);
    if (ras == NULL) {
        fprintf(stderr, "%s\n", cupsRasterErrorString());
        close(fd);
        return 1;
    }
    for (p = 0; p < pages; p++) {
        memset(&header, 0, sizeof header);
        header.HWResolution[0] = 203;
        header.HWResolution[1] = 203;
        header.PageSize[0] = 8;
        header.PageSize[1] = 2;
        header.cupsPageSize[0] = 8;
        header.cupsPageSize[1] = 2;
        header.cupsWidth = 8;
        header.cupsHeight = 2;
        header.cupsBitsPerColor = 8;
        header.cupsBitsPerPixel = 8;
        header.cupsBytesPerLine = 8;
        header.cupsColorOrder = CUPS_ORDER_CHUNKED;
        header.cupsColorSpace = CUPS_CSPACE_K;
        header.cupsNumColors = 1;
        header.NumCopies = 1;
        if (!cupsRasterWriteHeader2(ras, &header) ||
            cupsRasterWritePixels(ras, (unsigned char *)row0, 8) < 8 ||
            cupsRasterWritePixels(ras, (unsigned char *)row1, 8) < 8) {
            fprintf(stderr, "write failed: %s\n", cupsRasterErrorString());
            cupsRasterClose(ras);
            close(fd);
            return 1;
        }
    }
    cupsRasterClose(ras);
    close(fd);
    return 0;
}
