# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later

NAME       := changetrack-ng
VERSION    := 0.6.0

PREFIX     ?= /usr/local
BINDIR     ?= $(PREFIX)/bin
LIBDIR     ?= $(PREFIX)/lib/$(NAME)
SYSCONFDIR ?= $(if $(filter /usr,$(PREFIX)),/etc,$(PREFIX)/etc)
DATADIR    ?= /var/lib/$(NAME)
MANDIR     ?= $(PREFIX)/share/man
DOCDIR     ?= $(PREFIX)/share/doc/$(NAME)
SYSTEMDDIR  ?= /etc/systemd/system
HOOKSDIR    ?= $(LIBDIR)/hooks
CRONDIR     ?= /etc/cron.hourly
DEFAULTSDIR ?= $(if $(shell command -v dnf 2>/dev/null),/etc/sysconfig,/etc/default)
DESTDIR     ?=


PERL       ?= perl

.PHONY: all test install uninstall dist dist-deploy dist-minimal clean install-hooks install-debug-hooks install-systemd install-cron install-man man fatpack install-user install-user-systemd install-user-cron install-user-uninstall debian-build-setup debian-build-cleanup _install_defaults

all:
	@echo "$(NAME) $(VERSION)"
	@echo ""
	@echo "Targets:"
	@echo "  make test            Run the test suite"
	@echo "  make install         Install (PREFIX=$(PREFIX))"
	@echo "  make install-man     Install man pages (requires pod2man)"
	@echo "  make uninstall       Remove installed files"
	@echo "  make dist            Build full source release tarball"
	@echo "  make dist-deploy     Build production deployment tarball"
	@echo "  make dist-minimal    Build minimal fatpacked deployment tarball"
	@echo "  make fatpack         Build standalone single-file script (requires App::FatPacker)"
	@echo "  make install-hooks   Install package manager hooks"
	@echo "  make install-debug-hooks Install debug hooks (verbose log to /var/log/changetrack-ng-apt-debug.log)"
	@echo "  make install-systemd Install systemd timer"
	@echo "  make install-cron    Install cron.hourly job"
	@echo "  make install-user    Install under ~/.local + ~/.config"
	@echo "  make install-user-uninstall Remove user install files"
	@echo "  make install-user-systemd Install user systemd timer"
	@echo "  make install-user-cron    Print crontab entry for user"
	@echo "  make debian-build-setup   Expose packaging/debian as debian/ (for dpkg-buildpackage)"
	@echo "  make debian-build-cleanup Remove debian/ symlink"

test:
	prove -l t/

man: man/changetrack-ng.8.gz man/changetrack-ng.conf.5.gz

man/changetrack-ng.8.gz: man/changetrack-ng.8
	pod2man --section=8 --center="System Administration" --release="$(NAME) $(VERSION)" \
	    man/changetrack-ng.8 | gzip -9 > man/changetrack-ng.8.gz

man/changetrack-ng.conf.5.gz: man/changetrack-ng.conf.5
	pod2man --section=5 --center="File Formats" --release="$(NAME) $(VERSION)" \
	    man/changetrack-ng.conf.5 | gzip -9 > man/changetrack-ng.conf.5.gz

install-man: man
	install -d $(DESTDIR)$(MANDIR)/man8
	install -d $(DESTDIR)$(MANDIR)/man5
	install -m 644 man/changetrack-ng.8.gz    $(DESTDIR)$(MANDIR)/man8/changetrack-ng.8.gz
	install -m 644 man/changetrack-ng.conf.5.gz $(DESTDIR)$(MANDIR)/man5/changetrack-ng.conf.5.gz

install: _install_dirs _install_bin _install_lib _install_conf _install_examples

_install_conf_user:
	install -d $(HOME)/.config/$(NAME)
	@if [ ! -f $(HOME)/.config/$(NAME)/$(NAME).conf ]; then \
		install -m 640 packaging/etc/examples/$(NAME).conf-user $(HOME)/.config/$(NAME)/$(NAME).conf; \
		echo "Installed user config: $(HOME)/.config/$(NAME)/$(NAME).conf"; \
	else \
		echo "Skipping config (already exists): $(HOME)/.config/$(NAME)/$(NAME).conf"; \
	fi

