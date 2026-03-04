// ============================================================
//  matrix_daemon.cpp  ·  JUFO-BIKE  ·  Raspberry Pi 3 B+
//
//  Reads W-codes from the ESP32 over USB-Serial and renders
//  the corresponding warning on the 64 × 64 RGB LED matrix.
//
//  Usage (built by Makefile):
//    sudo ./matrix_daemon
//
//  Extra rpi-rgb-led-matrix flags can be appended:
//    sudo ./matrix_daemon --led-chain=2
//
//  Serial port auto-detection:
//    Tries /dev/ttyUSB0 first, then /dev/ttyACM0.
//    Override with environment variable MATRIX_SERIAL_PORT.
//
//  Protocol received from ESP32:
//    W0\n  – clear display
//    W1\n  – "Überholabstand beachten" + warning icon
//    W2\n  – "Abstand halten"          + warning icon
// ============================================================

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <cerrno>

// POSIX serial
#include <fcntl.h>
#include <termios.h>
#include <unistd.h>

// rpi-rgb-led-matrix  (FrameCanvas is the correct off-screen buffer type)
#include "led-matrix.h"
#include "graphics.h"

using namespace rgb_matrix;

// ── Configuration ─────────────────────────────────────────────

static constexpr int MATRIX_WIDTH  = 64;
static constexpr int MATRIX_HEIGHT = 64;

// Font path relative to the JufoMatrix working directory
static constexpr const char *FONT_PATH =
    "../rpi-rgb-led-matrix-master/fonts/6x10.bdf";

// ── Colors ────────────────────────────────────────────────────
static const Color COLOR_BG     (  0,   0,   0);   // Black background
static const Color COLOR_TEXT   (255, 180,   0);   // Amber text
static const Color COLOR_ICON   (255,   0,   0);   // Red icon border
static const Color COLOR_ICON_FG(255, 255, 255);   // White icon glyph

// ── Global matrix state ───────────────────────────────────────
static RGBMatrix    *g_matrix  = nullptr;
static FrameCanvas  *g_canvas  = nullptr;   // NOTE: FrameCanvas, not OffscreenCanvas
static Font          g_font;
static volatile bool g_running = true;

// ── Signal handler ────────────────────────────────────────────
static void onSignal(int) {
    g_running = false;
}

// ── Serial port helpers ───────────────────────────────────────

/** Open and configure a serial port at 115200 8N1. Returns fd or -1. */
static int openSerial(const char *path) {
    int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) return -1;

    struct termios tty {};
    if (tcgetattr(fd, &tty) != 0) { close(fd); return -1; }

    cfsetispeed(&tty, B115200);
    cfsetospeed(&tty, B115200);

    tty.c_cflag  = (tty.c_cflag & ~CSIZE) | CS8;
    tty.c_cflag |= CLOCAL | CREAD;
    tty.c_cflag &= ~(PARENB | PARODD);
    tty.c_cflag &= ~CSTOPB;
    tty.c_cflag &= ~CRTSCTS;
    tty.c_lflag  = 0;
    tty.c_iflag  = 0;
    tty.c_oflag  = 0;
    tty.c_cc[VMIN]  = 0;
    tty.c_cc[VTIME] = 0;

    if (tcsetattr(fd, TCSANOW, &tty) != 0) { close(fd); return -1; }
    tcflush(fd, TCIOFLUSH);
    return fd;
}

/** Try the two common port names (or MATRIX_SERIAL_PORT env). Returns fd or -1. */
static int autoDetectSerial() {
    const char *envPort = getenv("MATRIX_SERIAL_PORT");
    if (envPort) {
        int fd = openSerial(envPort);
        if (fd >= 0) { fprintf(stderr, "[Serial] opened %s\n", envPort); return fd; }
        fprintf(stderr, "[Serial] cannot open %s: %s\n", envPort, strerror(errno));
        return -1;
    }
    for (const char *path : {"/dev/ttyUSB0", "/dev/ttyACM0"}) {
        int fd = openSerial(path);
        if (fd >= 0) { fprintf(stderr, "[Serial] opened %s\n", path); return fd; }
    }
    fprintf(stderr, "[Serial] no port found – set MATRIX_SERIAL_PORT\n");
    return -1;
}

