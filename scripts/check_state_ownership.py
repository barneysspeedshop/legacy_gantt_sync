#!/usr/bin/env python3
"""Keep entity persistence behind the example's canonical local state owner."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
view_model = root / 'legacy_gantt_chart/example/lib/view_models/gantt_view_model.dart'
source = view_model.read_text()
read_model_methods = {
    'init', 'getAllTasks', 'getAllResources', 'getAllDependencies',
    'getLastServerSyncTimestamp', 'setLastServerSyncTimestamp',
}
violations = []
for match in re.finditer(r'_localRepository\.(\w+)\s*\(', source):
    if match[1] not in read_model_methods:
        line = source.count('\n', 0, match.start()) + 1
        violations.append(f'{view_model.relative_to(root)}:{line}: direct read-model mutation {match[1]}')
main = (root / 'legacy_gantt_chart/example/lib/main.dart').read_text()
if re.search(r'syncClient:\s*vm\.syncClient\b', main):
    violations.append('The chart widget must receive the presence-only connection; entity writes belong to canonical state.')
if violations:
    print('\n'.join(violations), file=sys.stderr)
    sys.exit(1)
print('Canonical state owns example entity persistence; widget transport is limited to presence.')
