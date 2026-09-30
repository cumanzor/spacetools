CFLAGS = -fobjc-arc -O2 -Wno-deprecated-declarations
APPS = $(HOME)/Applications
BIN = $(HOME)/.local/bin
LABEL = dev.umanzor.spacebadge
AGENT = $(HOME)/Library/LaunchAgents/$(LABEL).plist
SA = /Library/ScriptingAdditions/spacetools.osax
SADIR = spacetools.osax

all: spacetool spacebadge

spacetool: spacetool.m
	clang $(CFLAGS) -framework Cocoa -o $@ $<

spacebadge: spacebadge.m
	clang $(CFLAGS) -framework Cocoa -o $@ $<

# arm64e: the Dock is an arm64e process and only loads arm64e images;
# running either of these needs the -arm64e_preview_abi boot-arg
spacetoosa: spacetoosa.m
	clang -arch arm64e -shared -fPIC -fobjc-arc -O2 -Wno-deprecated-declarations \
	  -mmacosx-version-min=13.0 -framework Foundation -o $@ $<

loadsa: loadsa.m
	clang -arch arm64e -O2 -Wno-deprecated-declarations \
	  -mmacosx-version-min=13.0 -framework Cocoa -o $@ $<

sa: spacetoosa loadsa

install-sa: sa
	mkdir -p $(SADIR)/Contents/MacOS
	cp spacetoosa $(SADIR)/Contents/MacOS/spacetoosa
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '<key>CFBundleIdentifier</key><string>dev.umanzor.spacetoosa</string>' \
	  '<key>CFBundleName</key><string>spacetools</string>' \
	  '<key>CFBundlePackageType</key><string>BNDL</string>' \
	  '<key>CFBundleShortVersionString</key><string>1.0</string>' \
	  '</dict></plist>' > $(SADIR)/Contents/Info.plist
	@set -e; \
	if [ -f codesign.env ]; then . ./codesign.env; fi; \
	IDENT="$${SPACETOOLS_CODESIGN_IDENTITY:--}"; \
	if [ "$$IDENT" = "-" ]; then \
	  echo "  codesign sa: adhoc (no codesign.env)"; \
	  codesign --force -s - $(SADIR); \
	else \
	  echo "  codesign sa: $$IDENT"; \
	  codesign --force -s "$$IDENT" --identifier dev.umanzor.spacetoosa $(SADIR); \
	fi
	sudo rm -rf $(SA)
	sudo cp -r $(SADIR) $(SA)
	@echo "  installed at $(SA). load with: sudo ./loadsa"

uninstall-sa:
	sudo rm -rf $(SA)
	@echo "  removed $(SA) (the loaded payload dies with the Dock; killall Dock to drop it now)"

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
	printf '#!/bin/sh\nexec "$$HOME/Applications/SpaceTool.app/Contents/MacOS/SpaceTool" send "$$@"\n' > $(BIN)/send
	chmod +x $(BIN)/spacename $(BIN)/sw $(BIN)/bring $(BIN)/send

# bootout before bootstrap, never kickstart: launchd caches the old cdhash and
# kickstart dies with OS_REASON_CODESIGNING once the signature changes.
# bootout returns before the service leaves the domain, so bootstrapping straight
# after it races the teardown and fails with EIO. Wait for the label to go.
install-agent: install
	mkdir -p $(dir $(AGENT))
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '<key>Label</key><string>$(LABEL)</string>' \
	  '<key>ProgramArguments</key><array>' \
	  '<string>$(APPS)/SpaceBadge.app/Contents/MacOS/SpaceBadge</string>' \
	  '</array>' \
	  '<key>RunAtLoad</key><true/>' \
	  '<key>KeepAlive</key><true/>' \
	  '</dict></plist>' > $(AGENT)
	plutil -lint $(AGENT)
	@set -e; \
	D=gui/$$(id -u); \
	launchctl bootout $$D/$(LABEL) 2>/dev/null || true; \
	n=0; \
	while launchctl print $$D/$(LABEL) >/dev/null 2>&1; do \
	  n=$$((n + 1)); \
	  if [ $$n -ge 50 ]; then \
	    echo "fatal: $(LABEL) still loaded 5s after bootout" >&2; exit 1; \
	  fi; \
	  sleep 0.1; \
	done; \
	n=0; \
	while ! launchctl bootstrap $$D $(AGENT) 2>/dev/null; do \
	  n=$$((n + 1)); \
	  if [ $$n -ge 5 ]; then exec launchctl bootstrap $$D $(AGENT); fi; \
	  sleep 0.3; \
	done
	@echo "  agent loaded. 1-9 inside Mission Control needs Accessibility for SpaceBadge."

uninstall:
	-launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null
	rm -f $(AGENT)
	rm -rf $(APPS)/SpaceTool.app $(APPS)/SpaceBadge.app
	rm -f $(BIN)/spacename $(BIN)/sw $(BIN)/bring $(BIN)/send
	@echo "  removed. names kept at ~/.config/spacenames.json, delete it to drop those too."
	@echo "  SpaceBadge's Accessibility entry has to be removed by hand."

clean:
	rm -f spacetool spacebadge spacetoosa loadsa
	rm -rf $(SADIR)