// ── Text rendering helpers ────────────────────────────────────

/** Measure pixel width of a UTF-8 string with the loaded font. */
static int textWidth(const char *text) {
    int width = 0;
    for (const char *p = text; *p; ) {
        uint32_t cp = static_cast<uint8_t>(*p);
        if (cp < 0x80) {
            ++p;
        } else if ((cp & 0xE0) == 0xC0) {
            cp = ((cp & 0x1F) << 6) | (static_cast<uint8_t>(p[1]) & 0x3F);
            p += 2;
        } else {
            cp = 0x20;   // fallback for multi-byte sequences beyond BMP
            ++p;
        }
        int cw = g_font.CharacterWidth(cp);
        if (cw > 0) width += cw;
    }
    return width;
}

/**
 * Draw a centered UTF-8 string at row y.
 * Returns the font height + 1 px gap (vertical advance).
 */
static int drawCenteredLine(FrameCanvas *c, const char *text, int y) {
    int w = textWidth(text);
    int x = (MATRIX_WIDTH - w) / 2;
    if (x < 0) x = 0;
    DrawText(c, g_font, x, y + g_font.baseline(), COLOR_TEXT, &COLOR_BG, text);
    return g_font.height() + 1;
}

// ── Warning icon ──────────────────────────────────────────────

/**
 * Draw a circular warning icon (red ring + white "!") centered at (cx, cy).
 * r = outer radius in pixels.
 */
static void drawWarningIcon(FrameCanvas *c, int cx, int cy, int r) {
    // 2 px thick red ring
    DrawCircle(c, cx, cy, r,     COLOR_ICON);
    DrawCircle(c, cx, cy, r - 1, COLOR_ICON);

    // White "!" – stem
    int stemTop    = cy - r / 2;
    int stemBottom = cy + r / 4;
    int dotY       = cy + r / 2 - 1;

    DrawLine(c, cx,     stemTop, cx,     stemBottom, COLOR_ICON_FG);
    DrawLine(c, cx + 1, stemTop, cx + 1, stemBottom, COLOR_ICON_FG);

    // White "!" – dot (2 px wide)
    c->SetPixel(cx,     dotY, 255, 255, 255);
    c->SetPixel(cx + 1, dotY, 255, 255, 255);
}

// ── Screen renderers ─────────────────────────────────────────

static void renderClear(FrameCanvas *c) {
    c->Fill(0, 0, 0);
}

/** Case 1: Overtaking – 3 text lines + small icon */
static void renderOvertaking(FrameCanvas *c) {
    c->Fill(0, 0, 0);
    int y = 6;
    y += drawCenteredLine(c, "Überholabs-", y);
    y += drawCenteredLine(c, "tand",        y);
    y += drawCenteredLine(c, "beachten",    y);
    y += 3;

    int remaining = MATRIX_HEIGHT - y;
    int iconCy    = y + remaining / 2;
    int iconR     = (remaining / 2) - 2;
    if (iconR > 10) iconR = 10;
    if (iconR <  5) iconR =  5;
    drawWarningIcon(c, MATRIX_WIDTH / 2, iconCy, iconR);
}

/** Case 2: Tailgating – 2 text lines + larger icon */
static void renderTailgating(FrameCanvas *c) {
    c->Fill(0, 0, 0);
    int y = 4;
    y += drawCenteredLine(c, "Abstand", y);
    y += drawCenteredLine(c, "halten",  y);
    y += 3;

    int remaining = MATRIX_HEIGHT - y;
    int iconCy    = y + remaining / 2;
    int iconR     = (remaining / 2) - 2;
    if (iconR > 13) iconR = 13;
    if (iconR <  5) iconR =  5;
    drawWarningIcon(c, MATRIX_WIDTH / 2, iconCy, iconR);
}

// ── Message parser ────────────────────────────────────────────

/** Returns code 0-9 for a valid "W<digit>" prefix, or -1 for anything else. */
static int parseLine(const char *line, int len) {
    if (len < 2)         return -1;
    if (line[0] != 'W')  return -1;
    if (line[1] < '0' || line[1] > '9') return -1;
    return line[1] - '0';
}

