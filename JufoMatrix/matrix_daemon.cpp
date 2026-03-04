// ============================================================
//  matrix_daemon.cpp  ·  JUFO-BIKE  ·  Raspberry Pi 3 B+
//
//  Reads W-codes from the ESP32 over USB-Serial and renders
//  the corresponding warning on the 64 × 64 RGB LED matrix.
//
//  Usage (built by Makefile):
//    sudo ./matrix_daemon [--led-no-hardware-pulse --led-brightness=50
//                          --led-cols=64 --led-rows=64 --led-slowdown-gpio=10]
//
//  The rpi-rgb-led-matrix flags can be passed directly; see
//  led-matrix.h for the full list.
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

#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>


// POSIX serial
#include <fcntl.h>
#include <termios.h>
#include <unistd.h>

// rpi-rgb-led-matrix
#include "graphics.h"
#include "led-matrix.h"


using namespace rgb_matrix;

// ── Configuration ─────────────────────────────────────────────

static constexpr int MATRIX_WIDTH = 64;
static constexpr int MATRIX_HEIGHT = 64;

// Font path (relative to daemon working directory, or use absolute path)
static constexpr const char *FONT_PATH =
    "../rpi-rgb-led-matrix-master/fonts/6x10.bdf";

// ── Colors ────────────────────────────────────────────────────
static const Color COLOR_BG(0, 0, 0);            // Black background
static const Color COLOR_TEXT(255, 180, 0);      // Amber text
static const Color COLOR_ICON(255, 0, 0);        // Red icon border
static const Color COLOR_ICON_FG(255, 255, 255); // White icon glyph

// ── Global matrix state ───────────────────────────────────────
static RGBMatrix *g_matrix = nullptr;
static OffscreenCanvas *g_canvas = nullptr;
static Font g_font;
static volatile bool g_running = true;

// ── Signal handler ────────────────────────────────────────────
static void onSignal(int) { g_running = false; }

// ── Serial port helpers ───────────────────────────────────────

/**
 * Open and configure a serial port at 115200 8N1.
 * Returns file descriptor, or -1 on failure.
 */
static int openSerial(const char *path) {
  int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
  if (fd < 0)
    return -1;

  struct termios tty{};
  if (tcgetattr(fd, &tty) != 0) {
    close(fd);
    return -1;
  }

  cfsetispeed(&tty, B115200);
  cfsetospeed(&tty, B115200);

  tty.c_cflag = (tty.c_cflag & ~CSIZE) | CS8; // 8 data bits
  tty.c_cflag |= CLOCAL | CREAD;              // enable receiver
  tty.c_cflag &= ~(PARENB | PARODD);          // no parity
  tty.c_cflag &= ~CSTOPB;                     // 1 stop bit
  tty.c_cflag &= ~CRTSCTS;                    // no hardware flow ctrl

  tty.c_lflag = 0; // raw mode
  tty.c_iflag = 0;
  tty.c_oflag = 0;

  // Non-blocking reads
  tty.c_cc[VMIN] = 0;
  tty.c_cc[VTIME] = 0;

  if (tcsetattr(fd, TCSANOW, &tty) != 0) {
    close(fd);
    return -1;
  }
  tcflush(fd, TCIOFLUSH);
  return fd;
}

/** Try the two common port names; return fd or -1. */
static int autoDetectSerial() {
  const char *envPort = getenv("MATRIX_SERIAL_PORT");
  if (envPort) {
    int fd = openSerial(envPort);
    if (fd >= 0) {
      fprintf(stderr, "[Serial] opened %s\n", envPort);
      return fd;
    }
    fprintf(stderr, "[Serial] cannot open %s: %s\n", envPort, strerror(errno));
    return -1;
  }
  for (const char *path : {"/dev/ttyUSB0", "/dev/ttyACM0"}) {
    int fd = openSerial(path);
    if (fd >= 0) {
      fprintf(stderr, "[Serial] opened %s\n", path);
      return fd;
    }
  }
  fprintf(stderr, "[Serial] no port found – set MATRIX_SERIAL_PORT\n");
  return -1;
}

