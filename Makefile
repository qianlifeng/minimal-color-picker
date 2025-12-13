.PHONY: all windows macos clean help

# Detect host OS (best-effort). On Windows MSYS/MinGW this is typically MINGW*/MSYS*.
UNAME_S := $(shell uname -s 2>/dev/null)
IS_DARWIN := $(findstring Darwin,$(UNAME_S))

WIN_APP := color_picker.exe
WIN_SRC := windows_color_picker.c

MAC_APP := color_picker_macos
MAC_SRC := macos_color_picker.swift

SWIFTC ?= swiftc
SWIFT_FLAGS ?= -O -framework AppKit -framework CoreGraphics -framework Foundation

# Default target: build the native binary for the current OS.
ifeq ($(IS_DARWIN),)
DEFAULT_TARGET := windows
else
DEFAULT_TARGET := macos
endif

all: $(DEFAULT_TARGET)

help:
	@echo "Targets:"
	@echo "  make / make all   - build native target ($(DEFAULT_TARGET))"
	@echo "  make windows      - build $(WIN_APP)"
	@echo "  make macos        - build $(MAC_APP)"
	@echo "  make clean        - remove build outputs"
	@echo ""
	@echo "Windows toolchains:"
	@echo "  MinGW-w64/MSYS2: make windows CC=gcc"
	@echo "  MSVC:            nmake /f Makefile windows CC=cl"

windows: $(WIN_APP)
macos: $(MAC_APP)

# ----------------------
# Windows (C / Win32)
# ----------------------

# Compiler selection
# - Many MSYS/MINGW environments set CC=cc, but 'cc' may not exist.
# - Prefer gcc when available; use cl when explicitly requested.
CC ?= gcc

ifeq ($(notdir $(CC)),cc)
CC := gcc
endif

# Detect MSVC cl.exe (works with values like: cl, cl.exe, C:\...\cl.exe)
IS_MSVC := $(filter cl cl.exe,$(notdir $(CC)))

ifeq ($(IS_MSVC),)
# MinGW/Clang/GCC
CFLAGS ?= -O2 -Wall -Wextra -municode -mwindows
LDLIBS ?= -lgdi32 -luser32

$(WIN_APP): $(WIN_SRC)
	$(CC) $(CFLAGS) $(WIN_SRC) $(LDLIBS) -o $(WIN_APP)
else
# MSVC
CFLAGS ?= /nologo /O2 /W4 /DUNICODE /D_UNICODE
LDLIBS ?= user32.lib gdi32.lib

$(WIN_APP): $(WIN_SRC)
	$(CC) $(CFLAGS) $(WIN_SRC) $(LDLIBS) /Fe:$(WIN_APP)
endif

# ----------------------
# macOS (Swift)
# ----------------------

$(MAC_APP): $(MAC_SRC)
	$(SWIFTC) $(SWIFT_FLAGS) $(MAC_SRC) -o $(MAC_APP)

clean:
	-@rm -f $(WIN_APP) $(MAC_APP) *.obj *.pdb *.ilk
