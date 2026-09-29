# Smart Accident Alert System — developer tasks.
#
# Every target is runnable on Linux and macOS with a stock toolchain, and each
# one fails with an explanation rather than a cryptic shell error when its tool
# is missing. `make help` is the index.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Paths. `APP` is the Flutter project; `FIRMWARE` is the Arduino sketch.
APP      := app
FIRMWARE := firmware/SmartAccidentAlert
# Host-side unit tests. Deliberately outside $(FIRMWARE): the Arduino build
# compiles every .cpp in the sketch directory, so a test with a main() next to
# the .ino ends up linked into the firmware.
FWTEST   := firmware/test
TOOLS    := tools/protocol
BACKEND  := backend

# The BLE port the ESP32 node advertises on. Override per-board:
#   make firmware-upload PORT=/dev/ttyUSB0
PORT ?= /dev/ttyUSB0

# CI-style board/port. The sketch is a plain Arduino project, so `arduino-cli`
# needs the FQBN and library list.
FQBN ?= esp32:esp32:esp32

# Deterministic version stamp, so a build is traceable to a source commit.
FW_VERSION ?= 1.0.0
BUILD_DATE  = $(shell date -u +%Y%m%d)

# Scratch output for the host test binaries. Kept out of the source directories on
# purpose: the firmware tree is an Arduino sketch, and a stray .cpp with a main()
# in it would be compiled into the firmware by the IDE.
BUILD ?= build