// ── Text rendering helpers ────────────────────────────────────

/** Draw a centered UTF-8 string; returns y-advance (font height + 1 px gap). */
static int drawCenteredLine(OffscreenCanvas *c, const Font &font,
                            const char *text, int y) {
  // Measure pixel width of the string
  int width = 0;
  for (const char *p = text; *p;) {
    // Decode one UTF-8 codepoint
    uint32_t cp = static_cast<uint8_t>(*p);
    if (cp < 0x80) {
      ++p;
    } else if ((cp & 0xE0) == 0xC0) {
      cp = ((cp & 0x1F) << 6) | (static_cast<uint8_t>(p[1]) & 0x3F);
      p += 2;
    } else {
      cp = 0x20;
      ++p;
    } // simplification: replace non-BMP chars
    int cw = font.CharacterWidth(cp);
    if (cw > 0)
      width += cw;
  }
  int x = (MATRIX_WIDTH - width) / 2;
  if (x < 0)
    x = 0;
  DrawText(c, font, x, y + font.baseline(), COLOR_TEXT, &COLOR_BG, text);
  return font.height() + 1;
}

// ── Warning icon (procedural "!" in a circle) ─────────────────

/**
 * Draw a circular warning icon centered at (cx, cy) with outer radius r.
 *   - Red circle border (2 px thick via two concentric DrawCircle calls)
 *   - White "!" glyph inside
 */
static void drawWarningIcon(OffscreenCanvas *c, int cx, int cy, int r) {
  // Outer ring (2 px thick)
  DrawCircle(c, cx, cy, r, COLOR_ICON);
  DrawCircle(c, cx, cy, r - 1, COLOR_ICON);

  // "!" exclamation mark
  int stemTop = cy - r / 2;
  int stemBottom = cy + r / 4;
  int dotY = cy + r / 2 - 1;

  // Stem (2 px wide for visibility)
  DrawLine(c, cx, stemTop, cx, stemBottom, COLOR_ICON_FG);
  DrawLine(c, cx + 1, stemTop, cx + 1, stemBottom, COLOR_ICON_FG);

  // Dot
  c->SetPixel(cx, dotY, 255, 255, 255);
  c->SetPixel(cx + 1, dotY, 255, 255, 255);
}

// ── Screen renderers ─────────────────────────────────────────

static void renderClear(OffscreenCanvas *c) { c->Fill(0, 0, 0); }

/**
 * Case 1: Car overtakes too closely
 * Text: "Überholabstand beachten" (3 lines), icon below (r=9)
 */
static void renderOvertaking(OffscreenCanvas *c) {
  c->Fill(0, 0, 0);
  int y = 6;
  y += drawCenteredLine(c, g_font, "Überholabs-", y);
  y += drawCenteredLine(c, g_font, "tand", y);
  y += drawCenteredLine(c, g_font, "beachten", y);
  y += 3; // gap before icon

  // Icon centered horizontally, centered in remaining vertical space
  int remaining = MATRIX_HEIGHT - y;
  int iconCy = y + remaining / 2;
  int iconR = (remaining / 2) - 2;
  if (iconR > 10)
    iconR = 10; // cap so it stays in bounds
  if (iconR < 5)
    iconR = 5;
  drawWarningIcon(c, MATRIX_WIDTH / 2, iconCy, iconR);
}

/**
 * Case 2: Car is following too closely
 * Text: "Abstand halten" (2 lines), larger icon below (r=12)
 */
static void renderTailgating(OffscreenCanvas *c) {
  c->Fill(0, 0, 0);
  int y = 4;
  y += drawCenteredLine(c, g_font, "Abstand", y);
  y += drawCenteredLine(c, g_font, "halten", y);
  y += 3;

  int remaining = MATRIX_HEIGHT - y;
  int iconCy = y + remaining / 2;
  int iconR = (remaining / 2) - 2;
  if (iconR > 13)
    iconR = 13;
  if (iconR < 5)
    iconR = 5;
  drawWarningIcon(c, MATRIX_WIDTH / 2, iconCy, iconR);
}

