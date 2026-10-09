# SPDX-License-Identifier: GPL-3.0-or-later
# Host build and tests. The macOS installer is build.sh (dist/Rongta-Label-BLE.pkg).
CC ?= cc
CFLAGS ?= -std=c11 -D_DEFAULT_SOURCE -O2 -Wall -Wextra -Werror -Isrc
CUPS_CFLAGS := $(shell cups-config --cflags 2>/dev/null)
CUPS_LIBS := $(shell cups-config --libs 2>/dev/null)
ifeq ($(strip $(CUPS_LIBS)),)
CUPS_LIBS := -lcups
endif
ZLIB_LIBS ?= -lz
ifeq ($(shell uname -s),Darwin)
SDK := $(shell xcrun --show-sdk-path 2>/dev/null)
ifneq ($(SDK),)
CFLAGS += -isysroot $(SDK)
ifeq ($(strip $(CUPS_CFLAGS)),)
CUPS_CFLAGS := -I$(SDK)/usr/include
endif
endif
endif

BUILD := build
FILTER_SRC := src/encode.c src/raster_page.c

.PHONY: all test ppd clean fixtures

all: $(BUILD)/rastertozpl-rt $(BUILD)/rastertotspl-rt

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/rastertozpl-rt: src/rastertozpl-rt.c $(FILTER_SRC) src/encode.h src/raster_page.h | $(BUILD)
	$(CC) $(CFLAGS) $(CUPS_CFLAGS) -o $@ src/rastertozpl-rt.c $(FILTER_SRC) $(CUPS_LIBS) $(ZLIB_LIBS)

$(BUILD)/rastertotspl-rt: src/rastertotspl-rt.c $(FILTER_SRC) src/encode.h src/raster_page.h | $(BUILD)
	$(CC) $(CFLAGS) $(CUPS_CFLAGS) -o $@ src/rastertotspl-rt.c $(FILTER_SRC) $(CUPS_LIBS) $(ZLIB_LIBS)

$(BUILD)/test_encode: tests/test_encode.c src/encode.c src/encode.h | $(BUILD)
	$(CC) $(CFLAGS) -o $@ tests/test_encode.c src/encode.c $(ZLIB_LIBS)

$(BUILD)/make_fixture: tests/make_fixture.c | $(BUILD)
	$(CC) $(CFLAGS) $(CUPS_CFLAGS) -o $@ tests/make_fixture.c $(CUPS_LIBS)

ppd:
	python3 ppd/gen_ppds.py

fixtures: $(BUILD)/make_fixture
	mkdir -p tests/fixtures
	$(BUILD)/make_fixture tests/fixtures/tiny-8x2.raster 1

