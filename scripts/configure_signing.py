#!/usr/bin/env python3
"""Save a local development team without editing Xcode's tracked project."""
import argparse
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / 'Config' / 'Signing.local.xcconfig'


def team_from_project(path):
    teams = set(re.findall(r'\bDEVELOPMENT_TEAM\s*=\s*"?([A-Z0-9]{10})"?\s*;', path.read_text()))
    if len(teams) != 1:
        raise ValueError('Could not find one unambiguous team. Supply --team YOUR_TEAM_ID instead.')
    return teams.pop()


def configure(team, destination=DESTINATION):
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ValueError('Team ID must contain exactly 10 uppercase letters/digits.')
    contents = '// Personal signing setting; intentionally ignored by Git.\nDEVELOPMENT_TEAM = ' + team + '\n'
    if destination.exists():
        if destination.read_text() == contents:
            return False
        raise ValueError('Local signing configuration already exists. Edit it directly to change teams; it was not overwritten.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open('x') as handle:
        handle.write(contents)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--team', help='10-character Apple development team ID')
    source.add_argument('--from-project', type=Path, help='Previously saved project.pbxproj containing your team')
    args = parser.parse_args()
    try:
        team = args.team or team_from_project(args.from_project)
        changed = configure(team)
        print('Local signing configuration saved.' if changed else 'Local signing configuration is already configured.')
        print('Reopen Xcode. The app and tests inherit the team; avoid selecting it again in the project editor.')
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
