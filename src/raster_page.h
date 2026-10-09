/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef RONGTA_RASTER_PAGE_H
#define RONGTA_RASTER_PAGE_H

#include "encode.h"

/* CUPS filter entry. Reads application/vnd.cups-raster and writes one language. */
int rt_filter_main(int argc, char **argv, rt_lang_t lang);

#endif
