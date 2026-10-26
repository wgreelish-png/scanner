#!/usr/bin/env python3
"""Read-only diagnosis of missing Swift files in the app's Xcode target. No dependencies on macOS."""
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'CardShowScanner.xcodeproj' / 'project.pbxproj'
REQUIRED = sorted(p.name for p in (ROOT / 'CardShowScanner').glob('*.swift'))


def check(project):
    objects = project['objects']
    targets = [o for o in objects.values() if o.get('isa') == 'PBXNativeTarget' and o.get('name') == 'CardShowScanner']
    if len(targets) != 1:
        raise ValueError('Expected exactly one CardShowScanner application target.')
    sources = []
    for phase_id in targets[0].get('buildPhases', []):
        phase = objects[phase_id]
        if phase.get('isa') == 'PBXSourcesBuildPhase':
            for build_id in phase.get('files', []):
                ref = objects.get(objects.get(build_id, {}).get('fileRef'), {})
                sources.append(Path(ref.get('path', '')).name)
    failures = 0
    for filename in REQUIRED:
        exists = (ROOT / 'CardShowScanner' / filename).is_file()
        included = sources.count(filename) == 1
        print(f'{filename}: on disk={exists}; in app Compile Sources={included}')
        failures += not (exists and included)
    test_targets = [o for o in objects.values() if o.get('isa') == 'PBXNativeTarget' and o.get('name') == 'CardShowScannerTests']
    if len(test_targets) != 1:
        raise ValueError('Expected one native test target.')
    test_sources = []
    test_resources = []
    resources = []
    for target, destination, phase_kind in [(test_targets[0], test_sources, 'PBXSourcesBuildPhase'), (targets[0], resources, 'PBXResourcesBuildPhase'), (test_targets[0], test_resources, 'PBXResourcesBuildPhase')]:
        for phase_id in target.get('buildPhases', []):
            phase = objects[phase_id]
            if phase.get('isa') == phase_kind:
                for build_id in phase.get('files', []):
                    file = objects[objects[build_id]['fileRef']]
                    destination.append(Path(file.get('path', '')).name)
    expected_tests = sorted(p.name for p in (ROOT / 'Tests').glob('*.swift'))
    for filename in expected_tests:
        included = test_sources.count(filename) == 1 and filename not in sources
        print(f'{filename}: in test target only={included}')
        failures += not included
    ui_targets = [o for o in objects.values() if o.get('isa') == 'PBXNativeTarget' and o.get('name') == 'CardShowScannerUITests']
    if len(ui_targets) != 1:
        raise ValueError('Expected one UI regression test target.')
    ui_sources = []
    for phase_id in ui_targets[0].get('buildPhases', []):
        phase = objects[phase_id]
        if phase.get('isa') == 'PBXSourcesBuildPhase':
            for build_id in phase.get('files', []):
                ref = objects.get(objects.get(build_id, {}).get('fileRef'), {})
                ui_sources.append(Path(ref.get('path', '')).name)
    for file in sorted((ROOT / 'UITests').glob('*.swift')):
        included = ui_sources.count(file.name) == 1 and file.name not in sources and file.name not in test_sources
        print(f'{file.name}: in UI test target only={included}')
        failures += not included
    for filename in ['TCGTrackingBridge.js', 'PricingRequest.js', 'WebsiteSignIn.js', 'ScannerRuntime', 'PrivacyInfo.xcprivacy']:
        included = resources.count(filename) == 1
        print(f'{filename}: in application Copy Bundle Resources={included}')
        failures += not included
    fixture_in_tests = test_resources.count('Fixtures') == 1 and 'Fixtures' not in resources
    print('Captured public-price fixture: in test resources only=', fixture_in_tests)
    failures += not fixture_in_tests
    for object in objects.values():
        if object.get('isa') == 'XCBuildConfiguration':
            settings = object.get('buildSettings', {})
            if settings.get('PRODUCT_NAME') == '$(TARGET_NAME)' and settings.get('PRODUCT_BUNDLE_IDENTIFIER') == 'com.cardshow.CardShowScanner':
                failures += settings.get('INFOPLIST_FILE') != 'Config/AppInfo.plist'
    print('App Compile Sources count:', len(sources))
    return failures


def main():
    commit = subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], cwd=ROOT, text=True, capture_output=True)
    print('Checkout commit:', commit.stdout.strip() or 'unknown')
    status = subprocess.run(['git', 'status', '--short', '--', str(PROJECT.relative_to(ROOT))], cwd=ROOT, text=True, capture_output=True)
    print('Project locally modified:', bool(status.stdout.strip()))
    if sys.platform == 'darwin':
        result = subprocess.run(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(PROJECT)], capture_output=True, text=True)
        if result.returncode:
            raise ValueError('Apple plutil could not parse the project. ' + result.stderr.strip())
        project = json.loads(result.stdout)
    else:
        # Development-only fallback; macOS uses its built-in plutil above.
        from openstep_parser import OpenStepDecoder
        with PROJECT.open() as handle:
            project = OpenStepDecoder.ParseFromFile(handle)
    failed = check(project)
    if failed:
        print('FIX: Xcode > app target > Build Phases > Compile Sources > +. Add each missing file to the application target.')
    else:
        print('All required files are present and assigned to the app target.')
        print('If Xcode still reports missing types, send the FIRST error from a fresh build and the SwiftCompile input list from Report Navigator (Cmd-9).')
        print('Verify that the open project is this checkout and accept Reload from Disk if Xcode prompts.')
    return 1 if failed else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, ImportError) as error:
        print('Diagnostic could not complete:', str(error), file=sys.stderr)
        sys.exit(2)
