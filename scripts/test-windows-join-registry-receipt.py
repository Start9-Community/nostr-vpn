#!/usr/bin/env python3
"""Exercise registry receipt validation using supplied real release evidence."""
import argparse
import copy
import importlib.util
import json
import pathlib
import tempfile

parser = argparse.ArgumentParser()
for name in ('desktop', 'source', 'installer', 'fips-repo'):
    parser.add_argument('--' + name, type=pathlib.Path, required=True)
inputs = parser.parse_args()
spec = importlib.util.spec_from_file_location(
    'receipt', pathlib.Path(__file__).with_name('desktop_mobile_manual_join_receipt.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
desktop = module.load_json(inputs.desktop, 'desktop')
source = module.load_json(inputs.source, 'source')
installer = module.load_json(inputs.installer, 'installer')
args = argparse.Namespace(
    platform='windows', windows_fips_repo=inputs.fips_repo,
    expected_desktop_app_sha=desktop['appGitSha'],
    expected_desktop_app_tree=desktop['appGitTree'],
    expected_desktop_fips_sha=desktop['fipsGitSha'],
    expected_desktop_fips_tree=desktop['fipsGitTree'],
    expected_desktop_fips_version=desktop['fipsVersion'],
)
with tempfile.TemporaryDirectory(prefix='nvpn-registry-receipt-test-') as work:
    args.windows_source_receipt = pathlib.Path(work) / 'source.json'
    args.windows_installer_receipt = pathlib.Path(work) / 'installer.json'
    def check(name, mutate, accepted):
        d, s, i = copy.deepcopy((desktop, source, installer))
        mutate(d, s, i)
        args.windows_source_receipt.write_text(json.dumps(s))
        args.windows_installer_receipt.write_text(json.dumps(i))
        try:
            proof = module.validate_windows_registry_binding(args, d)
            module.validate_desktop_receipt(
                d, 'windows', args.expected_desktop_app_sha, args.expected_desktop_app_tree,
                args.expected_desktop_fips_sha, args.expected_desktop_fips_tree,
                args.expected_desktop_fips_version, proof)
        except ValueError:
            if accepted:
                raise
        else:
            if not accepted:
                raise AssertionError('Invalid evidence accepted: ' + name)
        print('PASS ' + name)
    check('actual registry source and installed payload', lambda d,s,i: None, True)
    def runtime(d, suffix):
        lines = d['artifacts']['cli']['verboseVersion'].splitlines()
        d['artifacts']['cli']['verboseVersion'] = '\n'.join(
            'fips_core_version: ' + desktop['fipsVersion'] + suffix
            if line.startswith('fips_core_version:') else line for line in lines)
    check('wrong runtime version', lambda d,s,i: d['artifacts']['cli'].update(verboseVersion='fips_core_version: 0.0.0'), False)
    check('wrong nonempty revision', lambda d,s,i: runtime(d, ' (rev aaaaaaaaaa)'), False)
    check('dirty revision', lambda d,s,i: runtime(d, ' (rev ' + desktop['fipsGitSha'][:10] + '-dirty)'), False)
    check('mismatched CLI hash', lambda d,s,i: d['artifacts']['cli'].update(sha256='0'*64), False)
    check('mismatched GUI hash', lambda d,s,i: d['artifacts']['app'].update(sha256='0'*64), False)
    check('wrong locked checksum', lambda d,s,i: s['fipsCrates']['nvpn-fips-core'].update(cargoLockChecksum='0'*64), False)
    check('wrong package VCS', lambda d,s,i: s['fipsCrates']['nvpn-fips-core'].update(packageVcsSha='0'*40), False)
    check('unaccepted installer', lambda d,s,i: i.update(installerInstalledAndLaunched=False), False)
try:
    module.validate_desktop_receipt(
        desktop, 'windows', args.expected_desktop_app_sha, args.expected_desktop_app_tree,
        args.expected_desktop_fips_sha, args.expected_desktop_fips_tree,
        args.expected_desktop_fips_version)
except ValueError:
    print('PASS missing registry proof')
else:
    raise AssertionError('Version-only runtime accepted without registry proof')
print('WINDOWS_JOIN_REGISTRY_RECEIPT_OK cases=10')
