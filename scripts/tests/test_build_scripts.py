"""Workflow checks using real package archives and mocked Arch/Docker commands.
Run with: python3 -m unittest discover -s scripts/tests -v
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import io

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'scripts'

MOCK = r'''#!/usr/bin/env python3
import io, json, os, pathlib, subprocess, sys, tarfile
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['COMMAND_LOG'], 'a') as f:
    f.write(json.dumps([name, *args]) + '\n')
if name == 'sudo':
    sys.exit(subprocess.call(args))
if name == 'pacman':
    sys.exit(127 if '-T' in args and os.environ.get('INSTALLED_QRTR') != '1' else 0)
if name == 'vercmp':
    print(1 if args[0] != '1.0-1' else -1)
if name == 'docker':
    if args[-2:] == ['uname', '-m']:
        print('aarch64')
if name == 'makepkg':
    package = pathlib.Path.cwd().name
    with open(os.environ['BUILD_LOG'], 'a') as f:
        f.write(package + '\n')
    if os.environ.get('FAIL_BUILD') == package:
        sys.exit(1)
    assert '--syncdeps' in args and '--nodeps' not in args
    assert '--force' in args and '--nosign' in args
    names = [package, package + '-headers'] if package == 'linux-yoga' else [package]
    for package in names:
        data = ('pkgname = ' + package + '\npkgver = 2.0-1\narch = aarch64\n').encode()
        out = pathlib.Path(os.environ['PKGDEST']) / (package + '-2.0-1-aarch64.pkg.tar.gz')
        with tarfile.open(out, 'w:gz') as tar:
            info = tarfile.TarInfo('.PKGINFO')
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
if name == 'repo-add':
    assert args.pop(0) == '--include-sigs'
    if os.environ.get('FAIL_REPO') == '1':
        sys.exit(1)
    for archive in args[1:]:
        assert not archive.endswith('.sig'), archive
        with tarfile.open(archive) as tar:
            assert tar.extractfile('.PKGINFO').read()
    db = pathlib.Path(args[0])
    db.write_text('\n'.join(pathlib.Path(p).name for p in args[1:]))
    files = db.with_name(db.name.replace('.db.', '.files.'))
    files.write_text('file list')
    db.with_name('yoga-alarm.db').symlink_to(db.name)
    files.with_name('yoga-alarm.files').symlink_to(files.name)
'''


@unittest.skipUnless(shutil.which('bsdtar'), 'bsdtar is required')
class BuildScriptsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='yoga build test ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for command in ('sudo', 'pacman', 'makepkg', 'repo-add', 'vercmp', 'docker'):
            path = self.bin / command
            path.write_text(MOCK)
            path.chmod(0o755)
        self.packages = self.root / 'packages'
        self.repo = self.packages / 'repo'
        self.repo.mkdir(parents=True)
        self.incoming = self.root / 'incoming'
        self.incoming.mkdir()
        self.log = self.root / 'commands.jsonl'
        self.build_log = self.root / 'builds'
        self.conf = self.root / 'pacman.conf'
        self.conf.write_text('[options]\n')
        for path in (ROOT / 'packages').glob('*/PKGBUILD'):
            target = self.packages / path.parent.name
            target.mkdir()
            (target / 'PKGBUILD').write_text(path.read_text())
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        PKGS_DIR=str(self.packages), PACMAN_CONF=str(self.conf),
                        COMMAND_LOG=str(self.log), BUILD_LOG=str(self.build_log))

    def run_command(self, command, success=True):
        result = subprocess.run(command, env=self.env, cwd='/tmp', text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def build(self, *names, success=True):
        return self.run_command(['bash', str(SCRIPTS / 'docker' / 'build-packages.sh'), *names], success)

    def update(self, publish=False, success=True):
        return self.run_command(['bash', '-euo', 'pipefail', '-c',
                                 'source "$1"; update_repo "$2" "${3:-}"', 'test',
                                 str(SCRIPTS / 'lib' / 'repo-common.sh'), str(self.repo),
                                 *([str(self.incoming)] if publish else [])], success)

    def archive(self, directory, name='demo', version='1.0-1', arch='aarch64', ext='gz'):
        path = directory / f'{name}-{version}-{arch}.pkg.tar.{ext}'
        data = f'pkgname = {name}\npkgver = {version}\narch = {arch}\n'.encode()
        with tarfile.open(path, 'w:' + ext) as tar:
            info = tarfile.TarInfo('.PKGINFO')
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        return path

    def signature(self, archive):
        path = Path(str(archive) + '.sig')
        path.write_text('old signature')
        return path

    def builds(self):
        return self.build_log.read_text().splitlines() if self.build_log.exists() else []

    def commands(self, name):
        return [row for row in map(json.loads, self.log.read_text().splitlines()) if row[0] == name]

    def test_single_package_ignores_source_archives(self):
        self.archive(self.packages / 'edk2-shell-aa64', 'edk2-shell-aa64', '99-1')
        self.build('edk2-shell-aa64')
        self.assertEqual(self.builds(), ['edk2-shell-aa64'])
        self.assertEqual(len(list(self.repo.glob('*.pkg.tar.*'))), 1)
        self.assertFalse(list(self.repo.glob('.build-*')))

    def test_all_packages_in_dependency_order(self):
        self.build()
        self.assertEqual(self.builds(), ['qmic-git', 'qrtr-git', 'tqftpserv-git',
                         'pd-mapper-git', 'firmware-lenovo-yoga-c630',
                         'alsa-ucm-conf-yoga-c630', 'edk2-shell-aa64', 'linux-yoga'])
        self.assertTrue(list(self.repo.glob('linux-yoga-headers-*.pkg.tar.gz')))

    def test_duplicate_selection_order(self):
        self.build('edk2-shell-aa64', 'qmic-git', 'edk2-shell-aa64')
        self.assertEqual(self.builds(), ['qmic-git', 'edk2-shell-aa64'])

    def test_unknown_name_before_side_effects(self):
        self.build('unknown', success=False)
        self.assertFalse(self.log.exists())
        self.assertEqual(self.conf.read_text(), '[options]\n')
        self.run_command(['bash', str(SCRIPTS / 'host' / 'run-docker-build.sh'), 'unknown'], False)
        self.assertFalse(self.log.exists())

    def test_help_without_docker(self):
        for script in (SCRIPTS / 'docker' / 'build-packages.sh',
                       SCRIPTS / 'host' / 'run-docker-build.sh'):
            self.assertIn('linux-yoga', self.run_command(['bash', str(script), '--help']).stdout)

        self.assertFalse(self.log.exists())

    def test_missing_dependency_built_once(self):
        self.build('pd-mapper-git', 'tqftpserv-git')
        self.assertEqual(self.builds(), ['qrtr-git', 'tqftpserv-git', 'pd-mapper-git'])

    def test_reuse_local_dependency(self):
        self.archive(self.repo, 'qrtr-git', '1.1-1')
        self.build('pd-mapper-git')
        self.assertEqual(self.builds(), ['pd-mapper-git'])

    def test_insufficient_or_wrong_arch_dependency(self):
        self.archive(self.repo, 'qrtr-git', '1.0-1')
        self.archive(self.repo, 'qrtr-git', '1.1-1', 'x86_64')
        self.build('tqftpserv-git')
        self.assertEqual(self.builds(), ['qrtr-git', 'tqftpserv-git'])

    def test_installed_dependency(self):
        self.env['INSTALLED_QRTR'] = '1'
        self.build('pd-mapper-git')
        self.assertEqual(self.builds(), ['pd-mapper-git'])

    def test_replacement_matches_metadata_and_architecture(self):
        old = self.archive(self.repo, 'linux-yoga')
        sig = self.signature(old)
        header = self.archive(self.repo, 'linux-yoga-headers')
        other_arch = self.archive(self.repo, 'linux-yoga', arch='x86_64')
        other_package = self.archive(self.repo, 'demo', ext='xz')
        self.archive(self.incoming, 'linux-yoga', '2.0-1')
        self.update(True)
        self.assertFalse(old.exists())
        self.assertFalse(sig.exists())
        for archive in (header, other_arch, other_package):
            self.assertTrue(archive.exists())

    def test_same_filename_overwritten_and_signature_invalidated(self):
        old = self.archive(self.repo)
        sig = self.signature(old)
        new = self.archive(self.incoming)
        with open(new, 'ab') as output:
            output.write(b'changed bytes')
        self.update(True)
        self.assertEqual(old.read_bytes(), new.read_bytes())
        self.assertFalse(sig.exists())
        self.assertTrue((self.repo / 'yoga-alarm.db').is_file())

    def test_signatures_filtered_and_retained(self):
        archive = self.archive(self.repo, ext='xz')
        sig = self.signature(archive)
        (self.repo / 'orphan.pkg.tar.gz.sig').write_text('orphan')
        (self.repo / 'fake.pkg.tar.gz').mkdir()
        self.update()
        self.assertTrue(sig.exists())
        self.assertEqual(self.commands('repo-add')[0][3:], [str(archive)])

    def test_database_failure_preserves_repository(self):
        old = self.archive(self.repo)
        sig = self.signature(old)
        database = self.repo / 'yoga-alarm.db.tar.gz'
        database.write_text('original db')
        self.archive(self.incoming, version='2.0-1')
        before = {p.name: p.read_bytes() for p in self.repo.iterdir()}
        self.env['FAIL_REPO'] = '1'
        self.update(True, False)
        for name, data in before.items():
            self.assertEqual((self.repo / name).read_bytes(), data)
        self.assertTrue(sig.exists())
        self.assertFalse(list(self.repo.glob('.rebuild-repo.*')))
        self.assertFalse(list(self.repo.glob('*2.0-1*')))

    def test_build_failure_preserves_archives_and_signatures(self):
        old = self.archive(self.repo, 'edk2-shell-aa64')
        sig = self.signature(old)
        self.env['FAIL_BUILD'] = 'edk2-shell-aa64'
        self.build('edk2-shell-aa64', success=False)
        self.assertTrue(old.exists())
        self.assertTrue(sig.exists())
        self.assertFalse(list(self.repo.glob('.build-*')))

    def test_empty_repository_keeps_database(self):
        database = self.repo / 'yoga-alarm.db.tar.gz'
        database.write_text('original')
        self.update(success=False)
        self.assertEqual(database.read_text(), 'original')
        self.assertFalse(self.log.exists())

    def test_host_forwarding_and_paths_outside_project(self):
        self.run_command(['bash', str(SCRIPTS / 'host' / 'run-docker-build.sh'),
                          'edk2-shell-aa64', 'qmic-git', 'edk2-shell-aa64'])
        docker = self.commands('docker')
        self.assertEqual(docker[-1][-3:], ['/scripts/docker/build-packages.sh', 'qmic-git', 'edk2-shell-aa64'])
        self.assertIn(str(ROOT / 'packages') + ':/packages', docker[-1])
        self.assertEqual(docker[-2][-1], str(ROOT))

    @unittest.skipUnless(os.environ.get('YOGA_TEST_DOCKER') == '1',
                         'set YOGA_TEST_DOCKER=1 to test the existing ARM64 image')
    def test_real_arm64_repo_add(self):
        old = self.archive(self.repo)
        old_sig = self.signature(old)
        retained = self.archive(self.repo, 'demo-headers')
        retained_sig = self.signature(retained)
        self.archive(self.incoming, version='2.0-1')

        def docker(script, success=True):
            command = ['docker', 'run', '--rm', '--platform', 'linux/arm64',
                       '--user', f'{os.getuid()}:{os.getgid()}',
                       '--mount', f'type=bind,source={self.root},target=/work',
                       '--mount', f'type=bind,source={SCRIPTS},target=/scripts,readonly',
                       '--entrypoint', '/bin/bash',
                       os.environ.get('IMAGE_NAME', 'archlinuxarm-build'),
                       '-euo', 'pipefail', '-c',
                       'source /scripts/lib/repo-common.sh; ' + script]
            result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE)
            if success:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            else:
                self.assertNotEqual(result.returncode, 0)
            return result

        docker('update_repo /work/packages/repo /work/incoming')
        self.assertFalse(old.exists())
        self.assertFalse(old_sig.exists())
        self.assertTrue(retained_sig.exists())
        self.assertTrue((self.repo / 'yoga-alarm.db').is_file())
        result = docker('update_repo /work/packages/repo; '
                        'bsdtar -xOf /work/packages/repo/yoga-alarm.db '
                        'demo-headers-1.0-1/desc')
        self.assertIn('%PGPSIG%', result.stdout)
        self.assertIn('%FILENAME%', result.stdout)
        self.assertIn(retained.name, result.stdout)
        before = {p.name: p.read_bytes() for p in self.repo.iterdir()}
        invalid = self.archive(self.incoming, version='3.0-1')
        Path(str(invalid) + '.sig').write_text('-----BEGIN PGP SIGNATURE-----')
        result = docker('update_repo /work/packages/repo /work/incoming', False)
        self.assertIn('Cannot use armored signatures', result.stderr + result.stdout)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.repo.iterdir()})
        self.assertFalse(list(self.repo.glob('.rebuild-repo.*')))

    def test_rebuild_mounts_shared_helper(self):
        self.env['REPO_DIR'] = str(self.repo)
        self.run_command(['bash', str(SCRIPTS / 'host' / 'rebuild-repo.sh')])
        call = self.commands('docker')[0]
        self.assertIn('type=bind,source=' + str(SCRIPTS) + ',target=/scripts,readonly', call)
        self.assertIn('source /scripts/lib/repo-common.sh', call[-1])


if __name__ == '__main__':
    unittest.main()
