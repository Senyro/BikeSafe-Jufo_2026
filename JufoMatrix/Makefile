# ============================================================
#  Makefile  ·  JUFO-BIKE LED Matrix Daemon
#  Raspberry Pi 3 B+
#
#  Prerequisites (run once on the Pi):
#    cd ../rpi-rgb-led-matrix-master && make -C lib
#
#  Build:     make
#  Install:   sudo make install
#  Uninstall: sudo make uninstall
# ============================================================

TARGET    := matrix_daemon
SRC       := matrix_daemon.cpp

# Path to the hzeller rpi-rgb-led-matrix library (relative to this Makefile)
RGB_LIB_DIR := ../rpi-rgb-led-matrix-master

INCLUDES  := -I$(RGB_LIB_DIR)/include
LIBS      := -L$(RGB_LIB_DIR)/lib -lrgbmatrix -lrt -lm -lpthread

CXX       := g++
CXXFLAGS  := -std=c++17 -O2 -Wall -Wextra $(INCLUDES)

# ── Default target ─────────────────────────────────────────────
all: $(TARGET)

$(TARGET): $(SRC)
	$(CXX) $(CXXFLAGS) -o $@ $^ $(LIBS)
	@echo "Build OK: $(TARGET)"

# ── Install as systemd service ─────────────────────────────────
INSTALL_DIR  := /usr/local/bin
SERVICE_NAME := jufo-matrix
SERVICE_FILE := /etc/systemd/system/$(SERVICE_NAME).service
DAEMON_PATH  := $(INSTALL_DIR)/$(TARGET)

install: $(TARGET)
	install -m 755 $(TARGET) $(INSTALL_DIR)/
	@echo "Installed $(DAEMON_PATH)"
	@echo "[Unit]"                                                     >  $(SERVICE_FILE)
	@echo "Description=JUFO-BIKE LED Matrix Daemon"                   >> $(SERVICE_FILE)
	@echo "After=network.target"                                       >> $(SERVICE_FILE)
	@echo ""                                                           >> $(SERVICE_FILE)
	@echo "[Service]"                                                  >> $(SERVICE_FILE)
	@echo "ExecStart=$(DAEMON_PATH)"                                   >> $(SERVICE_FILE)
	@echo "Restart=always"                                             >> $(SERVICE_FILE)
	@echo "RestartSec=3"                                               >> $(SERVICE_FILE)
	@echo "User=root"                                                  >> $(SERVICE_FILE)
	@echo ""                                                           >> $(SERVICE_FILE)
	@echo "[Install]"                                                  >> $(SERVICE_FILE)
	@echo "WantedBy=multi-user.target"                                 >> $(SERVICE_FILE)
	systemctl daemon-reload
	systemctl enable $(SERVICE_NAME)
	systemctl restart $(SERVICE_NAME)
	@echo "Service $(SERVICE_NAME) installed and started."

uninstall:
	-systemctl stop    $(SERVICE_NAME)
	-systemctl disable $(SERVICE_NAME)
	-rm -f $(SERVICE_FILE) $(DAEMON_PATH)
	systemctl daemon-reload
	@echo "Service $(SERVICE_NAME) removed."

clean:
	rm -f $(TARGET)

.PHONY: all install uninstall clean
