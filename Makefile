# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later

NAME       := changetrack-ng
VERSION    := 0.3.0

PREFIX     ?= /usr/local
BINDIR     ?= $(PREFIX)/bin
LIBDIR     ?= $(PREFIX)/lib/$(NAME)
SYSCONFDIR ?= $(if $(filter /usr,$(PREFIX)),/etc,$(PREFIX)/etc)
DATADIR    ?= /var/lib/$(NAME)
MANDIR     ?= $(PREFIX)/share/man
SYSTEMDDIR ?= /etc/systemd/system
HOOKSDIR   ?= $(LIBDIR)/hooks
CRONDIR    ?= /etc/cron.hourly
DESTDIR    ?=


PERL       ?= perl

.PHONY: all test install uninstall dist clean install-hooks install-systemd install-cron install-man man fatpack install-user install-user-systemd install-user-cron install-user-uninstall

all:
	@echo "$(NAME) $(VERSION)"
	@echo ""
	@echo "Targets:"
	@echo "  make test            Run the test suite"
	@echo "  make install         Install (PREFIX=$(PREFIX))"
	@echo "  make install-man     Install man pages (requires pod2man)"
	@echo "  make uninstall       Remove installed files"
	@echo "  make dist            Build release tarball"
	@echo "  make fatpack         Build standalone single-file script (requires App::FatPacker)"
	@echo "  make install-hooks   Install package manager hooks"
	@echo "  make install-systemd Install systemd timer"
	@echo "  make install-cron    Install cron.hourly job"
	@echo "  make install-user    Install under ~/.local + ~/.config"
	@echo "  make install-user-uninstall Remove user install files"
	@echo "  make install-user-systemd Install user systemd timer"
	@echo "  make install-user-cron    Print crontab entry for user"

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
		install -m 640 etc/examples/$(NAME).conf-user $(HOME)/.config/$(NAME)/$(NAME).conf; \
		echo "Installed user config: $(HOME)/.config/$(NAME)/$(NAME).conf"; \
	else \
		echo "Skipping config (already exists): $(HOME)/.config/$(NAME)/$(NAME).conf"; \
	fi

_install_dirs:
	install -d $(DESTDIR)$(BINDIR)
	install -d $(DESTDIR)$(LIBDIR)/ChangeTrack/VCS
	install -d $(DESTDIR)$(LIBDIR)/ChangeTrack/Notify
	install -d $(DESTDIR)$(SYSCONFDIR)/$(NAME)
	install -d $(DESTDIR)$(SYSCONFDIR)/$(NAME)/examples
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
	install -m 644 etc/examples/changetrack-ng.conf-minimal $(DESTDIR)$(SYSCONFDIR)/$(NAME)/examples/changetrack-ng.conf-minimal
	install -m 644 etc/examples/changetrack-ng.conf-user    $(DESTDIR)$(SYSCONFDIR)/$(NAME)/examples/changetrack-ng.conf-user

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
	    --exclude='debian/changetrack-ng' \
	    --exclude='debian/.debhelper' \
	    --transform "s,^,$(NAME)-$(VERSION)/," \
	    bin lib etc man hooks systemd cron rpm debian t Makefile LICENSE README.md INSTALL.md CHANGELOG.md

