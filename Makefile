CFLAGS = -fobjc-arc -O2 -Wno-deprecated-declarations
APPS = $(HOME)/Applications
BIN = $(HOME)/.local/bin
LABEL = dev.umanzor.spacebadge
AGENT = $(HOME)/Library/LaunchAgents/$(LABEL).plist
VLABEL = dev.umanzor.spaceview
VAGENT = $(HOME)/Library/LaunchAgents/$(VLABEL).plist
# outside /Library/ScriptingAdditions: OpenScripting scans that folder on every
# AppleScript run and warns about any bundle without OSAXHandlers
SAROOT = /Library/Application Support/spacetools
SA = $(SAROOT)/spacetools.osax
OLDSA = /Library/ScriptingAdditions/spacetools.osax
SADIR = spacetools.osax
LOADSA = $(APPS)/SpaceTool.app/Contents/MacOS/loadsa
SUDOERS = /private/etc/sudoers.d/spacetools-sa

all: spacetool spacebadge spaceview

spacetool: spacetool.m
	clang $(CFLAGS) -framework Cocoa -o $@ $<

spacebadge: spacebadge.m
	clang $(CFLAGS) -framework Cocoa -o $@ $<

spaceview: spaceview.m
	clang $(CFLAGS) -framework Cocoa -framework QuartzCore -o $@ $<

# arm64e: the Dock is an arm64e process and only loads arm64e images;
# running either of these needs the -arm64e_preview_abi boot-arg
spacetoosa: spacetoosa.m
	clang -arch arm64e -shared -fPIC -fobjc-arc -O2 -Wno-deprecated-declarations \
	  -mmacosx-version-min=13.0 -framework Foundation -o $@ $<

loadsa: loadsa.m
	clang -arch arm64e -O2 -Wno-deprecated-declarations \
	  -mmacosx-version-min=13.0 -framework Cocoa -o $@ $<

sa: spacetoosa loadsa

# the sudoers line pins the bundle loadsa by sha256 (yabai's pattern); sudo
# only ever runs that exact byte-for-byte binary, so every loadsa rebuild must
# regenerate the pin or sudo -n silently denies and re-injection stops
refresh-sa: loadsa spacetool
	@if [ "$$(id -u)" = 0 ]; then \
	  echo "fatal: run refresh-sa as yourself; sudo only wraps the install below" >&2; \
	  echo "       (codesign needs your login keychain; root cannot sign)" >&2; exit 1; fi
	$(call BUNDLE,SpaceTool,spacetool,loadsa)
	@set -e; \
	H=$$(shasum -a 256 $(LOADSA) | cut -d' ' -f1); \
	{ echo "# spacetools sa injector pin (managed by make refresh-sa; regenerate after every loadsa rebuild)"; \
	  printf '%s ALL=(root) NOPASSWD: sha256:%s %s ""\n' "$$(whoami)" "$$H" "$(LOADSA)"; } > /tmp/spacetools-sudoers; \
	visudo -c -f /tmp/spacetools-sudoers; \
	sudo install -o root -g wheel -m 0440 /tmp/spacetools-sudoers $(SUDOERS); \
	rm -f /tmp/spacetools-sudoers; \
	echo "  sudoers pinned: $$(whoami) NOPASSWD sha256:$$H $(LOADSA)"

install-sa: sa refresh-sa
	@if [ "$$(id -u)" = 0 ]; then \
	  echo "fatal: run install-sa as yourself; sudo only wraps the rm/cp below" >&2; \
	  echo "       (codesign needs your login keychain; root cannot sign)" >&2; exit 1; fi
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
	sudo rm -rf "$(SA)" "$(OLDSA)"
	sudo mkdir -p "$(SAROOT)"
	sudo cp -r $(SADIR) "$(SA)"
	sudo -n $(LOADSA)
	@echo "  installed at $(SA), sudoers pinned, payload loaded. stick works."

uninstall-sa:
	sudo rm -rf "$(SA)" "$(OLDSA)"
	-sudo rmdir "$(SAROOT)"
	sudo rm -f $(SUDOERS)
	rm -f $(LOADSA)
	@echo "  removed $(SA), the sudoers pin and the bundle loadsa"
	@echo "  (the loaded payload dies with the Dock; killall Dock to drop it now)"

# optional 4th arg: destination folder, ~/Applications by default
define BUNDLE
	mkdir -p $(or $(4),$(APPS))/$(1).app/Contents/MacOS
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
	  '</dict></plist>' > $(or $(4),$(APPS))/$(1).app/Contents/Info.plist
	cp $(2) $(or $(4),$(APPS))/$(1).app/Contents/MacOS/$(1)
	$(foreach x,$(3),cp $(x) $(or $(4),$(APPS))/$(1).app/Contents/MacOS/$(x);)
	@set -e; \
	if [ -f codesign.env ]; then . ./codesign.env; fi; \
	IDENT="$${SPACETOOLS_CODESIGN_IDENTITY:--}"; OU="$${SPACETOOLS_TEAM_OU:-}"; \
	if [ "$$IDENT" = "-" ]; then \
	  echo "  codesign $(1): adhoc (no codesign.env - accessibility grant resets every build)"; \
	  codesign --force -s - $(or $(4),$(APPS))/$(1).app; \
	else \
	  if [ -z "$$OU" ]; then \
	    echo "fatal: SPACETOOLS_CODESIGN_IDENTITY set but SPACETOOLS_TEAM_OU empty" >&2; exit 1; fi; \
	  echo "  codesign $(1): stable identity, DR pinned to OU $$OU"; \
	  codesign --force -s "$$IDENT" --requirements \
	    "=designated => identifier \"dev.umanzor.$(2)\" and anchor apple generic and certificate leaf[subject.OU] = \"$$OU\" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */" \
	    $(or $(4),$(APPS))/$(1).app; \
	fi
