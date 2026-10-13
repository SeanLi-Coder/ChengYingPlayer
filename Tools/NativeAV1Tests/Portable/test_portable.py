"""Offline launcher controls. Fake processes never count as hardware evidence."""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("portable_builder", HERE / "build.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


@unittest.skipUnless(sys.platform == "darwin", "Target launcher requires macOS system tools")
class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="av1-offline-test.")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "bundle with spaces"
        self.root.mkdir()

    def make(self, scenario="pass", minimum=26):
        for folder in ("bin", "lib", "fixtures"):
            (self.root / folder).mkdir(exist_ok=True)
        for name in builder.LIBRARIES:
            (self.root / "lib" / name).write_bytes(b"Offline fake library; never loaded")
        for name in builder.FIXTURES:
            (self.root / "fixtures" / name).write_bytes(b"Offline fake fixture; never decoded")
        executable = self.root / "bin/native-av1-tests"
        program = r'''#!/usr/bin/perl
use strict;
use warnings;
die "Unexpected command" unless @ARGV == 2 && $ARGV[1] eq 'hardware';
die "Inherited environment" if exists $ENV{HOME} || exists $ENV{AV1_TEST_SECRET} || exists $ENV{PERL5OPT};
die "Wrong PATH" unless $ENV{PATH} eq '/usr/bin:/bin:/usr/sbin:/sbin';
my $root = $ARGV[0]; $root =~ s{/fixtures$}{};
my $scenario = 'SCENARIO';
if ($scenario eq 'timeout') { sleep 5; }
if ($scenario eq 'signal') { kill 'KILL', $$; }
if ($scenario eq 'inherited_pipe') {
    my $child = fork(); die unless defined $child;
    if (!$child) { sleep 2; exit 0; }
}
if ($scenario eq 'tamper') { open my $o, '>>', "$root/fixtures/av1-8.mkv" or die; print {$o} 'changed'; close $o; }
print "PRIVATE /Users/private/hidden/video.mkv account=do-not-record\n";
print "dyld[$$]: move loaded to delayed: SystemOnly\n";
for my $name (qw(LIBRARIES)) {
    my $dir = $scenario eq 'foreign_library' ? '/untrusted/lib' : "$root/lib";
    print "dyld[$$]: <TEST-UUID> $dir/$name\n" unless $scenario eq 'missing_library';
}
for my $depth (8, 10) {
    next if $depth == 10 && $scenario eq 'missing_depth';
    my $software = $scenario eq 'software' ? 1 : 0;
    my $hw = $software ? 0 : 24;
    print "ACTUAL AV1 depth=$depth native_opens=1 software_opens=$software fallback=$software frames=24 vt=$hw hardware=$hw\n";
}
print "FAIL: synthetic failure\n" if $scenario eq 'failure_line';
my $checks = $scenario eq 'short_count' ? 1 : 1738;
my $strict = $scenario eq 'not_strict' ? 0 : 1;
my $summary = "Native AV1 checks=$checks failures=0 strict_hardware=$strict\n";
print $summary unless $scenario eq 'missing_summary';
print $summary if $scenario eq 'double_summary';
exit($scenario eq 'bad_exit' ? 1 : 0);
'''.replace("SCENARIO", scenario).replace("LIBRARIES", " ".join(sorted(builder.LIBRARIES)))
        executable.write_text(program)
        executable.chmod(0o755)
        launcher = self.root / "Run-M4-AV1-Check.command"
        launcher.write_text(builder.SHELL_LAUNCHER)
        launcher.chmod(0o755)
        guide = self.root / "README.txt"
        guide.write_text("Offline unit test; no hardware evidence\n")
        files = {str(p.relative_to(self.root)): builder.sha(p) for p in self.root.rglob('*') if p.is_file()}
        policy = {"schema": 1, "minimum_macos": minimum, "architecture": "arm64", "expected_checks": 1738,
                  "timeout_seconds": 1, "files": files, "libraries": sorted(builder.LIBRARIES)}
        verifier = self.root / "verify-and-run.pl"
        verifier.write_text(builder.render_launcher(policy))
        (self.root / "manifest.json").write_text(json.dumps({"files": {**files, verifier.name: builder.sha(verifier)}}))
        return launcher

    def invoke(self, verify_only=False):
        command = ["/bin/sh", str(self.root / "Run-M4-AV1-Check.command")]
        if verify_only:
            command.append("--verify-only")
        result = subprocess.run(command, env={**os.environ, "PERL5OPT": "-MNonexistentBadModule", "AV1_TEST_SECRET": "no"},
                                capture_output=True, text=True, timeout=8)
        reports = sorted((self.root / "reports").glob('run-*/report.json'))
        self.assertEqual(len(reports), 1, result.stderr)
        report_text = reports[0].read_text()
        self.assertNotIn("PRIVATE", report_text)
        self.assertNotIn("account", report_text)
        self.assertNotIn(str(self.root), report_text)
        self.assertNotIn("/Users", report_text)
        self.assertNotIn("TEST-UUID", report_text)
        return result, json.loads(report_text)

    def test_simulated_pass_and_clean_environment(self):
        self.make()
        result, report = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report["status"], "PASS")
        self.assertTrue(report["loaded_libraries_verified"])
        self.assertTrue(report["post_hashes_verified"])

    def test_verify_only_never_runs_binary(self):
        self.make("signal")
        result, report = self.invoke(True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(report["status"], "VERIFIED_NOT_RUN")
        self.assertFalse(report["hardware_acceptance"])
        self.assertNotIn("child_exit_code", report)

    def test_platform_gate(self):
        self.make(minimum=999)
        result, report = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(report["error_category"], "platform_requires_arm64_macos26")
        self.assertNotIn("child_exit_code", report)

    def test_failed_outputs_cannot_pass(self):
        for scenario in ("software", "bad_exit", "signal", "timeout", "inherited_pipe", "foreign_library", "missing_library",
                         "missing_depth", "missing_summary", "double_summary", "short_count", "not_strict", "failure_line"):
            with self.subTest(scenario=scenario):
                # Keep each run's reports independent without changing a live bundle.
                old_root = self.root
                self.root = old_root / scenario
                self.root.mkdir()
                self.make(scenario)
                result, report = self.invoke()
                self.assertEqual(result.returncode, 1)
                self.assertEqual(report["status"], "FAIL")
                self.assertFalse(report["hardware_acceptance"])
                self.assertTrue(report["post_hashes_verified"])
                if scenario == "timeout": self.assertEqual(report["termination"], "timeout")
                if scenario == "signal": self.assertNotEqual(report["child_signal"], 0)
                if scenario == "inherited_pipe":
                    self.assertEqual(report["child_exit_code"], 0)
                    self.assertEqual(report["child_signal"], 0)
                    self.assertEqual(report["termination"], "timeout")
                self.root = old_root

    def test_post_run_mutation_rejected(self):
        self.make("tamper")
        result, report = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertTrue(report["pre_hashes_verified"])
        self.assertFalse(report["post_hashes_verified"])
        self.assertEqual(report["error_category"], "integrity_changed_file")

    def test_pre_run_damage_rejected(self):
        for scenario in ("missing", "changed", "extra", "symlink", "manifest", "traversal", "verifier"):
            with self.subTest(scenario=scenario):
                old_root = self.root
                self.root = old_root / scenario
                self.root.mkdir()
                self.make()
                target = self.root / "fixtures/av1-8.mkv"
                if scenario == "missing": target.unlink()
                if scenario == "changed": target.write_bytes(b"wrong")
                if scenario == "extra": (self.root / "lib/foreign.dylib").write_bytes(b"unexpected")
                if scenario == "symlink":
                    target.unlink()
                    target.symlink_to(self.root / "fixtures/av1-10.mkv")
                if scenario == "manifest": (self.root / "manifest.json").write_text("{")
                if scenario == "traversal":
                    manifest = json.loads((self.root / "manifest.json").read_text())
                    manifest["files"]["../outside"] = "0" * 64
                    (self.root / "manifest.json").write_text(json.dumps(manifest))
                if scenario == "verifier":
                    with (self.root / "verify-and-run.pl").open('a') as stream: stream.write("\n# Changed\n")
                result, report = self.invoke()
                self.assertEqual(result.returncode, 1)
                self.assertFalse(report["pre_hashes_verified"])
                self.assertFalse(report["hardware_acceptance"])
                self.assertNotIn("child_exit_code", report)
                self.root = old_root


class BuilderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="av1-builder-test.")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_hash_rejects_changed_missing_and_symlink(self):
        target = self.root / "asset"
        target.write_bytes(b"expected")
        digest = builder.sha(target)
        builder.verify(target, digest)
        target.write_bytes(b"changed")
        with self.assertRaises(ValueError): builder.verify(target, digest)
        target.unlink()
        with self.assertRaises(ValueError): builder.verify(target, digest)
        target.symlink_to(self.root / "absent")
        with self.assertRaises(ValueError): builder.verify(target, digest)

    def test_only_unreaped_owned_child_can_be_killed(self):
        source = (HERE / 'launch.pl.in').read_text()
        self.assertEqual(source.count("kill 'KILL', $pid;"), 1)
        self.assertIn("if (!defined $status) {\n                kill 'KILL', $pid;\n                waitpid($pid, 0);\n                $status = $?;\n            }", source)

    def test_bad_macho_rejected(self):
        target = self.root / "binary"
        for data in (b"", b"not a Mach-O" * 10, struct.pack('<8I', 0xFEEDFACF, 0x100000C, 0, 2, 1, 99, 0, 0)):
            target.write_bytes(data)
            with self.assertRaises(ValueError): builder.macho(target)

    def test_macho_build_metadata(self):
        target = self.root / "binary"
        target.write_bytes(struct.pack('<8I', 0xFEEDFACF, 0x100000C, 0, 2, 1, 24, 0, 0)
                           + struct.pack('<6I', 0x32, 24, 1, 26 << 16, 27 << 16, 0))
        self.assertEqual(builder.macho(target)["minimum"], (26, 0, 0))

    def test_evidence_record_rejects_duplicates_and_changes(self):
        target = self.root / "asset"
        target.write_bytes(b"data")
        manifest = self.root / "source.sha256"
        line = builder.sha(target) + "  " + str(target) + "\n"
        manifest.write_text(line)
        builder.verify_record(manifest)
        for text in ("", line + line, "0" * 64 + "  " + str(target) + "\n", "invalid"):
            manifest.write_text(text)
            with self.assertRaises(ValueError): builder.verify_record(manifest)

    def test_dependency_closure_rejects_uncontrolled_paths(self):
        binary = self.root / "native-av1-tests"
        dependencies = ["@rpath/" + name for name in builder.LIBRARIES]
        metadata = {"kind": 2, "minimum": (26, 0, 0), "dependencies": dependencies}
        def inspection(path):
            return metadata if path == binary else {"dependencies": ["/usr/lib/libSystem.B.dylib"]}
        with mock.patch.object(builder, "macho", side_effect=inspection):
            builder.validate_closure(binary, self.root)
            for bad in ("/opt/homebrew/lib/foreign.dylib", "@rpath/foreign.dylib", "@loader_path/libavutil.59.dylib"):
                metadata["dependencies"] = dependencies + [bad]
                with self.assertRaises(ValueError): builder.validate_closure(binary, self.root)
            metadata["dependencies"] = dependencies[:-1]
            with self.assertRaises(ValueError): builder.validate_closure(binary, self.root)
            metadata["dependencies"] = dependencies
            metadata["minimum"] = (27, 0, 0)
            with self.assertRaises(ValueError): builder.validate_closure(binary, self.root)


if __name__ == '__main__':
    unittest.main()
