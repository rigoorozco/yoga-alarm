"""Staged kernel workflow tests with real hashes, ELF parsing and archives.
Run on the host with: python3 -m unittest discover -s scripts/tests -v

Compilers/makepkg are mocked; these tests do not replace the Docker integration
build and external-module check documented in docs/kernel.md.
"""
import io
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / 'scripts/docker/build-kernel-cross.sh'
COMMON = ROOT / 'scripts/lib/kernel-cross-common.sh'

MOCK = r'''#!/usr/bin/env python3
import gzip, io, os, pathlib, shutil, struct, subprocess, sys, tarfile
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
package = pathlib.Path(os.environ['FIXTURE_PACKAGE'])
tree = package / 'src/linux-test'
failure = os.environ.get('FAIL_STAGE')
def elf(machine=183):
    return struct.pack('<16sHHIQQQIHHHHHH', b'\x7fELF\x02\x01\x01' + b'\0'*9,
                       2, machine, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0)
def write(path, data, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    if executable: path.chmod(0o755)
def tools(root, machine):
    for p in ['scripts/basic/fixdep', 'scripts/mod/modpost']:
        write(root / p, elf(machine), True)
if name == 'sudo':
    if args[:1] == ['-E']: args.pop(0)
    sys.exit(subprocess.call(args))
elif name in ('gcc', 'aarch64-linux-gnu-gcc'):
    print('fixture compiler ' + name)
elif name == 'ccache':
    print('fixture cache statistics')
elif name == 'pacman':
    pass
elif name == 'makepkg':
    if '--verifysource' in args:
        if not (package / 'source.tar').exists():
            write(package / 'source.tar', b'fixture source archive')
    elif '--nobuild' in args:
        if failure == 'prepare': sys.exit(1)
        root = pathlib.Path.cwd() / 'src/linux-test'
        write(root / 'Makefile', b'# fixture\n')
        write(root / '.config', b'CONFIG_MODULES=y\n')
    else:
        assert '--repackage' in args and '--cleanbuild' not in args
        if failure == 'package': sys.exit(1)
        release = (tree / 'version').read_text().strip()
        for pkg in ('linux-yoga', 'linux-yoga-headers'):
            output = pathlib.Path(os.environ['PKGDEST']) / (pkg + '.pkg.tar.gz')
            with tarfile.open(output, 'w:gz') as tar:
                arch = os.environ.get('PACKAGE_ARCH', 'aarch64')
                version = os.environ.get('PACKAGE_VERSION', '1-1')
                files = {'.PKGINFO': f'pkgname = {pkg}\npkgver = {version}\narch = {arch}\n'.encode()}
                if pkg.endswith('-headers'):
                    prefix = 'usr/lib/modules/' + release + '/build/'
                    for p in ('.config', 'Module.symvers', 'System.map', 'vmlinux', 'version'):
                        files[prefix + p] = (tree / p).read_bytes()
                    for p in ('scripts/basic/fixdep', 'scripts/mod/modpost'):
                        machine = 62 if os.environ.get('WRONG_HEADERS') else 183
                        files[prefix + p] = elf(machine)
                else:
                    files['boot/Image'] = (tree / 'arch/arm64/boot/Image').read_bytes()
                    files['boot/Image.gz'] = (tree / 'arch/arm64/boot/Image.gz').read_bytes()
                    files['boot/dtbs/qcom/sdm850-lenovo-yoga-c630.dtb'] = (tree / 'arch/arm64/boot/dts/board.dtb').read_bytes()
                    files['usr/lib/modules/' + release + '/kernel/test.ko'] = elf()
                for p, data in files.items():
                    info = tarfile.TarInfo(p)
                    info.size = len(data)
                    info.mode = 0o755 if p.endswith(('fixdep', 'modpost', 'vmlinux')) else 0o644
                    tar.addfile(info, io.BytesIO(data))
elif name == 'make':
    if any(a.startswith('M=') for a in args):
        if failure == 'module': sys.exit(1)
        module = pathlib.Path(next(a[2:] for a in args if a.startswith('M=')))
        write(module / 'check.ko', elf())
    elif '-C' in args:
        native = pathlib.Path(args[args.index('-C') + 1])
        if 'modules_prepare' in args:
            if failure == 'tools': sys.exit(1)
            tools(native, 183)
            if os.environ.get('TAMPER_COMPILED'):
                write(tree / 'test.ko', b'tampered')
    else:
        if failure == 'compile': sys.exit(1)
        (tree / 'include/generated').mkdir(parents=True, exist_ok=True)
        (tree / 'arch/arm64/include/generated').mkdir(parents=True, exist_ok=True)
        for p in ('Module.symvers', 'System.map', 'include/generated/autoconf.h'):
            write(tree / p, b'fixture\n')
        write(tree / 'vmlinux', elf(), True)
        write(tree / 'test.ko', elf())
        write(tree / 'version', b'1-test\n')
        image = b'\0' * 56 + b'ARM\x64'
        write(tree / 'arch/arm64/boot/Image', image)
        write(tree / 'arch/arm64/boot/Image.gz', gzip.compress(image))
        dtb = tree / 'arch/arm64/boot/dts/board.dtb'
        dtb.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['dtc', '-q', '-I', 'dts', '-O', 'dtb', '-o', str(dtb)],
                       input=b'/dts-v1/; / { };', check=True)
        tools(tree, 62)
elif name == 'modinfo':
    print('1-test SMP')
elif name == 'repo-add':
    assert args.pop(0) == '--include-sigs'
    db = pathlib.Path(args[0])
    db.write_text('validated repository')
    db.with_name('yoga-alarm.db').symlink_to(db.name)
'''


