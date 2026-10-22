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
