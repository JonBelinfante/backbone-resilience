"""Tests for the failure detector."""

from dataclasses import replace

import pytest

from failover_controller.detector import Detector, Observation, Verdict

GOOD = Observation(
    writer_answers=True,
    writer_in_recovery=False,
    standby_answers=True,
    standby_in_recovery=True,
    standby_receiving=True,
)
WRITER_DEAD = replace(GOOD, writer_answers=False, standby_receiving=False)
WRITER_CUT_OFF = replace(GOOD, writer_answers=False)
STANDBY_DEAD = replace(WRITER_DEAD, standby_answers=False, standby_in_recovery=False)
STANDBY_PROMOTED = replace(WRITER_DEAD, standby_in_recovery=False)


def test_healthy_writer_is_healthy() -> None:
    """A writer that answers and accepts writes is healthy."""
    assert Detector(3).observe(GOOD) is Verdict.HEALTHY


def test_failures_below_the_threshold_only_raise_suspicion() -> None:
    """Two failed probes of three do not decide anything."""
    detector = Detector(3)
    assert detector.observe(WRITER_DEAD) is Verdict.SUSPECT
    assert detector.observe(WRITER_DEAD) is Verdict.SUSPECT


def test_threshold_failures_in_a_row_fail_over() -> None:
    """The third failed probe, with the standby hearing nothing, decides to fail over."""
    detector = Detector(3)
    verdicts = [detector.observe(WRITER_DEAD) for _ in range(3)]
    assert verdicts[-1] is Verdict.FAIL_OVER


def test_one_success_resets_the_count() -> None:
    """A pause shorter than the threshold never fails over."""
    detector = Detector(3)
    detector.observe(WRITER_DEAD)
    detector.observe(WRITER_DEAD)
    assert detector.observe(GOOD) is Verdict.HEALTHY
    assert detector.observe(WRITER_DEAD) is Verdict.SUSPECT


def test_cut_off_from_a_live_writer_does_not_fail_over() -> None:
    """If the standby still hears the writer, the controller is the one cut off."""
    detector = Detector(2)
    detector.observe(WRITER_CUT_OFF)
    assert detector.observe(WRITER_CUT_OFF) is Verdict.HOLD_WRITER_ALIVE


def test_no_usable_standby_means_no_fail_over() -> None:
    """Failing over to a dead or already promoted standby is refused."""
    assert Detector(1).observe(STANDBY_DEAD) is Verdict.CANNOT_FAIL_OVER
    assert Detector(1).observe(STANDBY_PROMOTED) is Verdict.CANNOT_FAIL_OVER


def test_writer_that_is_read_only_is_reported() -> None:
    """A node that answers but is in recovery is not a writer."""
    observation = replace(GOOD, writer_in_recovery=True)
    assert Detector(3).observe(observation) is Verdict.WRITER_READ_ONLY


def test_threshold_below_one_is_refused() -> None:
    """A threshold of zero would fail over on no evidence."""
    with pytest.raises(ValueError, match="at least 1"):
        Detector(0)