// ── Message parser ────────────────────────────────────────────

/**
 * Parse a line received from the ESP32.
 * Returns the warning code (0-9) or -1 if the line is not a valid W-message.
 */
static int parseLine(const char *line, int len) {
  if (len < 2)
    return -1;
  if (line[0] != 'W')
    return -1;
  if (line[1] < '0' || line[1] > '9')
    return -1;
  return line[1] - '0';
}

// ── Application rendering dispatch ────────────────────────────

static void applyWarning(int code) {
  switch (code) {
  case 0:
    renderClear(g_canvas);
    break;
  case 1:
    renderOvertaking(g_canvas);
    break;
  case 2:
    renderTailgating(g_canvas);
    break;
  default:
    fprintf(stderr, "[Matrix] unknown code W%d – ignoring\n", code);
    return;
  }
  g_canvas = g_matrix->SwapOnVSync(g_canvas);
  fprintf(stderr, "[Matrix] displayed W%d\n", code);
}

// ── Main ──────────────────────────────────────────────────────

int main(int argc, char **argv) {
  // ── Matrix initialization ──────────────────────────────────
  RGBMatrix::Options matrixOpts;
  matrixOpts.cols = MATRIX_WIDTH;
  matrixOpts.rows = MATRIX_HEIGHT;
  matrixOpts.brightness = 50;
  matrixOpts.disable_hardware_pulsing = true;
  matrixOpts.gpio_slowdown = 10;

  rgb_matrix::RuntimeOptions runtimeOpts;
  // Parse any extra flags passed on the command line (e.g. --led-chain=2)
  // ParseOptionsFromFlags modifies argc/argv in place.
  if (!rgb_matrix::ParseOptionsFromFlags(&argc, &argv, &matrixOpts,
                                         &runtimeOpts)) {
    fprintf(stderr, "[Matrix] invalid flags\n");
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
  fprintf(stderr, "[Matrix] font loaded: %s (h=%d)\n", FONT_PATH,
          g_font.height());

  // ── Signal handlers ────────────────────────────────────────
  signal(SIGINT, onSignal);
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
  if (!g_running) {
    delete g_matrix;
    return 0;
  }

  // ── Show idle (black) on startup ───────────────────────────
  applyWarning(0);

  // ── Main read loop ─────────────────────────────────────────
  fprintf(stderr, "[Main] entering read loop\n");

  char lineBuf[64];
  int lineLen = 0;

  while (g_running) {
    char ch;
    ssize_t n = read(serialFd, &ch, 1);
    if (n < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        usleep(5000); // 5 ms back-off when nothing available
        continue;
      }
      // Real read error – port likely disconnected
      fprintf(stderr, "[Serial] read error: %s – reconnecting\n",
              strerror(errno));
      close(serialFd);
      serialFd = -1;
      // Try to reconnect
      while (g_running && serialFd < 0) {
        sleep(2);
        serialFd = autoDetectSerial();
      }
      continue;
    }
    if (n == 0) {
      usleep(5000);
      continue;
    }

    // Accumulate until newline
    if (ch == '\r')
      continue; // ignore CR in case of CRLF
    if (ch == '\n') {
      lineBuf[lineLen] = '\0';
      int code = parseLine(lineBuf, lineLen);
      if (code >= 0)
        applyWarning(code);
      else if (lineLen > 0) // debug output from ESP32 – just log it
        fprintf(stderr, "[ESP32] %s\n", lineBuf);
      lineLen = 0;
    } else if (lineLen < static_cast<int>(sizeof(lineBuf) - 1)) {
      lineBuf[lineLen++] = ch;
    }
  }

  // ── Cleanup ────────────────────────────────────────────────
  if (serialFd >= 0)
    close(serialFd);
  renderClear(g_canvas);
  g_canvas = g_matrix->SwapOnVSync(g_canvas);
  delete g_matrix;

  fprintf(stderr, "[Main] exiting cleanly\n");
  return 0;
}
