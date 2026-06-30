# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later
# Keep Version: in sync with Makefile VERSION and lib/ChangeTrack/Version.pm
Name:           changetrack-ng
Version:        0.7.0
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
%doc README.md INSTALL.md ARCHITECTURE.md CHANGELOG.md PRODUCT.md CONTRIBUTING.md
%doc %{_docdir}/%{name}/examples

%{_bindir}/changetrack-ng

%dir %{_libdir}/%{name}
%dir %{_libdir}/%{name}/ChangeTrack
%dir %{_libdir}/%{name}/ChangeTrack/VCS
%dir %{_libdir}/%{name}/ChangeTrack/Notify
%{_libdir}/%{name}/ChangeTrack/*.pm
%{_libdir}/%{name}/ChangeTrack/VCS/*.pm
%{_libdir}/%{name}/ChangeTrack/Notify/*.pm

%dir %{_sysconfdir}/%{name}
%dir %{_sysconfdir}/%{name}/conf.d
%dir %{_sysconfdir}/%{name}/track.d
%dir %{_sysconfdir}/%{name}/notifier.d
%config(noreplace) %{_sysconfdir}/%{name}/%{name}.conf

%dir %{_localstatedir}/lib/%{name}

%{_unitdir}/%{name}.service
%{_unitdir}/%{name}.timer
%{_sysconfdir}/cron.hourly/%{name}
%{_sysconfdir}/dnf/plugins/changetrack_ng.py
%config(noreplace) %{_sysconfdir}/dnf/plugins/changetrack_ng.conf

%{_mandir}/man8/changetrack-ng.8*
%{_mandir}/man5/changetrack-ng.conf.5*


%changelog
* Mon Jun 29 2026 Christopher Cashell <topher@zyp.org> - 0.7.0-1
- Security hardening release (consolidated multi-tool security review)
- Explicit TLS verification (verify_SSL=1) on webhook and otlp notifiers
- Redact credentials (URI userinfo, tokens) in debug traces, config dumps,
  and webhook/VCS push failure warnings
- Strip CR/LF/NUL from OTLP headers; sendmail '--' terminator and header
  CR/LF stripping; skip relative PATH entries when locating sendmail
- Reject '..' in track paths; assert whole-repo mirror paths stay in output_dir
- Atomic metadata save via File::Temp (O_EXCL, 0600); lock file opened with
  O_NOFOLLOW and no bare /tmp fallback; revert re-checks regular file
- New command_timeout global (default 120s) bounds external commands so a hung
  command cannot hang a scheduled run
- run_cmd drains to EOF (no truncation) and reports signal termination
- status/diff/log fail loudly on backend errors; notifier failures warn and are
  recorded; failed metadata save aborts before commit
- Add ctime to the fast path (catches same-size, mtime-restored edits)
- RCS colon-encoding collision fixed; webhook honors max_diff_bytes and zeroes
  sensitive line counts when the diff is suppressed
- Numerous correctness/POD fixes (see CHANGELOG.md)
* Thu Jun 25 2026 Christopher Cashell <topher@zyp.org> - 0.6.1-1
- OTel conformance: canonical attribute model on the otlp and file notifiers
  (file.path/name/directory, config_change.type/sensitive/diff, file.mode/owner/
  group/size, changetrack.files_tracked/run_duration_ms) and namespaced event
  names (changetrack.file.changed/created/removed, run.heartbeat, run.warning)
- Add occurred-time vs observed-time: occurred = file mtime (timestamp /
  timeUnixNano), observed = scan start (observed_timestamp / observedTimeUnixNano)
- File notifier now emits one OTel record per event as append-only NDJSON,
  replacing the single-object-per-run format
- Add config keys (otlp and file): emit_recipients, max_diff_bytes,
  severity_change, severity_heartbeat, severity_warning
- Fix: register the new notifier keys in the config-file parse whitelist so
  setting them no longer aborts parsing

* Tue May 19 2026 Christopher Cashell <topher@zyp.org> - 0.6.0-1
- BREAKING: Notifier configuration redesigned; [notifier:<type>:<name>] subsections
  replace the flat notify= list and all prefixed notifier keys (email_to, email_from,
  webhook_url, otlp_endpoint, otlp_headers, notify_log_path, file_heartbeat, etc.)
- BREAKING: migrate-config subcommand removed
- Add drop-in directory support: conf.d/ ([global] only), track.d/ ([track] only),
  notifier.d/ ([notifier:*] only); scanned automatically in sorted order
- Add @include, @include-track, @include-notifier directives; directories process
  *.conf files in sorted order; visited-paths guard prevents infinite recursion
- Add multi-instance notifiers: multiple [notifier:<type>:<name>] sections produce
  independent notifier objects; duplicate instance names are a fatal parse error
- Add t/24-config-sections.t, t/25-config-drop-in-dirs.t,
  t/26-config-include-directives.t, t/27-config-cross-file-errors.t
- Install creates conf.d/, track.d/, notifier.d/ under /etc/changetrack-ng/

* Thu May 15 2026 Christopher Cashell <topher@zyp.org> - 0.5.5-1
- Add --system and --user flags for explicit config scope declaration
- Add CHANGETRACK_CONFIG env var (beats --system/--user; loses to -c)
- Source /etc/default/changetrack-ng (Debian) or /etc/sysconfig/changetrack-ng (RHEL)
  from cron, systemd, and all package manager hooks; template installed by make install-hooks
- Add DEFAULTSDIR Makefile variable with auto-detection via 'command -v dnf'
- Add t/23-config-resolution.t: 8-test suite for config resolution priority

* Wed May 14 2026 Christopher Cashell <topher@zyp.org> - 0.5.4-1
- Add three-tier diagnostic system: --verbose/-v (high-level run structure),
  --debug/-d (external commands + effective config with secrets redacted),
  --trace/-t (per-file disposition for every tracked path, O(N) output).
  Implication chain: --trace enables --debug; --debug enables --verbose.
  All diagnostic output goes to STDERR; STDOUT stays clean.
- Add t/22-verbose-debug.t: 42-test suite for the diagnostic tiers
- Add PRODUCT.md and CONTRIBUTING.md project documentation files

* Tue May 12 2026 Christopher Cashell <topher@zyp.org> - 0.5.3-1
- Fix: Fossil backend sets FOSSIL_HOME when HOME is absent (systemd service
  environment), resolving "not within an open check-out" errors

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
