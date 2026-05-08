# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later
# Keep Version: in sync with Makefile VERSION and lib/ChangeTrack/Version.pm
Name:           changetrack-ng
Version:        0.5.2
Release:        1%{?dist}
Summary:        System file change tracker with pluggable VCS and notification support

License:        GPL-3.0-or-later
URL:            https://github.com/cashell/changetrack-ng
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
BuildRequires:  make
BuildRequires:  perl-interpreter
BuildRequires:  perl-generators
BuildRequires:  systemd-rpm-macros
BuildRequires:  %{_bindir}/pod2man

Requires:       perl-interpreter >= 5.020
# HTTP::Tiny, JSON::PP, IO::Compress::Gzip are core; SSL is not
Recommends:     perl-IO-Socket-SSL
# At least one VCS backend required
Suggests:       git
Suggests:       rcs
Suggests:       fossil
Suggests:       subversion
Suggests:       mercurial

%description
changetrack-ng tracks changes to system files and directories using a
pluggable VCS backend (RCS, Git, Fossil, SVN, or Mercurial) and sends
notifications via email, HTTP webhook, OpenTelemetry (OTLP), or an
append-only JSON log.

It combines the per-file flexibility of the original changetrack (last
maintained 2009) with the modern VCS and package-manager integration of
etckeeper.  Supports systemd timer, cron.hourly, and package manager
hooks (apt, pacman, dnf).


%prep
%autosetup


%build
# pure Perl — nothing to compile


%install
%make_install PREFIX=/usr
%make_install install-man PREFIX=/usr

# Install scheduler integration files for packaged deployments.
install -d %{buildroot}%{_unitdir}
sed -e "s|@BINDIR@|%{_bindir}|g" packaging/systemd/%{name}.service > %{buildroot}%{_unitdir}/%{name}.service
install -m 644 packaging/systemd/%{name}.timer %{buildroot}%{_unitdir}/%{name}.timer

install -d %{buildroot}%{_sysconfdir}/cron.hourly
sed -e "s|@BINDIR@|%{_bindir}|g" packaging/cron/%{name} > %{buildroot}%{_sysconfdir}/cron.hourly/%{name}
chmod 755 %{buildroot}%{_sysconfdir}/cron.hourly/%{name}

install -d %{buildroot}%{_sysconfdir}/dnf/plugins
sed -e "s|@BINDIR@|%{_bindir}|g" packaging/hooks/dnf/changetrack_ng.py > %{buildroot}%{_sysconfdir}/dnf/plugins/changetrack_ng.py
chmod 644 %{buildroot}%{_sysconfdir}/dnf/plugins/changetrack_ng.py
install -m 644 packaging/hooks/dnf/changetrack_ng.conf %{buildroot}%{_sysconfdir}/dnf/plugins/changetrack_ng.conf


%post
%systemd_post %{name}.timer


%preun
%systemd_preun %{name}.timer %{name}.service


%postun
%systemd_postun_with_restart %{name}.timer


%files
%license LICENSE
%doc README.md INSTALL.md ARCHITECTURE.md CHANGELOG.md
%doc %{_docdir}/%{name}/examples

%{_bindir}/changetrack-ng

%dir %{_libdir}/%{name}
%dir %{_libdir}/%{name}/ChangeTrack
%dir %{_libdir}/%{name}/ChangeTrack/VCS
%dir %{_libdir}/%{name}/ChangeTrack/Notify
%{_libdir}/%{name}/ChangeTrack/*.pm
%{_libdir}/%{name}/ChangeTrack/VCS/*.pm
%{_libdir}/%{name}/ChangeTrack/Notify/*.pm

%config(noreplace) %{_sysconfdir}/%{name}/%{name}.conf
%dir %{_sysconfdir}/%{name}

%dir %{_localstatedir}/lib/%{name}

%{_unitdir}/%{name}.service
%{_unitdir}/%{name}.timer
%{_sysconfdir}/cron.hourly/%{name}
%{_sysconfdir}/dnf/plugins/changetrack_ng.py
%config(noreplace) %{_sysconfdir}/dnf/plugins/changetrack_ng.conf

%{_mandir}/man8/changetrack-ng.8*
%{_mandir}/man5/changetrack-ng.conf.5*


%changelog
* Fri May 08 2026 Christopher Cashell <topher@zyp.org> - 0.5.2-1
- Perf: status, diff, and log subcommands now apply metadata fast-path,
  skipping unchanged files without spawning a VCS process per file
- Add t/16-subcommands.t: tests for status/diff fast-path and clean-file diff_path

* Tue May 06 2026 Christopher Cashell <topher@zyp.org> - 0.5.1-1
- Fix: all unattended invocations (apt, pacman hooks; cron; systemd) now pass --quiet,
  preventing change reports from flooding terminal output during package manager operations

* Tue May 06 2026 Christopher Cashell <topher@zyp.org> - 0.5.0-1
- Add config_keys() to each notifier; _build_notifier filters to notifier-specific keys
- Add t/21-report.t: 52-test dedicated suite for ChangeTrack::Report
- Add start_time/end_time accessors to Report.pm (were documented but missing)
- Fix: MockSendmail $VERSION now derived from ChangeTrack::Version
- Perf: cache /etc/machine-id in OTLP::_resource_attrs() via state variable
- Perf: pass pre-computed mode to _resolve_sensitive(), eliminate redundant stat()
- Fix: webhook diff counters no longer count unified diff +++ / --- header lines
- Fix: eliminate redundant $vcs->add() after checkin() in Runner
- Fix: Fossil/SVN chdir() wrapped in exception-safe eval; Mercurial uses -R
- Add --dry-run / -n flag for static change analysis without VCS mutation
- Precompile ignore patterns once per run (was per-file); improves scaling
- Deduplicate notifier construction via shared _build_notifier helper

* Sun May 04 2026 Christopher Cashell <topher@zyp.org> - 0.4.3-1
- Unified metadata type system: drop skip_reason, use single type field
  (file, symlink, binary, empty, unreadable, special, directory, missing)
- Performance: metadata-based fast path skips unchanged files without I/O
- Fix: symlinks no longer misclassified as binary
- Fix: empty (zero-byte) files no longer flagged as binary
- Fix: binary file warnings only emitted on first detection
- Fix: getpwuid/getgrgid portability for non-POSIX platforms

* Mon Apr 28 2026 Christopher Cashell <topher@zyp.org> - 0.3.0-1
- Initial RPM packaging
- Clean Perl rewrite of changetrack with modern VCS and notification support
- Supports RCS, Git, Fossil, SVN, Mercurial backends
- Supports Email, Webhook, OTLP, File notification channels
- Includes systemd timer, cron.hourly script, and package manager hooks for apt, pacman, and dnf