@unittest.skipUnless(all(shutil.which(p) for p in ('bsdtar', 'readelf', 'dtc', 'python')),
                     'bsdtar, readelf, dtc and python are required')
class KernelCrossTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='kernel cross test ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.package = self.root / 'packages/linux-yoga'
        self.package.mkdir(parents=True)
        self.state = self.package / '.cross-build'
        self.repo = self.package.parent / 'repo'
        self.repo.mkdir()
        self.old = self.repo / 'old.pkg.tar.gz'
        with tarfile.open(self.old, 'w:gz') as tar:
            data = b'pkgname = linux-yoga\npkgver = old\narch = aarch64\n'
            info = tarfile.TarInfo('.PKGINFO')
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        self.old_bytes = self.old.read_bytes()
        (self.package / 'PKGBUILD').write_text('''
pkgbase=linux-yoga
pkgver=1
pkgrel=1
_srcname=linux-test
source=(source.tar)
build() { cd "$_srcname"; make ${MAKEFLAGS} all; }
''')
        (self.package / 'source.tar').write_bytes(b'fixture source archive')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for command in ('sudo', 'makepkg', 'make', 'gcc', 'aarch64-linux-gnu-gcc',
                        'ccache', 'pacman', 'modinfo', 'repo-add'):
            script = self.bin / command
            script.write_text(MOCK)
            script.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        PKGS_DIR=str(self.package.parent), FIXTURE_PACKAGE=str(self.package))

    def stage(self, name, success=True):
        result = subprocess.run(['bash', str(BUILDER), name], cwd='/tmp', env=self.env,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertEqual(self.old.read_bytes(), self.old_bytes)
            self.assertFalse(list(self.repo.glob('.build-*')))
        return result

    def test_completed_cross_build_validates_and_publishes_both_packages(self):
        self.stage('compile')
        self.assertTrue((self.state / 'complete').is_file())
        result = self.stage('package')
        self.assertIn('external-module validation', result.stdout)
        self.assertFalse(self.old.exists())
        self.assertTrue((self.repo / 'linux-yoga.pkg.tar.gz').is_file())
        self.assertTrue((self.repo / 'linux-yoga-headers.pkg.tar.gz').is_file())

    def test_packaging_requires_successful_cross_build(self):
        self.stage('package', False)

    def test_first_build_downloads_sources_before_recording_handoff(self):
        (self.package / 'source.tar').unlink()
        self.stage('compile')
        self.stage('package')

    def test_prepare_and_compile_failures_do_not_leave_completion_marker(self):
        for stage in ('prepare', 'compile'):
            with self.subTest(stage=stage):
                self.env['FAIL_STAGE'] = stage
                self.stage('compile', False)
                self.assertFalse((self.state / 'complete').exists())

    def test_failed_rebuild_invalidates_previous_completion(self):
        self.stage('compile')
        self.env['FAIL_STAGE'] = 'compile'
        self.stage('compile', False)
        self.assertFalse((self.state / 'complete').exists())

    def test_source_change_invalidates_handoff(self):
        self.stage('compile')
        (self.package / 'source.tar').write_bytes(b'changed')
        self.stage('package', False)

    def test_native_stage_cannot_change_completed_kernel_outputs(self):
        self.stage('compile')
        self.env['TAMPER_COMPILED'] = '1'
        self.stage('package', False)

    def test_packaging_and_validation_failures_preserve_published_packages(self):
        self.stage('compile')
        for stage in ('tools', 'package', 'module'):
            with self.subTest(stage=stage):
                self.env['FAIL_STAGE'] = stage
                self.stage('package', False)

    def test_wrong_archive_architecture_version_or_headers_tools_are_rejected(self):
        self.stage('compile')
        for key, value in [('PACKAGE_ARCH', 'x86_64'), ('PACKAGE_VERSION', 'wrong'),
                           ('WRONG_HEADERS', '1')]:
            with self.subTest(key=key):
                self.env[key] = value
                self.stage('package', False)
                del self.env[key]

    def test_real_pkgbuild_replaces_only_headers_tools(self):
        tree = self.package / 'src/linux-7.3'
        native = self.root / 'native'
        files = ['.config', 'Makefile', 'Module.symvers', 'System.map', 'version',
                 'kernel/Makefile', 'arch/arm64/Makefile', 'arch/arm64/kernel/asm-offsets.s',
                 'include/generated/autoconf.h', 'arch/arm64/include/test.h',
                 'arch/arm/include/test.h', 'drivers/md/test.h', 'net/mac80211/test.h',
                 'drivers/media/i2c/msp3400-driver.h', 'drivers/media/usb/dvb-usb/test.h',
                 'drivers/media/dvb-frontends/test.h', 'drivers/media/tuners/test.h',
                 'drivers/iio/common/hid-sensors/test.h']
        for path in files:
            file = tree / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('1-test\n' if path == 'version' else 'original\n')
        def elf(machine):
            return struct.pack('<16sHHIQQQIHHHHHH', b'\x7fELF\x02\x01\x01' + b'\0'*9,
                               2, machine, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0)
        (tree / 'vmlinux').write_bytes(elf(183))
        relative = 'scripts/basic/fixdep'
        for root, machine in [(tree, 62), (native, 183)]:
            file = root / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(elf(machine))
            file.chmod(0o755)
        script = tree / 'scripts/helper.sh'
        script.write_text('#!/bin/sh\nexit 0\n')
        script.chmod(0o755)
        for directory in tree.rglob('*'):
            if directory.is_dir():
                directory.chmod(0o775)
        output = self.root / 'headers'
        command = ['bash', '-eo', 'pipefail', '-c',
                   'source "$1"; cd "$2"; pkgdir=$3; KERNEL_HEADERS_TOOLS=$4; '
                   'STRIP_SHARED=; STRIP_STATIC=; STRIP_BINARIES=; strip() { :; }; '
                   '_package-headers', 'test', str(ROOT / 'packages/linux-yoga/PKGBUILD'),
                   str(tree.parent), str(output), str(native)]
        result = subprocess.run(command, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        build = output / 'usr/lib/modules/1-test/build'
        self.assertEqual((build / relative).read_bytes(), elf(183))
        self.assertEqual((tree / relative).read_bytes(), elf(62))
        self.assertEqual((build / '.config').read_text(), 'original\n')
        self.assertEqual((build / 'scripts/helper.sh').read_bytes(), script.read_bytes())
        for directory in output.rglob('*'):
            if directory.is_dir() and not directory.is_symlink():
                self.assertEqual(directory.stat().st_mode & 0o7777, 0o755, str(directory))

        (native / relative).unlink()
        result = subprocess.run(command, env=self.env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing ARM64 headers tool', result.stderr)

    def test_real_kernel_package_excludes_depmod_indexes_and_normalizes_directories(self):
        tree = self.package / 'src/linux-7.3'
        (tree / 'arch/arm64/boot').mkdir(parents=True)
        (tree / 'version').write_text('1-test\n')
        for name in ('Image', 'Image.gz'):
            (tree / 'arch/arm64/boot' / name).write_bytes(b'fixture image')
        for name in ('linux.preset', '60-linux.hook', '90-linux.hook'):
            shutil.copyfile(ROOT / 'packages/linux-yoga' / name, tree.parent / name)
        output = self.root / 'kernel-package'
        command = ['bash', '-eo', 'pipefail', '-c', r'''
source "$1"
cd "$2"
pkgdir=$3
pkgname=linux-yoga
MAKEFLAGS=ARCH=arm64
make() {
  if [[ " $* " == *' modules_install '* ]]; then
    [[ " $* " == *' DEPMOD=true '* ]] || return 1
    local modulesdir="$pkgdir/usr/lib/modules/1-test"
    mkdir -p "$modulesdir/kernel"
    chmod 775 "$modulesdir/kernel"
    touch "$modulesdir/kernel/test.ko"
    touch "$modulesdir"/modules.{dep,dep.bin,alias,alias.bin,softdep,weakdep,symbols,symbols.bin,builtin.bin,builtin.alias.bin,devname}
    touch "$modulesdir"/modules.{order,builtin,builtin.modinfo,builtin.ranges}
    ln -s /build/workspace "$modulesdir/build"
    ln -s /build/workspace "$modulesdir/source"
  fi
}
_package
''', 'test', str(ROOT / 'packages/linux-yoga/PKGBUILD'), str(tree.parent), str(output)]
        result = subprocess.run(command, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        modulesdir = output / 'usr/lib/modules/1-test'
        self.assertEqual(sorted(p.name for p in modulesdir.glob('modules.*')),
                         ['modules.builtin', 'modules.builtin.modinfo',
                          'modules.builtin.ranges', 'modules.order'])
        self.assertTrue((modulesdir / 'kernel/test.ko').is_file())
        self.assertFalse((modulesdir / 'build').is_symlink())
        self.assertFalse((modulesdir / 'source').is_symlink())
        hook = output / 'usr/share/libalpm/hooks/60-linux-yoga.hook'
        self.assertIn('Exec = /usr/bin/depmod 1-test', hook.read_text())
        for directory in output.rglob('*'):
            if directory.is_dir():
                self.assertEqual(directory.stat().st_mode & 0o7777, 0o755, str(directory))