clean:
	find t/ -name '*.tmp' -delete 2>/dev/null; true
	rm -f $(NAME)-*.tar.gz $(NAME)-*.pl man/*.gz
	rm -rf fatlib

install-hooks:
	@if command -v apt-get >/dev/null 2>&1; then \
		echo "Detected apt; installing hooks..."; \
		[ -d hooks ] && install -m 644 hooks/apt-pre  /etc/apt/apt.conf.d/80$(NAME)-pre  || true; \
		[ -d hooks ] && install -m 644 hooks/apt-post /etc/apt/apt.conf.d/80$(NAME)-post || true; \
	elif command -v dnf >/dev/null 2>&1; then \
		echo "Detected dnf; installing plugin hooks..."; \
		if [ -d hooks/dnf ]; then \
			install -d /etc/dnf/plugins; \
			sed -e "s|@BINDIR@|$(BINDIR)|g" hooks/dnf/changetrack_ng.py > /etc/dnf/plugins/changetrack_ng.py; \
			chmod 644 /etc/dnf/plugins/changetrack_ng.py; \
			install -m 644 hooks/dnf/changetrack_ng.conf /etc/dnf/plugins/changetrack_ng.conf; \
		fi; \
	elif command -v pacman >/dev/null 2>&1; then \
		echo "Detected pacman; installing hooks..."; \
		if [ -d hooks ]; then \
			sed -e "s|@BINDIR@|$(BINDIR)|g" hooks/pacman-pre.hook  > /usr/share/libalpm/hooks/$(NAME)-pre.hook; \
			sed -e "s|@BINDIR@|$(BINDIR)|g" hooks/pacman-post.hook > /usr/share/libalpm/hooks/$(NAME)-post.hook; \
			chmod 644 /usr/share/libalpm/hooks/$(NAME)-pre.hook /usr/share/libalpm/hooks/$(NAME)-post.hook; \
		fi; \
	else \
		echo "No supported package manager detected; install hooks manually from hooks/"; \
	fi

install-systemd:
	install -d $(DESTDIR)$(SYSTEMDDIR)
	sed -e "s|@BINDIR@|$(BINDIR)|g" systemd/$(NAME).service > $(DESTDIR)$(SYSTEMDDIR)/$(NAME).service
	chmod 644 $(DESTDIR)$(SYSTEMDDIR)/$(NAME).service
	install -m 644 systemd/$(NAME).timer   $(DESTDIR)$(SYSTEMDDIR)/
	systemctl daemon-reload
	@echo "Enable with: systemctl enable --now $(NAME).timer"

install-cron:
	install -d $(DESTDIR)$(CRONDIR)
	sed -e "s|@BINDIR@|$(BINDIR)|g" cron/$(NAME) > $(DESTDIR)$(CRONDIR)/$(NAME)
	chmod 755 $(DESTDIR)$(CRONDIR)/$(NAME)
	@echo "Installed: $(DESTDIR)$(CRONDIR)/$(NAME)"


install-user: _install_dirs_user _install_bin_user _install_lib_user _install_conf_user _install_examples_user
	@echo "Installed user config: $(HOME)/.config/$(NAME)/$(NAME).conf"
	@echo "Example configs: $(HOME)/.config/$(NAME)/examples/"
	@echo "Next: edit [track] entries, then run: $(HOME)/.local/bin/$(NAME) run"

_install_dirs_user:
	install -d $(HOME)/.local/bin
	install -d $(HOME)/.local/lib/$(NAME)/ChangeTrack/VCS
	install -d $(HOME)/.local/lib/$(NAME)/ChangeTrack/Notify
	install -d $(HOME)/.config/$(NAME)
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
	install -m 644 etc/examples/changetrack-ng.conf-minimal $(HOME)/.config/$(NAME)/examples/changetrack-ng.conf-minimal
	install -m 644 etc/examples/changetrack-ng.conf-user    $(HOME)/.config/$(NAME)/examples/changetrack-ng.conf-user
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
	sed -e "s|@BINDIR@|$(HOME)/.local/bin|g" systemd/$(NAME).service > $(HOME)/.config/systemd/user/$(NAME).service
	install -m 644 systemd/$(NAME).timer $(HOME)/.config/systemd/user/$(NAME).timer
	@if command -v systemctl >/dev/null 2>&1; then \
		systemctl --user daemon-reload 2>/dev/null; \
		echo "Enable with: systemctl --user enable --now $(NAME).timer"; \
	else \
		echo "systemctl not found; installed unit files only"; \
	fi

install-user-cron:
	@echo "Add this line to your user crontab (crontab -e):"
	@echo "0 * * * * $(HOME)/.local/bin/$(NAME) run --config $(HOME)/.config/$(NAME)/$(NAME).conf"
