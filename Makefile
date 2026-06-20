# ClaudeTry — build, install to /Applications, and run at login.
#
# Common usage:
#   make            # build + install + enable autostart (the "just set it up" path)
#   make build      # Release build into ./build
#   make install     # copy the built .app into /Applications
#   make autostart  # register a LaunchAgent so it starts at login (and launch now)
#   make restart    # relaunch the installed app
#   make uninstall  # remove app + LaunchAgent
#   make clean      # delete local build artifacts

PROJECT      := ClaudeTry/ClaudeTry.xcodeproj
SCHEME       := ClaudeTry
APP_NAME     := ClaudeTry.app
CONFIG       := Release
BUILD_DIR    := build
APP_PATH     := $(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME)
INSTALL_DIR  := /Applications
INSTALLED_APP := $(INSTALL_DIR)/$(APP_NAME)

BUNDLE_ID    := zone.trash.ClaudeTry
LAUNCH_LABEL := $(BUNDLE_ID)
LAUNCH_AGENT := $(HOME)/Library/LaunchAgents/$(LAUNCH_LABEL).plist

.PHONY: all build install autostart setup restart uninstall clean

# Default: full setup in one shot.
all: setup

setup: install autostart
	@echo "✅ ClaudeTry installed to $(INSTALLED_APP) and set to launch at login."

build:
	@echo "🔨 Building $(SCHEME) ($(CONFIG))…"
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration $(CONFIG) \
		-derivedDataPath "$(BUILD_DIR)" \
		-destination 'platform=macOS' \
		CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
		build
	@echo "📦 Built: $(APP_PATH)"

install: build
	@echo "🚚 Installing to $(INSTALLED_APP)…"
	@# Stop any running copy so the bundle can be replaced cleanly.
	@osascript -e 'tell application id "$(BUNDLE_ID)" to quit' >/dev/null 2>&1 || true
	@pkill -f "$(INSTALLED_APP)" 2>/dev/null || true
	rm -rf "$(INSTALLED_APP)"
	cp -R "$(APP_PATH)" "$(INSTALL_DIR)/"
	@echo "✅ Installed."

autostart: $(LAUNCH_AGENT)
	@echo "🔁 Enabling launch-at-login…"
	@# Reload the agent so changes take effect and the app starts now.
	@launchctl unload "$(LAUNCH_AGENT)" 2>/dev/null || true
	launchctl load "$(LAUNCH_AGENT)"
	@echo "✅ Will start automatically at login (and started now)."

# Generate the LaunchAgent plist pointing at the installed binary.
$(LAUNCH_AGENT):
	@mkdir -p "$(HOME)/Library/LaunchAgents"
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'    <key>Label</key>' \
		'    <string>$(LAUNCH_LABEL)</string>' \
		'    <key>ProgramArguments</key>' \
		'    <array>' \
		'        <string>$(INSTALLED_APP)/Contents/MacOS/$(SCHEME)</string>' \
		'    </array>' \
		'    <key>RunAtLoad</key>' \
		'    <true/>' \
		'    <key>KeepAlive</key>' \
		'    <false/>' \
		'</dict>' \
		'</plist>' > "$(LAUNCH_AGENT)"
	@echo "📝 Wrote $(LAUNCH_AGENT)"

restart:
	@osascript -e 'tell application id "$(BUNDLE_ID)" to quit' >/dev/null 2>&1 || true
	@pkill -f "$(INSTALLED_APP)" 2>/dev/null || true
	@sleep 1
	open "$(INSTALLED_APP)"
	@echo "🔄 Relaunched ClaudeTry."

uninstall:
	@echo "🗑  Uninstalling…"
	@launchctl unload "$(LAUNCH_AGENT)" 2>/dev/null || true
	rm -f "$(LAUNCH_AGENT)"
	@osascript -e 'tell application id "$(BUNDLE_ID)" to quit' >/dev/null 2>&1 || true
	@pkill -f "$(INSTALLED_APP)" 2>/dev/null || true
	rm -rf "$(INSTALLED_APP)"
	@echo "✅ Removed app and LaunchAgent."

clean:
	rm -rf "$(BUILD_DIR)"
	@echo "🧹 Cleaned build artifacts."