test: $(BUILD)/test_encode $(BUILD)/rastertozpl-rt $(BUILD)/rastertotspl-rt $(BUILD)/make_fixture
	$(BUILD)/test_encode
	mkdir -p $(BUILD)
	$(BUILD)/make_fixture $(BUILD)/tiny-8x2.raster 1
	$(BUILD)/make_fixture $(BUILD)/tiny-8x2-2page.raster 2
	$(BUILD)/rastertozpl-rt 1 user title 1 'rtGfa=Hex rtInsetLeft=0 rtInsetRight=0 rtInsetTop=0 rtInsetBottom=0' tests/fixtures/tiny-8x2.raster > $(BUILD)/tiny-8x2.zpl
	diff -u tests/expected/tiny-8x2.zpl $(BUILD)/tiny-8x2.zpl
	$(BUILD)/rastertozpl-rt 1 user title 1 'rtGfa=Hex rtInsetLeft=0 rtInsetRight=0 rtInsetTop=0 rtInsetBottom=0' $(BUILD)/tiny-8x2.raster > $(BUILD)/regen.zpl
	diff -u tests/expected/tiny-8x2.zpl $(BUILD)/regen.zpl
	$(BUILD)/rastertozpl-rt 1 user title 1 'rtInsetLeft=0 rtInsetRight=0 rtInsetTop=0 rtInsetBottom=0' tests/fixtures/tiny-8x2.raster > $(BUILD)/tiny-8x2-z64.zpl
	python3 -c 'import pathlib; d=pathlib.Path("$(BUILD)/tiny-8x2-z64.zpl").read_bytes(); assert b":Z64:" in d and b"^MMT\r\n" in d and b"~SD7\r\n" in d and b"^MD" not in d'
	$(BUILD)/rastertotspl-rt 1 user title 1 '' tests/fixtures/tiny-8x2.raster > $(BUILD)/tiny-8x2.tspl
	cmp tests/expected/tiny-8x2.tspl $(BUILD)/tiny-8x2.tspl
	$(BUILD)/rastertozpl-rt 1 user title 2 'rtLabelHomeX=-20 rtLabelTop=0 Darkness=10 PrintSpeed=3 MediaType=Continuous rtGfa=Hex rtInsetLeft=0 rtInsetRight=0 rtInsetTop=0 rtInsetBottom=0' tests/fixtures/tiny-8x2.raster > $(BUILD)/tiny-8x2-shift.zpl
	diff -u tests/expected/tiny-8x2-shift.zpl $(BUILD)/tiny-8x2-shift.zpl
	$(BUILD)/rastertotspl-rt 1 user title 2 'rtLabelHomeX=-20 rtLabelTop=0 Darkness=10 PrintSpeed=3 MediaType=Continuous' tests/fixtures/tiny-8x2.raster > $(BUILD)/tiny-8x2-shift.tspl
	cmp tests/expected/tiny-8x2-shift.tspl $(BUILD)/tiny-8x2-shift.tspl
	cat tests/expected/tiny-8x2.zpl tests/expected/tiny-8x2.zpl > $(BUILD)/two.zpl
	$(BUILD)/rastertozpl-rt 1 user title 1 'rtGfa=Hex rtInsetLeft=0 rtInsetRight=0 rtInsetTop=0 rtInsetBottom=0' $(BUILD)/tiny-8x2-2page.raster > $(BUILD)/two-out.zpl
	diff -u $(BUILD)/two.zpl $(BUILD)/two-out.zpl
	python3 tests/test_ppd.py
	python3 -c 'import plistlib; from pathlib import Path; d=plistlib.loads(Path("macos/setup/Info.plist").read_bytes()); t=d["NSBluetoothAlwaysUsageDescription"]; assert t=="Rongta Label Setup uses Bluetooth to find and set up your label printer.", t'
	python3 ppd/gen_ppds.py --check
	bash -n build.sh
	sh -n macos/rongta-bt
	sh -n macos/scripts/preinstall
	sh -n macos/scripts/postinstall
	sh -n macos/uninstall.sh
	sh -n macos/rongta-testprint
	python3 tests/test_edge_pdf.py
	if grep -E -n 'nc -N|/usr/bin/nc' macos/rongta-bt macos/rongta-testprint macos/scripts/postinstall macos/scripts/preinstall macos/uninstall.sh macos/setup/*.swift macos/rongta-ble.swift; then \
	  echo 'netcat flag regression' >&2; exit 1; \
	fi
	sh tests/scrub.sh
	if [ "$$(uname -s)" = Darwin ] && command -v swiftc >/dev/null 2>&1; then \
	  sdk=$$(xcrun --show-sdk-path 2>/dev/null || true); \
	  arch=$$(uname -m); \
	  prefix=$$(pwd); \
	  maps="-file-prefix-map $$prefix=. -debug-prefix-map $$prefix=. -coverage-prefix-map $$prefix=."; \
	  if [ -n "$${HOME:-}" ]; then \
	    maps="$$maps -file-prefix-map $$HOME=/home -debug-prefix-map $$HOME=/home -coverage-prefix-map $$HOME=/home"; \
	  fi; \
	  if [ -n "$$sdk" ]; then \
	    swiftc -sdk "$$sdk" -target "$$arch-apple-macosx13.0" $$maps \
	      -Xfrontend -no-serialize-debugging-options \
	      -o $(BUILD)/setup-logic-test \
	      macos/BluetoothGate.swift macos/setup/SetupLogic.swift macos/setup/EdgeTestPDF.swift macos/setup/SetupLogicTests.swift; \
	  else \
	    swiftc -target "$$arch-apple-macosx13.0" $$maps \
	      -Xfrontend -no-serialize-debugging-options \
	      -o $(BUILD)/setup-logic-test \
	      macos/BluetoothGate.swift macos/setup/SetupLogic.swift macos/setup/EdgeTestPDF.swift macos/setup/SetupLogicTests.swift; \
	  fi; \
	  $(BUILD)/setup-logic-test; \
	fi

clean:
	rm -rf $(BUILD)
