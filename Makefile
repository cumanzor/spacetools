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
	@set -e; \
	if [ -f codesign.env ]; then . ./codesign.env; fi; \
	IDENT="$${SPACETOOLS_CODESIGN_IDENTITY:--}"; OU="$${SPACETOOLS_TEAM_OU:-}"; \
	if [ "$$IDENT" = "-" ]; then \
	  echo "  codesign $(1): adhoc (no codesign.env - accessibility grant resets every build)"; \
	  codesign --force -s - $(APPS)/$(1).app; \
	else \
	  if [ -z "$$OU" ]; then \
	    echo "fatal: SPACETOOLS_CODESIGN_IDENTITY set but SPACETOOLS_TEAM_OU empty" >&2; exit 1; fi; \
	  echo "  codesign $(1): stable identity, DR pinned to OU $$OU"; \
	  codesign --force -s "$$IDENT" --requirements \
	    "=designated => identifier \"dev.umanzor.$(2)\" and anchor apple generic and certificate leaf[subject.OU] = \"$$OU\" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */" \
	    $(APPS)/$(1).app; \
	fi
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