BLUE := \033[0;34m
GREEN := \033[0;32m
YELLOW := \033[0;33m
RED := \033[0;31m
NC := \033[0m

## ── helpers ──────────────────────────────────────────────────────────────────

# require <command> <hint>
# Prints a usable error and exits 1 when a tool is missing, instead of letting
# the shell report "command not found" halfway through a long command.
define require
	@command -v $(1) >/dev/null 2>&1 || { \
		printf "$(RED)error:$(NC) '$(1)' is not installed.\n"; \
		printf "       $(2)\n"; \
		exit 1; \
	}
endef

## ── meta ─────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@printf "$(BLUE)Smart Accident Alert System$(NC)\n\n"
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@printf "\n$(YELLOW)Prototype warning:$(NC) not a certified emergency system. See PROJECT_PLAN.md §27.\n"

.PHONY: doctor
doctor: ## Check which required tools are present
	@printf "$(BLUE)Toolchain$(NC)\n"
	@for t in node npm dart flutter arduino-cli; do \
		if command -v $$t >/dev/null 2>&1; then \
			printf "  $(GREEN)ok$(NC)      %-14s %s\n" "$$t" "$$($$t --version 2>&1 | head -1)"; \
		else \
			printf "  $(YELLOW)missing$(NC) %-14s\n" "$$t"; \
		fi; \
	done
	@printf "\n$(BLUE)Optional$(NC)\n"
	@for t in platformio pio java; do \
		command -v $$t >/dev/null 2>&1 \
			&& printf "  $(GREEN)ok$(NC)      %-14s %s\n" "$$t" "$$($$t --version 2>&1 | head -1)" \
			|| printf "  $(YELLOW)missing$(NC) %-14s\n" "$$t"; \
	done

## ── protocol (the contract shared by firmware, app and tools) ────────────────

.PHONY: golden
golden: ## Regenerate the protocol conformance vectors
	@$(call require,node,"Install Node 18+ from https://nodejs.org")
	cd $(TOOLS) && node generate-golden.mjs
	@printf "$(GREEN)golden.json regenerated.$(NC) Commit it if the protocol changed.\n"

.PHONY: test-protocol
test-protocol: ## Run the protocol conformance suite
	@$(call require,node,"Install Node 18+ from https://nodejs.org")
	cd $(TOOLS) && node --test 'test/*.mjs'

## Host tests for the firmware logic that has no Arduino dependency. These are
## the tests that can reach the fault paths: a detached sensor and a bus that
## froze mid-shake are not reproducible by shaking a node on a desk.
HOST_TEST_BIN := $(BUILD)/host
.PHONY: test-firmware-host
test-firmware-host: ## Compile and run the firmware's host-side unit tests
	@$(call require,g++,"Install a C++17 compiler")
	@mkdir -p $(HOST_TEST_BIN)
	$(CXX) -std=c++17 -Wall -Wextra -Werror -I$(FIRMWARE) \
		-o $(HOST_TEST_BIN)/demomode \
		$(FIRMWARE)/demomode.cpp $(FWTEST)/demomode_test.cpp
	@$(HOST_TEST_BIN)/demomode
	@echo
	# The accelerometer conversion needs json.cpp for two of its symbols, so the
	# test links the same trio the firmware does.
	$(CXX) -std=c++17 -Wall -Wextra -Werror -I$(FIRMWARE) \
		-o $(HOST_TEST_BIN)/scale \
		$(FIRMWARE)/sensors.cpp $(FIRMWARE)/json.cpp $(FIRMWARE)/protocol.cpp \
		$(FWTEST)/scale_test.cpp
	@$(HOST_TEST_BIN)/scale
	@echo
	# power.cpp guards its ESP.restart() behind #if defined(ARDUINO), so the
	# host build gets the decision logic without the side effect.
	$(CXX) -std=c++17 -Wall -Wextra -Werror -I$(FIRMWARE) \
		-o $(HOST_TEST_BIN)/watchdog \
		$(FIRMWARE)/power.cpp $(FWTEST)/watchdog_test.cpp
	@$(HOST_TEST_BIN)/watchdog
	@echo
	$(CXX) -std=c++17 -Wall -Wextra -Werror -I$(FIRMWARE) \
		-o $(HOST_TEST_BIN)/sensordiag \
		$(FIRMWARE)/sensordiag.cpp $(FWTEST)/sensordiag_test.cpp
	@$(HOST_TEST_BIN)/sensordiag

## ── tests ────────────────────────────────────────────────────────────────────

.PHONY: test
test: test-protocol test-firmware-host test-app ## Run every automated test

.PHONY: test-app
test-app: ## Run the Flutter unit + widget tests
	@$(call require,flutter,"See https://docs.flutter.dev/get-started/install")
	cd $(APP) && flutter test

.PHONY: test-coverage
test-coverage: ## Run the app tests with coverage
	@$(call require,flutter,"See https://docs.flutter.dev/get-started/install")
	cd $(APP) && flutter test --coverage
	@command -v genhtml >/dev/null 2>&1 \
		&& genhtml -o $(APP)/coverage/html $(APP)/coverage/lcov.info \
		|| printf "$(YELLOW)lcov is at$(NC) $(APP)/coverage/lcov.info\n"

## ── static analysis ──────────────────────────────────────────────────────────

.PHONY: lint
lint: lint-app ## Run all linters

.PHONY: lint-app
lint-app: ## Analyse and format-check the Flutter app
	@$(call require,dart,"Install the Dart SDK, or use the Flutter SDK's dart")
	cd $(APP) && dart analyze --fatal-warnings
	cd $(APP) && dart format --output=none --set-exit-if-changed lib test

.PHONY: format
format: ## Auto-format the app
	cd $(APP) && dart format lib test

## ── firmware ─────────────────────────────────────────────────────────────────

# The sketch is a plain Arduino project, so `arduino-cli` needs the FQBN plus an
# explicit library list. The motion sensor is an ADXL345; the MPU6050 and its
# Unified Sensor dependency were removed with the gyro path.
ARDUINO_LIBS = \
	--library "NimBLE-Arduino" \
	--library "Adafruit SSD1306" \
	--library "Adafruit GFX Library" \
	--library "Adafruit BusIO" \
	--library "Adafruit ADXL345" \
	--library "Adafruit Unified Sensor"

.PHONY: firmware
firmware: ## Compile the ESP32 sketch (no upload)
	@$(call require,arduino-cli,"curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | sh")
	@printf "$(BLUE)Compiling$(NC) $(FIRMWARE)\n"
# The ESP32 macro is defined here as well as by the core. arduino-esp32 puts
# -DESP32=ESP32 in `build.extra_flags`, which reaches the sketch but NOT the
# libraries, and several Adafruit libraries (SSD1306 2.5.17 among them) guard
# their platform includes on that macro. Without it they fall through to an
# AVR-only branch and fail on <util/delay.h>. The Arduino IDE does pass it, which
# is why this only ever bites on the command line.
	arduino-cli compile --fqbn $(FQBN) $(ARDUINO_LIBS) \
		--build-property "build.extra_flags=-D ESP32=ESP32 -D SAAS_FW_VERSION='\"$(FW_VERSION)\"' -D SAAS_FW_BUILD=$(BUILD_DATE)" \
		$(FIRMWARE)

.PHONY: firmware-upload
firmware-upload: firmware ## Compile and flash the node over USB
	arduino-cli upload --fqbn $(FQBN) --port $(PORT) $(FIRMWARE)
	@printf "$(GREEN)Flashed.$(NC) Open the serial monitor with: make monitor\n"

.PHONY: monitor
monitor: ## Open the serial monitor at 115200 baud
	@$(call require,arduino-cli,"Install arduino-cli")
	arduino-cli monitor --port $(PORT) --config baudrate=115200

.PHONY: firmware-pio
firmware-pio: ## Build the firmware with PlatformIO instead (alternative path)
	@$(call require,pio,"pip install platformio")
	pio run -d firmware

## ── app ──────────────────────────────────────────────────────────────────────

.PHONY: pub
pub: ## Fetch the app's Dart dependencies
	@$(call require,flutter,"See https://docs.flutter.dev/get-started/install")
	cd $(APP) && flutter pub get

.PHONY: app
app: ## Run the app on a connected device or emulator
	@$(call require,flutter,"See https://docs.flutter.dev/get-started/install")
	cd $(APP) && flutter run

.PHONY: app-demo
app-demo: ## Run the app with no hardware, using the built-in ESP32 simulator
	@$(call require,flutter,"See https://docs.flutter.dev/get-started/install")
	cd $(APP) && flutter run --dart-define=DEMO=true

.PHONY: app-build-apk
app-build-apk: ## Build a release APK (universal, ~60 MB)
	cd $(APP) && flutter build apk --release

.PHONY: app-build-apk-split
app-build-apk-split: ## Build per-ABI release APKs (~20 MB each)
	cd $(APP) && flutter build apk --release --split-per-abi

.PHONY: app-build-bundle
app-build-bundle: ## Build an App Bundle, which is what Play Store wants
	cd $(APP) && flutter build appbundle --release

.PHONY: app-build-ios
app-build-ios: ## Build a release iOS build (needs macOS + Xcode)
	cd $(APP) && flutter build ios --release --no-codesign

## ── backend ──────────────────────────────────────────────────────────────────

.PHONY: seed
seed: ## Regenerate the hospital seed dataset
	@$(call require,node,"Install Node 18+")
	node $(BACKEND)/seed/generate.mjs

.PHONY: backend-emu
backend-emu: ## Run the Firestore emulator with the project's rules
	@$(call require,firebase,"npm i -g firebase-tools")
	firebase emulators:start --only firestore,functions --project demo-saas

.PHONY: backend-deploy
backend-deploy: ## Deploy Firestore rules, indexes and functions
	@$(call require,firebase,"npm i -g firebase-tools")
	firebase deploy --only firestore:rules,firestore:indexes,functions

## ── housekeeping ─────────────────────────────────────────────────────────────

.PHONY: clean
clean: ## Remove build output
	rm -rf $(APP)/build $(APP)/.dart_tool $(APP)/coverage
	rm -rf firmware/.pio .pio build
	@printf "$(GREEN)Cleaned.$(NC)\n"

.PHONY: verify
verify: lint test ## What CI runs
	@printf "\n$(GREEN)All checks passed.$(NC)\n"