_install_dirs:
	install -d $(DESTDIR)$(BINDIR)
	install -d $(DESTDIR)$(LIBDIR)/ChangeTrack/VCS
	install -d $(DESTDIR)$(LIBDIR)/ChangeTrack/Notify
	install -d $(DESTDIR)$(SYSCONFDIR)/$(NAME)
	install -d $(DESTDIR)$(SYSCONFDIR)/$(NAME)/conf.d
	install -d $(DESTDIR)$(SYSCONFDIR)/$(NAME)/track.d
	install -d $(DESTDIR)$(SYSCONFDIR)/$(NAME)/notifier.d
	install -d $(DESTDIR)$(DOCDIR)/examples
	install -d $(DESTDIR)$(DOCDIR)/examples/conf.d
	install -d $(DESTDIR)$(DOCDIR)/examples/track.d
	install -d $(DESTDIR)$(DOCDIR)/examples/notifier.d
	install -d $(DESTDIR)$(DATADIR)
	install -d $(DESTDIR)$(MANDIR)/man8
	install -d $(DESTDIR)$(MANDIR)/man5

_install_bin:
	sed -e "s|^use lib.*|use lib \"$(LIBDIR)\";|" \
	    bin/$(NAME) > $(DESTDIR)$(BINDIR)/$(NAME)
	chmod 755 $(DESTDIR)$(BINDIR)/$(NAME)

