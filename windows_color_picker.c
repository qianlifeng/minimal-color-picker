// Minimal Color Picker (Windows, single-file)
// Build (MSVC): cl /O2 /W4 windows_color_picker.c user32.lib gdi32.lib
// Run: windows_color_picker.exe
// Behavior:
// - Shows a circular magnifier near the cursor.
// - Left click: copies center pixel color as #RRGGBB to clipboard and exits.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>

static const int kRadius = 120;          // circle radius in px
static const int kDiameter = 240;        // 2*radius
static const int kZoom = 8;              // magnification factor
static const int kBorderWidth = 2;
static const int kTickMs = 16;           // ~60fps
static const int kOffsetX = 40;          // window offset from cursor
static const int kOffsetY = 40;

static HINSTANCE g_hInstance;
static HWND g_hwnd;
static HHOOK g_mouseHook;
static HHOOK g_keyboardHook;

static HDC g_memDC;
static HBITMAP g_dib;
static void* g_bits;

static HDC g_capDC;
static HBITMAP g_capBmp;
static int g_capSize;

static void enable_dpi_awareness(void) {
    // Prefer Per-Monitor V2 when available; fall back to legacy system DPI aware.
    HMODULE user32 = LoadLibraryW(L"user32.dll");
    if (user32) {
        typedef BOOL (WINAPI *SetDpiAwarenessContextFn)(HANDLE);
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wcast-function-type"
#endif
        SetDpiAwarenessContextFn fn = (SetDpiAwarenessContextFn)GetProcAddress(user32, "SetProcessDpiAwarenessContext");
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic pop
#endif
        if (fn) {
            // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (HANDLE)-4
            fn((HANDLE)-4);
            FreeLibrary(user32);
            return;
        }
        FreeLibrary(user32);
    }

    HMODULE u = LoadLibraryW(L"user32.dll");
    if (u) {
        typedef BOOL (WINAPI *SetProcessDPIAwareFn)(void);
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wcast-function-type"
#endif
        SetProcessDPIAwareFn fn2 = (SetProcessDPIAwareFn)GetProcAddress(u, "SetProcessDPIAware");
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic pop
#endif
        if (fn2) fn2();
        FreeLibrary(u);
    }
}