// ── Dispatch ─────────────────────────────────────────────────

static void applyWarning(int code) {
    switch (code) {
        case 0: renderClear(g_canvas);      break;
        case 1: renderOvertaking(g_canvas); break;
        case 2: renderTailgating(g_canvas); break;
        default:
            fprintf(stderr, "[Matrix] unknown code W%d – ignoring\n", code);
            return;
    }
    g_canvas = g_matrix->SwapOnVSync(g_canvas);
    fprintf(stderr, "[Matrix] displayed W%d\n", code);
}

// ── Main ──────────────────────────────────────────────────────

int main(int argc, char **argv) {
    // ── Matrix options ─────────────────────────────────────────
    RGBMatrix::Options matrixOpts;
    matrixOpts.cols                    = MATRIX_WIDTH;
    matrixOpts.rows                    = MATRIX_HEIGHT;
    matrixOpts.brightness              = 50;
    matrixOpts.disable_hardware_pulsing = true;   // --led-no-hardware-pulse

    // gpio_slowdown lives in RuntimeOptions, not in RGBMatrix::Options
    RuntimeOptions runtimeOpts;
    runtimeOpts.gpio_slowdown = 10;               // --led-slowdown-gpio=10

    // Let the library parse any extra command-line flags (e.g. --led-chain=2)
    if (!ParseOptionsFromFlags(&argc, &argv, &matrixOpts, &runtimeOpts)) {
        PrintMatrixFlags(stderr);
        return 1;
    }

    g_matrix = RGBMatrix::CreateFromOptions(matrixOpts, runtimeOpts);
    if (!g_matrix) {
        fprintf(stderr, "[Matrix] failed to create RGBMatrix\n");
        return 1;
    }
    g_canvas = g_matrix->CreateFrameCanvas();

    // ── Font loading ───────────────────────────────────────────
    if (!g_font.LoadFont(FONT_PATH)) {
        fprintf(stderr, "[Matrix] could not load font: %s\n", FONT_PATH);
        delete g_matrix;
        return 1;
    }
    fprintf(stderr, "[Matrix] font loaded (%s, h=%d)\n", FONT_PATH, g_font.height());

    // ── Signals ────────────────────────────────────────────────
    signal(SIGINT,  onSignal);
    signal(SIGTERM, onSignal);

    // ── Serial port ────────────────────────────────────────────
    int serialFd = -1;
    while (g_running && serialFd < 0) {
        serialFd = autoDetectSerial();
        if (serialFd < 0) {
            fprintf(stderr, "[Serial] retrying in 3 s …\n");
            sleep(3);
        }
    }
    if (!g_running) { delete g_matrix; return 0; }

    // Start with a clear (black) display
    applyWarning(0);

    // ── Read loop ─────────────────────────────────────────────
    fprintf(stderr, "[Main] entering read loop\n");

    char lineBuf[64];
    int  lineLen = 0;

    while (g_running) {
        char   ch;
        ssize_t n = read(serialFd, &ch, 1);

        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                usleep(5000);
                continue;
            }
            fprintf(stderr, "[Serial] read error: %s – reconnecting\n", strerror(errno));
            close(serialFd);
            serialFd = -1;
            while (g_running && serialFd < 0) {
                sleep(2);
                serialFd = autoDetectSerial();
            }
            continue;
        }
        if (n == 0) { usleep(5000); continue; }

        if (ch == '\r') continue;   // skip CR in CRLF
        if (ch == '\n') {
            lineBuf[lineLen] = '\0';
            int code = parseLine(lineBuf, lineLen);
            if (code >= 0)
                applyWarning(code);
            else if (lineLen > 0)
                fprintf(stderr, "[ESP32] %s\n", lineBuf);   // pass-through debug
            lineLen = 0;
        } else if (lineLen < static_cast<int>(sizeof(lineBuf) - 1)) {
            lineBuf[lineLen++] = ch;
        }
    }

    // ── Cleanup ────────────────────────────────────────────────
    if (serialFd >= 0) close(serialFd);
    renderClear(g_canvas);
    g_matrix->SwapOnVSync(g_canvas);
    delete g_matrix;

    fprintf(stderr, "[Main] exiting cleanly\n");
    return 0;
}
