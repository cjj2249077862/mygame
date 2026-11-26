"""First-chapter acceptance; --static-only never starts Godot.

Requires the confirmed chapter data, combat/Boss rules, map/save validation,
transactions, actual scenes, and reproducible full chapter simulations.
Uses the same fail-closed runner as phase one, including log-error detection,
timeouts, structured assertions, and a fingerprint of the checked source.
"""
from accept_phase_one import main

SUITES = (
    'test_game_data', 'test_battle_rules', 'test_boss_rules',
    'test_map_generator', 'test_save_manager', 'test_run_flow',
    'test_chapter_flow', 'test_battle_ui', 'test_chapter_ui', 'test_battle_sim',
)

if __name__ == '__main__':
    raise SystemExit(main(phase=2, suites=SUITES))