static RECT clamp_to_monitor(POINT desiredTopLeft, int width, int height) {
    RECT r = { desiredTopLeft.x, desiredTopLeft.y, desiredTopLeft.x + width, desiredTopLeft.y + height };

    HMONITOR mon = MonitorFromPoint(desiredTopLeft, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi;
    mi.cbSize = sizeof(mi);
    GetMonitorInfo(mon, &mi);

    int monLeft = mi.rcWork.left;
    int monTop = mi.rcWork.top;
    int monRight = mi.rcWork.right;
    int monBottom = mi.rcWork.bottom;

    int x = r.left;
    int y = r.top;

    if (x < monLeft) x = monLeft;
    if (y < monTop) y = monTop;
    if (x + width > monRight) x = monRight - width;
    if (y + height > monBottom) y = monBottom - height;

    RECT out = { x, y, x + width, y + height };
    return out;
}

static void clipboard_set_text_utf16(const wchar_t* text) {
    if (!OpenClipboard(NULL)) return;
    EmptyClipboard();

    size_t len = wcslen(text);
    size_t bytes = (len + 1) * sizeof(wchar_t);
    HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (hMem) {
        void* p = GlobalLock(hMem);
        if (p) {
            memcpy(p, text, bytes);
            GlobalUnlock(hMem);
            SetClipboardData(CF_UNICODETEXT, hMem);
        } else {
            GlobalFree(hMem);
        }
    }
    CloseClipboard();
}

static BOOL try_use_parent_console_stdout(void) {
    // Do not create a new console window.
    if (!GetConsoleWindow()) {
        if (!AttachConsole(ATTACH_PARENT_PROCESS)) {
            return FALSE;
        }
    }

    (void)freopen("CONOUT$", "w", stdout);
    (void)freopen("CONOUT$", "w", stderr);
    return TRUE;
}

static void copy_color_and_quit(void) {
    POINT p;
    GetCursorPos(&p);

    HDC screen = GetDC(NULL);
    COLORREF c = GetPixel(screen, p.x, p.y);
    ReleaseDC(NULL, screen);

    int r = GetRValue(c);
    int g = GetGValue(c);
    int b = GetBValue(c);

    wchar_t buf[16];
    swprintf(buf, 16, L"#%02X%02X%02X", r, g, b);
    clipboard_set_text_utf16(buf);

    if (try_use_parent_console_stdout()) {
        wprintf(L"%ls\n", buf);
        fflush(stdout);
    }

    PostQuitMessage(0);
}

static LRESULT CALLBACK LowLevelMouseProc(int nCode, WPARAM wParam, LPARAM lParam) {
    if (nCode == HC_ACTION) {
        const MSLLHOOKSTRUCT* ms = (const MSLLHOOKSTRUCT*)lParam;
        (void)ms;
        if (wParam == WM_LBUTTONDOWN) {
            copy_color_and_quit();
            return 1; // swallow to avoid double-click side effects
        }
    }
    return CallNextHookEx(g_mouseHook, nCode, wParam, lParam);
}

static LRESULT CALLBACK LowLevelKeyboardProc(int nCode, WPARAM wParam, LPARAM lParam) {
    if (nCode == HC_ACTION) {
        const KBDLLHOOKSTRUCT* ks = (const KBDLLHOOKSTRUCT*)lParam;

        if (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN) {
            int step = (GetAsyncKeyState(VK_SHIFT) & 0x8000) ? 5 : 1;
            POINT p;

            switch (ks->vkCode) {
                case VK_LEFT:
                    GetCursorPos(&p);
                    SetCursorPos(p.x - step, p.y);
                    return 1;
                case VK_RIGHT:
                    GetCursorPos(&p);
                    SetCursorPos(p.x + step, p.y);
                    return 1;
                case VK_UP:
                    GetCursorPos(&p);
                    SetCursorPos(p.x, p.y - step);
                    return 1;
                case VK_DOWN:
                    GetCursorPos(&p);
                    SetCursorPos(p.x, p.y + step);
                    return 1;
                case VK_ESCAPE:
                    PostQuitMessage(0);
                    return 1;
                default:
                    break;
            }
        }
    }
    return CallNextHookEx(g_keyboardHook, nCode, wParam, lParam);
}

static void ensure_resources(void) {
    if (!g_memDC) {
        HDC screen = GetDC(NULL);
        g_memDC = CreateCompatibleDC(screen);

        BITMAPINFO bmi;
        ZeroMemory(&bmi, sizeof(bmi));
        bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = kDiameter;
        bmi.bmiHeader.biHeight = -kDiameter; // top-down
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = BI_RGB;

        g_dib = CreateDIBSection(screen, &bmi, DIB_RGB_COLORS, &g_bits, NULL, 0);
        SelectObject(g_memDC, g_dib);

        g_capDC = CreateCompatibleDC(screen);

        ReleaseDC(NULL, screen);
    }

    // Use odd capture size so the cursor maps to the exact center pixel.
    int desiredCapSize = kDiameter / kZoom;
    if ((desiredCapSize % 2) == 0) desiredCapSize += 1;

    if (!g_capBmp || g_capSize != desiredCapSize) {
        if (g_capBmp) {
            DeleteObject(g_capBmp);
            g_capBmp = NULL;
        }
        HDC screen = GetDC(NULL);
        g_capBmp = CreateCompatibleBitmap(screen, desiredCapSize, desiredCapSize);
        SelectObject(g_capDC, g_capBmp);
        ReleaseDC(NULL, screen);
        g_capSize = desiredCapSize;
    }
}

static void apply_circle_alpha_mask(void) {
    uint8_t* px = (uint8_t*)g_bits; // BGRA
    int r2 = kRadius * kRadius;
    int cx = kRadius;
    int cy = kRadius;

    for (int y = 0; y < kDiameter; y++) {
        for (int x = 0; x < kDiameter; x++) {
            int dx = x - cx;
            int dy = y - cy;
            int d2 = dx*dx + dy*dy;
            uint8_t* p = px + (y * kDiameter + x) * 4;
            if (d2 <= r2) {
                p[3] = 255;
            } else {
                p[0] = 0; p[1] = 0; p[2] = 0; p[3] = 0;
            }
        }
    }
}

static void draw_overlay_frame(void) {
    ensure_resources();

    POINT cur;
    GetCursorPos(&cur);

    // Capture source square around cursor
    int capSize = g_capSize;
    int half = capSize / 2;

    HDC screen = GetDC(NULL);
    BitBlt(g_capDC, 0, 0, capSize, capSize, screen, cur.x - half, cur.y - half, SRCCOPY);
    ReleaseDC(NULL, screen);

    // Clear memory buffer
    memset(g_bits, 0, kDiameter * kDiameter * 4);

    // Draw magnified capture into DIB
    SetStretchBltMode(g_memDC, COLORONCOLOR);
    StretchBlt(g_memDC, 0, 0, kDiameter, kDiameter, g_capDC, 0, 0, capSize, capSize, SRCCOPY);

    // Apply circle alpha after StretchBlt (GDI doesn't set alpha)
    apply_circle_alpha_mask();

    // Draw circle border (will affect RGB, alpha already 255 in circle)
    HPEN pen = CreatePen(PS_SOLID, kBorderWidth, RGB(255, 255, 255));
    HGDIOBJ oldPen = SelectObject(g_memDC, pen);
    HGDIOBJ oldBrush = SelectObject(g_memDC, GetStockObject(HOLLOW_BRUSH));

    int inset = kBorderWidth / 2;
    Ellipse(g_memDC, inset, inset, kDiameter - inset, kDiameter - inset);

    // Draw center marker (small square)
    int m = 6;
    int cx = kRadius;
    int cy = kRadius;
    Rectangle(g_memDC, cx - m/2, cy - m/2, cx + m/2, cy + m/2);

    SelectObject(g_memDC, oldBrush);
    SelectObject(g_memDC, oldPen);
    DeleteObject(pen);

    // Position window near cursor
    POINT desired = { cur.x + kOffsetX, cur.y + kOffsetY };
    RECT wr = clamp_to_monitor(desired, kDiameter, kDiameter);

    SIZE sizeWnd = { kDiameter, kDiameter };
    POINT ptSrc = { 0, 0 };
    POINT ptDst = { wr.left, wr.top };

    BLENDFUNCTION bf;
    bf.BlendOp = AC_SRC_OVER;
    bf.BlendFlags = 0;
    bf.SourceConstantAlpha = 255;
    bf.AlphaFormat = AC_SRC_ALPHA;

    HDC screenDC = GetDC(NULL);
    UpdateLayeredWindow(g_hwnd, screenDC, &ptDst, &sizeWnd, g_memDC, &ptSrc, 0, &bf, ULW_ALPHA);
    ReleaseDC(NULL, screenDC);
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
        case WM_CREATE:
            SetTimer(hwnd, 1, kTickMs, NULL);
            return 0;
        case WM_TIMER:
            draw_overlay_frame();
            return 0;
        case WM_DESTROY:
            KillTimer(hwnd, 1);
            PostQuitMessage(0);
            return 0;
        default:
            return DefWindowProc(hwnd, msg, wParam, lParam);
    }
}