endef

install: all loadsa
	$(call BUNDLE,SpaceTool,spacetool,loadsa)
	$(call BUNDLE,SpaceBadge,spacebadge)
	mkdir -p $(BIN)
	printf '#!/bin/sh\nexec "$$HOME/Applications/SpaceTool.app/Contents/MacOS/SpaceTool" "$$@"\n' > $(BIN)/spacename
	printf '#!/bin/sh\nexec "$$HOME/Applications/SpaceTool.app/Contents/MacOS/SpaceTool" switch "$$@"\n' > $(BIN)/sw
	printf '#!/bin/sh\nexec "$$HOME/Applications/SpaceTool.app/Contents/MacOS/SpaceTool" bring "$$@"\n' > $(BIN)/bring
	printf '#!/bin/sh\nexec "$$HOME/Applications/SpaceTool.app/Contents/MacOS/SpaceTool" send "$$@"\n' > $(BIN)/send
	printf '#!/bin/sh\nexec "$$HOME/Applications/SpaceTool.app/Contents/MacOS/SpaceTool" stick "$$@"\n' > $(BIN)/stick
	printf '#!/bin/sh\nexec "$$HOME/Applications/SpaceTool.app/Contents/MacOS/SpaceTool" unstick "$$@"\n' > $(BIN)/unstick
	chmod +x $(BIN)/spacename $(BIN)/sw $(BIN)/bring $(BIN)/send $(BIN)/stick $(BIN)/unstick
	@echo "  loadsa bundled at $(LOADSA)"
	@echo "  (rebuilding loadsa.m? run make refresh-sa after, to re-pin the sudoers hash)"

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
	rm -f $(BIN)/spacename $(BIN)/sw $(BIN)/bring $(BIN)/send $(BIN)/stick $(BIN)/unstick
	@echo "  removed. names kept at ~/.config/spacenames.json, delete it to drop those too."
	@echo "  SpaceBadge's Accessibility entry has to be removed by hand."
	@echo "  run make uninstall-sa separately to drop the scripting addition."

# runs uninstalled from the repo; same identifier and DR as the installed
# bundle, so TCC grants carry over to install-view
view-dev: spaceview
	$(call BUNDLE,SpaceView,spaceview,,$(CURDIR)/build)
	@echo "  run: build/SpaceView.app/Contents/MacOS/SpaceView"

install-view: spaceview
	$(call BUNDLE,SpaceView,spaceview)

# same bootout/wait/bootstrap dance as install-agent, for SpaceView's label only
install-view-agent: install-view
	mkdir -p $(dir $(VAGENT))
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '<key>Label</key><string>$(VLABEL)</string>' \
	  '<key>ProgramArguments</key><array>' \
	  '<string>$(APPS)/SpaceView.app/Contents/MacOS/SpaceView</string>' \
	  '</array>' \
	  '<key>RunAtLoad</key><true/>' \
	  '<key>KeepAlive</key><true/>' \
	  '</dict></plist>' > $(VAGENT)
	plutil -lint $(VAGENT)
	@set -e; \
	D=gui/$$(id -u); \
	launchctl bootout $$D/$(VLABEL) 2>/dev/null || true; \
	n=0; \
	while launchctl print $$D/$(VLABEL) >/dev/null 2>&1; do \
	  n=$$((n + 1)); \
	  if [ $$n -ge 50 ]; then \
	    echo "fatal: $(VLABEL) still loaded 5s after bootout" >&2; exit 1; \
	  fi; \
	  sleep 0.1; \
	done; \
	n=0; \
	while ! launchctl bootstrap $$D $(VAGENT) 2>/dev/null; do \
	  n=$$((n + 1)); \
	  if [ $$n -ge 5 ]; then exec launchctl bootstrap $$D $(VAGENT); fi; \
	  sleep 0.3; \
	done
	@echo "  agent loaded. previews need Screen Recording, keys need Accessibility for SpaceView."

uninstall-view:
	-launchctl bootout gui/$$(id -u)/$(VLABEL) 2>/dev/null
	rm -f $(VAGENT)
	rm -rf $(APPS)/SpaceView.app
	@echo "  removed. SpaceView's Screen Recording and Accessibility entries have to be removed by hand."

clean:
	rm -f spacetool spacebadge spaceview spacetoosa loadsa
	rm -rf build
	rm -rf $(SADIR)
