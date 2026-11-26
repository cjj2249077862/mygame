"""Chapter-one art, interaction and audio acceptance; --static-only never runs Godot.

Retains all phase-two regressions and adds presentation/resource checks. Automated
success still requires the user's visual, sound and interaction review.
"""
from accept_phase_one import main
from accept_phase_two import SUITES as PHASE_TWO_SUITES

SUITES = PHASE_TWO_SUITES + ('test_presentation', 'test_interaction')

if __name__ == '__main__':
    raise SystemExit(main(phase=3, suites=SUITES))