int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE hPrev, PWSTR lpCmdLine, int nCmdShow) {
    (void)hPrev; (void)lpCmdLine; (void)nCmdShow;
    g_hInstance = hInstance;

    enable_dpi_awareness();

    const wchar_t* kClass = L"MinimalColorPickerOverlay";
    WNDCLASSEXW wc;
    ZeroMemory(&wc, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.hInstance = hInstance;
    wc.lpfnWndProc = WndProc;
    wc.lpszClassName = kClass;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    RegisterClassExW(&wc);

    DWORD exStyle = WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT;
    DWORD style = WS_POPUP;

    g_hwnd = CreateWindowExW(
        exStyle,
        kClass,
        L"",
        style,
        0, 0, kDiameter, kDiameter,
        NULL, NULL, hInstance, NULL
    );

    if (!g_hwnd) return 1;

    ShowWindow(g_hwnd, SW_SHOW);
    UpdateWindow(g_hwnd);

    g_mouseHook = SetWindowsHookExW(WH_MOUSE_LL, LowLevelMouseProc, hInstance, 0);
    g_keyboardHook = SetWindowsHookExW(WH_KEYBOARD_LL, LowLevelKeyboardProc, hInstance, 0);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    if (g_keyboardHook) UnhookWindowsHookEx(g_keyboardHook);
    if (g_mouseHook) UnhookWindowsHookEx(g_mouseHook);

    if (g_capBmp) { DeleteObject(g_capBmp); g_capBmp = NULL; }
    if (g_capDC) { DeleteDC(g_capDC); g_capDC = NULL; }

    if (g_dib) { DeleteObject(g_dib); g_dib = NULL; }
    if (g_memDC) { DeleteDC(g_memDC); g_memDC = NULL; }

    return 0;
}