_install_lib:
	for f in lib/ChangeTrack/*.pm; do \
		install -m 644 "$$f" $(DESTDIR)$(LIBDIR)/ChangeTrack/; \
	done
	@if ls lib/ChangeTrack/VCS/*.pm 2>/dev/null | grep -q .; then \
		for f in lib/ChangeTrack/VCS/*.pm; do \
			install -m 644 "$$f" $(DESTDIR)$(LIBDIR)/ChangeTrack/VCS/; \
		done; \
	fi
	@if ls lib/ChangeTrack/Notify/*.pm 2>/dev/null | grep -q .; then \
		for f in lib/ChangeTrack/Notify/*.pm; do \
			install -m 644 "$$f" $(DESTDIR)$(LIBDIR)/ChangeTrack/Notify/; \
		done; \
	fi

_install_conf:
	@if [ ! -f $(DESTDIR)$(SYSCONFDIR)/$(NAME)/$(NAME).conf ]; then \
		install -m 640 etc/$(NAME).conf $(DESTDIR)$(SYSCONFDIR)/$(NAME)/; \
		echo "Installed default config: $(DESTDIR)$(SYSCONFDIR)/$(NAME)/$(NAME).conf"; \
	else \
		echo "Skipping config (already exists): $(DESTDIR)$(SYSCONFDIR)/$(NAME)/$(NAME).conf"; \
	fi

_install_examples:
	install -m 644 packaging/etc/examples/changetrack-ng.conf-full    $(DESTDIR)$(DOCDIR)/examples/changetrack-ng.conf-full
	install -m 644 packaging/etc/examples/changetrack-ng.conf-default $(DESTDIR)$(DOCDIR)/examples/changetrack-ng.conf-default
	install -m 644 packaging/etc/examples/changetrack-ng.conf-minimal $(DESTDIR)$(DOCDIR)/examples/changetrack-ng.conf-minimal
	install -m 644 packaging/etc/examples/changetrack-ng.conf-user    $(DESTDIR)$(DOCDIR)/examples/changetrack-ng.conf-user
	install -m 644 packaging/etc/examples/conf.d/local-settings.conf  $(DESTDIR)$(DOCDIR)/examples/conf.d/local-settings.conf
	install -m 644 packaging/etc/examples/track.d/system-core.conf    $(DESTDIR)$(DOCDIR)/examples/track.d/system-core.conf
	install -m 644 packaging/etc/examples/notifier.d/email.conf       $(DESTDIR)$(DOCDIR)/examples/notifier.d/email.conf
	install -m 644 packaging/etc/examples/notifier.d/otlp.conf        $(DESTDIR)$(DOCDIR)/examples/notifier.d/otlp.conf

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(NAME)
	rm -rf $(DESTDIR)$(LIBDIR)
	@echo "Note: config at $(DESTDIR)$(SYSCONFDIR)/$(NAME)/ was not removed"
	@echo "Note: data at $(DESTDIR)$(DATADIR) was not removed"

fatpack:
	@command -v fatpack >/dev/null 2>&1 || \
	    { echo "fatpack not found; install App::FatPacker (cpan App::FatPacker)"; exit 1; }
	mkdir -p fatlib
	cp -r lib/ChangeTrack fatlib/
	fatpack file bin/$(NAME) > $(NAME)-$(VERSION).pl
	chmod 755 $(NAME)-$(VERSION).pl
	rm -rf fatlib
	@echo "Created: $(NAME)-$(VERSION).pl"

dist:
	tar -czf $(NAME)-$(VERSION).tar.gz \
	    --exclude='.git' \
	    --exclude='*.tar.gz' \
	    --exclude='*.pl' \
	    --exclude='t/tmp' \
	    --exclude='man/*.gz' \
	    --exclude='packaging/debian/changetrack-ng' \
	    --exclude='packaging/debian/.debhelper' \
	    --transform "s,^,$(NAME)-$(VERSION)/," \
	    bin lib etc man packaging t Makefile LICENSE README.md INSTALL.md CHANGELOG.md

# Production deployment tarball: program, libs, configs, docs, hooks, scheduling, Makefile.
# No test suite, packaging metadata, or development files.
dist-deploy:
	tar -czf $(NAME)-$(VERSION)-deploy.tar.gz \
	    --exclude='*.tar.gz' \
	    --exclude='man/*.gz' \
	    --transform "s,^,$(NAME)-$(VERSION)/," \
	    bin lib etc man packaging/systemd packaging/cron packaging/hooks packaging/etc \
	    Makefile LICENSE README.md INSTALL.md CHANGELOG.md

# Minimal deployment tarball: fatpacked single-file script + essential support files.
# Requires fatpack to have been run first (or runs it automatically).
dist-minimal: fatpack
	tar -czf $(NAME)-$(VERSION)-minimal.tar.gz \
	    --exclude='*.tar.gz' \
	    --exclude='man/*.gz' \
	    --transform "s,^,$(NAME)-$(VERSION)/," \
	    $(NAME)-$(VERSION).pl etc man packaging/systemd packaging/cron packaging/hooks packaging/etc \
	    Makefile LICENSE README.md INSTALL.md CHANGELOG.md

clean:
	find t/ -name '*.tmp' -delete 2>/dev/null; true
	rm -f $(NAME)-*.tar.gz $(NAME)-*.pl man/*.gz
	rm -rf fatlib

debian-build-setup:
	@if [ -e debian ]; then \
		echo "Error: debian/ already exists"; exit 1; \
	fi
	ln -sfn packaging/debian debian
	@echo "Created debian/ → packaging/debian symlink"

debian-build-cleanup:
	@if [ -L debian ]; then \
		rm -f debian; \
		echo "Removed debian/ symlink"; \
	elif [ -d debian ]; then \
		echo "Error: debian/ is a directory, not a symlink; not removing"; exit 1; \
	else \
		echo "debian/ symlink not found (nothing to remove)"; \
	fi

install-hooks: _install_defaults
	@if command -v apt-get >/dev/null 2>&1; then \
		echo "Detected apt; installing hooks..."; \
		if [ -d packaging/hooks ]; then \
			sed -e "s|@BINDIR@|$(BINDIR)|g" -e "s|@DEFAULTSDIR@|$(DEFAULTSDIR)|g" \
			    packaging/hooks/apt-pre  > /etc/apt/apt.conf.d/80$(NAME)-pre; \
			chmod 644 /etc/apt/apt.conf.d/80$(NAME)-pre; \
			sed -e "s|@BINDIR@|$(BINDIR)|g" -e "s|@DEFAULTSDIR@|$(DEFAULTSDIR)|g" \
			    packaging/hooks/apt-post > /etc/apt/apt.conf.d/80$(NAME)-post; \
			chmod 644 /etc/apt/apt.conf.d/80$(NAME)-post; \
		fi; \
	elif command -v dnf >/dev/null 2>&1; then \
		echo "Detected dnf; installing plugin hooks..."; \
		if [ -d packaging/hooks/dnf ]; then \
			install -d /etc/dnf/plugins; \
			sed -e "s|@BINDIR@|$(BINDIR)|g" -e "s|@DEFAULTSDIR@|$(DEFAULTSDIR)|g" \
			    packaging/hooks/dnf/changetrack_ng.py > /etc/dnf/plugins/changetrack_ng.py; \
			chmod 644 /etc/dnf/plugins/changetrack_ng.py; \
			install -m 644 packaging/hooks/dnf/changetrack_ng.conf /etc/dnf/plugins/changetrack_ng.conf; \
		fi; \
	elif command -v pacman >/dev/null 2>&1; then \
		echo "Detected pacman; installing hooks..."; \
		if [ -d packaging/hooks ]; then \
			sed -e "s|@BINDIR@|$(BINDIR)|g" packaging/hooks/pacman-pre.hook  > /usr/share/libalpm/hooks/$(NAME)-pre.hook; \
			sed -e "s|@BINDIR@|$(BINDIR)|g" packaging/hooks/pacman-post.hook > /usr/share/libalpm/hooks/$(NAME)-post.hook; \
			chmod 644 /usr/share/libalpm/hooks/$(NAME)-pre.hook /usr/share/libalpm/hooks/$(NAME)-post.hook; \
		fi; \
	else \
		echo "No supported package manager detected; install hooks manually from packaging/hooks/"; \
	fi

install-debug-hooks: _install_defaults
	@if command -v apt-get >/dev/null 2>&1; then \
		echo "Detected apt; installing debug hooks..."; \
		if [ -d packaging/hooks ]; then \
			sed -e "s|@BINDIR@|$(BINDIR)|g" -e "s|@DEFAULTSDIR@|$(DEFAULTSDIR)|g" \
			    packaging/hooks/apt-pre-debug  > /etc/apt/apt.conf.d/80$(NAME)-pre; \
			chmod 644 /etc/apt/apt.conf.d/80$(NAME)-pre; \
			sed -e "s|@BINDIR@|$(BINDIR)|g" -e "s|@DEFAULTSDIR@|$(DEFAULTSDIR)|g" \
			    packaging/hooks/apt-post-debug > /etc/apt/apt.conf.d/80$(NAME)-post; \
			chmod 644 /etc/apt/apt.conf.d/80$(NAME)-post; \
		fi; \
		echo "Debug hooks installed. Run 'apt update && apt upgrade' then check /var/log/changetrack-ng-apt-debug.log"; \
		echo "Restore production hooks with: make install-hooks"; \
	else \
		echo "Debug hooks are only supported for apt; no action taken"; \
	fi

install-systemd: _install_defaults
	install -d $(DESTDIR)$(SYSTEMDDIR)
	sed -e "s|@BINDIR@|$(BINDIR)|g" -e "s|@DEFAULTSDIR@|$(DEFAULTSDIR)|g" \
	    packaging/systemd/$(NAME).service > $(DESTDIR)$(SYSTEMDDIR)/$(NAME).service
	chmod 644 $(DESTDIR)$(SYSTEMDDIR)/$(NAME).service
	install -m 644 packaging/systemd/$(NAME).timer   $(DESTDIR)$(SYSTEMDDIR)/
	systemctl daemon-reload
	@echo "Enable with: systemctl enable --now $(NAME).timer"

install-cron: _install_defaults
	install -d $(DESTDIR)$(CRONDIR)
	sed -e "s|@BINDIR@|$(BINDIR)|g" -e "s|@DEFAULTSDIR@|$(DEFAULTSDIR)|g" \
	    packaging/cron/$(NAME) > $(DESTDIR)$(CRONDIR)/$(NAME)
	chmod 755 $(DESTDIR)$(CRONDIR)/$(NAME)
	@echo "Installed: $(DESTDIR)$(CRONDIR)/$(NAME)"

_install_defaults:
	install -d $(DESTDIR)$(DEFAULTSDIR)
	@if [ ! -f $(DESTDIR)$(DEFAULTSDIR)/$(NAME) ]; then \
		install -m 644 packaging/etc/$(NAME).default $(DESTDIR)$(DEFAULTSDIR)/$(NAME); \
		echo "Installed defaults: $(DESTDIR)$(DEFAULTSDIR)/$(NAME)"; \
	else \
		echo "Skipping defaults (already exists): $(DESTDIR)$(DEFAULTSDIR)/$(NAME)"; \
	fi


install-user: _install_dirs_user _install_bin_user _install_lib_user _install_conf_user _install_examples_user
	@echo "Installed user config: $(HOME)/.config/$(NAME)/$(NAME).conf"
	@echo "Example configs: $(HOME)/.config/$(NAME)/examples/"
	@echo "Next: edit [track] entries, then run: $(HOME)/.local/bin/$(NAME) run"

_install_dirs_user:
	install -d $(HOME)/.local/bin
	install -d $(HOME)/.local/lib/$(NAME)/ChangeTrack/VCS
	install -d $(HOME)/.local/lib/$(NAME)/ChangeTrack/Notify
	install -d $(HOME)/.config/$(NAME)
	install -d $(HOME)/.config/$(NAME)/conf.d
	install -d $(HOME)/.config/$(NAME)/track.d
	install -d $(HOME)/.config/$(NAME)/notifier.d
	install -d $(HOME)/.config/$(NAME)/examples
	install -d $(HOME)/.local/state/$(NAME)

_install_bin_user:
	sed -e "s|^use lib.*|use lib \"$(HOME)/.local/lib/$(NAME)\";|" \
	    bin/$(NAME) > $(HOME)/.local/bin/$(NAME)
	chmod 755 $(HOME)/.local/bin/$(NAME)

_install_lib_user:
	for f in lib/ChangeTrack/*.pm; do \
		install -m 644 "$$f" $(HOME)/.local/lib/$(NAME)/ChangeTrack/; \
	done
	@if ls lib/ChangeTrack/VCS/*.pm 2>/dev/null | grep -q .; then \
		for f in lib/ChangeTrack/VCS/*.pm; do \
			install -m 644 "$$f" $(HOME)/.local/lib/$(NAME)/ChangeTrack/VCS/; \
		done; \
	fi
	@if ls lib/ChangeTrack/Notify/*.pm 2>/dev/null | grep -q .; then \
		for f in lib/ChangeTrack/Notify/*.pm; do \
			install -m 644 "$$f" $(HOME)/.local/lib/$(NAME)/ChangeTrack/Notify/; \
		done; \
	fi

_install_examples_user:
	install -d $(HOME)/.config/$(NAME)/examples
	install -d $(HOME)/.config/$(NAME)/examples/conf.d
	install -d $(HOME)/.config/$(NAME)/examples/track.d
	install -d $(HOME)/.config/$(NAME)/examples/notifier.d
	install -m 644 packaging/etc/examples/changetrack-ng.conf-full    $(HOME)/.config/$(NAME)/examples/changetrack-ng.conf-full
	install -m 644 packaging/etc/examples/changetrack-ng.conf-default $(HOME)/.config/$(NAME)/examples/changetrack-ng.conf-default
	install -m 644 packaging/etc/examples/changetrack-ng.conf-minimal $(HOME)/.config/$(NAME)/examples/changetrack-ng.conf-minimal
	install -m 644 packaging/etc/examples/changetrack-ng.conf-user    $(HOME)/.config/$(NAME)/examples/changetrack-ng.conf-user
	install -m 644 packaging/etc/examples/conf.d/local-settings.conf  $(HOME)/.config/$(NAME)/examples/conf.d/local-settings.conf
	install -m 644 packaging/etc/examples/track.d/system-core.conf    $(HOME)/.config/$(NAME)/examples/track.d/system-core.conf
	install -m 644 packaging/etc/examples/notifier.d/email.conf       $(HOME)/.config/$(NAME)/examples/notifier.d/email.conf
	install -m 644 packaging/etc/examples/notifier.d/otlp.conf        $(HOME)/.config/$(NAME)/examples/notifier.d/otlp.conf
install-user-uninstall:
	rm -f $(HOME)/.local/bin/$(NAME)
	rm -rf $(HOME)/.local/lib/$(NAME)
	rm -f $(HOME)/.config/systemd/user/$(NAME).service
	rm -f $(HOME)/.config/systemd/user/$(NAME).timer
	@if command -v systemctl >/dev/null 2>&1; then \
		systemctl --user daemon-reload 2>/dev/null; \
	fi
	@echo "Removed user installation of changetrack-ng"
	@echo "Note: config at $(HOME)/.config/$(NAME)/ was not removed"
	@echo "Note: data at $(HOME)/.local/state/$(NAME)/ was not removed"


install-user-systemd:
	install -d $(HOME)/.config/systemd/user
	sed -e "s|@BINDIR@|$(HOME)/.local/bin|g" packaging/systemd/$(NAME).service > $(HOME)/.config/systemd/user/$(NAME).service
	install -m 644 packaging/systemd/$(NAME).timer $(HOME)/.config/systemd/user/$(NAME).timer
	@if command -v systemctl >/dev/null 2>&1; then \
		systemctl --user daemon-reload 2>/dev/null; \
		echo "Enable with: systemctl --user enable --now $(NAME).timer"; \
	else \
		echo "systemctl not found; installed unit files only"; \
	fi

install-user-cron:
	@echo "Add this line to your user crontab (crontab -e):"
	@echo "0 * * * * $(HOME)/.local/bin/$(NAME) run --config $(HOME)/.config/$(NAME)/$(NAME).conf"
