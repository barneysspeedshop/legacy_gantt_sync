#!/usr/bin/env python3
"""Use checked-out packages before coordinated versions are published to pub.dev."""
from pathlib import Path

root = Path(__file__).resolve().parent.parent
packages = {
    'legacy_gantt_chart': {
        'legacy_gantt_protocol': '../legacy_gantt_protocol',
        'legacy_timeline_scrubber': '../legacy_timeline_scrubber',
    },
    'legacy_gantt_chart/example': {
        'legacy_gantt_protocol': '../../legacy_gantt_protocol',
        'legacy_timeline_scrubber': '../../legacy_timeline_scrubber',
        'legacy_tree_grid': '../../legacy_tree_grid',
        'legacy_context_menu': '../../legacy_context_menu',
    },
    'legacy_tree_grid/example': {
        'legacy_context_menu': '../../legacy_context_menu',
    },
    'legacy_pert_chart': {
        'legacy_gantt_protocol': '../legacy_gantt_protocol',
        'legacy_gantt_chart': '../legacy_gantt_chart',
        'legacy_timeline_scrubber': '../legacy_timeline_scrubber',
    },
    'legacy_pert_chart/example': {
        'legacy_gantt_protocol': '../../legacy_gantt_protocol',
        'legacy_gantt_chart': '../../legacy_gantt_chart',
        'legacy_timeline_scrubber': '../../legacy_timeline_scrubber',
    },
    'legacy_gantt_plugin/webview_ui': {
        'legacy_gantt_protocol': '../../legacy_gantt_protocol',
        'legacy_timeline_scrubber': '../../legacy_timeline_scrubber',
    },
}
for directory, dependencies in packages.items():
    path = root / directory / 'pubspec_overrides.yaml'
    content = 'dependency_overrides:\n' + ''.join(
        f'  {name}:\n    path: {relative}\n' for name, relative in dependencies.items())
    if path.exists() and path.read_text() != content:
        previous = [
            'dependency_overrides:\n' + ''.join(
                f'  {name}:\n    path: {relative}\n'
                for name, relative in dependencies.items() if name not in omitted)
            for omitted in (
                {'legacy_context_menu'},
                {'legacy_tree_grid', 'legacy_context_menu'},
                {'legacy_tree_grid', 'legacy_timeline_scrubber', 'legacy_context_menu'},
            )
        ]
        if directory == 'legacy_gantt_plugin/webview_ui' or path.read_text() not in previous:
            raise SystemExit(f'Refusing to overwrite existing local overrides: {path}')
    path.write_text(content)
    print(f'Configured local packages for {directory}')
