CFLAGS = -fobjc-arc -O2 -Wno-deprecated-declarations
APPS = $(HOME)/Applications
BIN = $(HOME)/.local/bin

all: spacetool spacebadge

spacetool: spacetool.m
	clang $(CFLAGS) -framework Cocoa -o $@ $<

spacebadge: spacebadge.m
	clang $(CFLAGS) -framework Cocoa -o $@ $<

define BUNDLE
	mkdir -p $(APPS)/$(1).app/Contents/MacOS
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '<key>CFBundleExecutable</key><string>$(1)</string>' \
	  '<key>CFBundleIdentifier</key><string>dev.umanzor.$(2)</string>' \
	  '<key>CFBundleName</key><string>$(1)</string>' \
	  '<key>CFBundlePackageType</key><string>APPL</string>' \
	  '<key>CFBundleShortVersionString</key><string>1.0</string>' \
	  '<key>LSMinimumSystemVersion</key><string>13.0</string>' \
	  '<key>LSUIElement</key><true/>' \
	  '</dict></plist>' > $(APPS)/$(1).app/Contents/Info.plist
	cp $(2) $(APPS)/$(1).app/Contents/MacOS/$(1)
	codesign --force -s - $(APPS)/$(1).app
endef

install: all
	$(call BUNDLE,SpaceTool,spacetool)
	$(call BUNDLE,SpaceBadge,spacebadge)
	mkdir -p $(BIN)
	printf '#!/bin/sh\nexec "$$HOME/Applications/SpaceTool.app/Contents/MacOS/SpaceTool" "$$@"\n' > $(BIN)/spacename
	printf '#!/bin/sh\nexec "$$HOME/Applications/SpaceTool.app/Contents/MacOS/SpaceTool" switch "$$@"\n' > $(BIN)/sw
	printf '#!/bin/sh\nexec "$$HOME/Applications/SpaceTool.app/Contents/MacOS/SpaceTool" bring "$$@"\n' > $(BIN)/bring
	chmod +x $(BIN)/spacename $(BIN)/sw $(BIN)/bring

clean:
	rm -f spacetool spacebadge
