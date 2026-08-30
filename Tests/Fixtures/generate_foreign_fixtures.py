#!/usr/bin/env python3
"""Generates the FitEngine test fixtures committed alongside this script:
foreign_drop/ (a complete, valid drop with no relation to the bundled sample
fixture the rest of the suite is built around) plus five malformed
variants, each demonstrating exactly one PanelLoader rejection.

Everything here is a closed-form function of the week/geo/channel index --
no RNG, no timestamps, no external input -- so re-running this script
reproduces byte-identical output. That determinism is the point: these
files are committed as plain data, and this script is committed next to
them only as the record of how they were produced, not as something the
test suite runs.

Usage: python3 generate_foreign_fixtures.py
(re-)writes every fixture directory next to this script.
"""
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))


def date_for_week(t):
    # 2024-01-01 is a Monday; every fixture uses Monday-anchored ISO weeks
    # so lexicographic sort of the date strings equals chronological order.
    import datetime
    d = datetime.date(2024, 1, 1) + datetime.timedelta(days=7 * t)
    return d.isoformat()


def write_csv(path, header, rows):
    with open(path, "w", newline="\n") as f:
        f.write(",".join(header) + "\n")
        for row in rows:
            f.write(",".join(str(v) for v in row) + "\n")


# ---------------------------------------------------------------------------
# foreign_drop: 64 weeks, two geos, four channels none of which are in
# FitEngine's ChannelRegistry, one control, no treatments file.
# ---------------------------------------------------------------------------

def build_foreign_drop():
    out = os.path.join(HERE, "foreign_drop")
    os.makedirs(out, exist_ok=True)

    weeks = 64
    geos = ["east", "west"]
    geo_mult = {"east": 1.0, "west": 0.82}
    geo_kpi_offset = {"east": 0.0, "west": -35.0}
    channels = ["linkedin_ads", "podcast_sponsorship", "out_of_home", "email_nurture"]
    channel_base = {
        "linkedin_ads": 900.0,
        "podcast_sponsorship": 320.0,
        "out_of_home": 260.0,
        "email_nurture": 60.0,
    }

    kpi_rows = []
    paid_rows = []
    control_rows = []

    for t in range(weeks):
        date = date_for_week(t)
        trend = 1.8 * t
        season = 45.0 * math.sin(2 * math.pi * t / 13.0)
        wiggle = ((t * 37) % 23) - 11  # deterministic pseudo-noise, no RNG
        for geo in geos:
            kpi_value = max(50.0, 480.0 + trend + season + geo_kpi_offset[geo] + wiggle)
            kpi_rows.append((date, geo, "demo_requests", round(kpi_value, 1)))

            control_value = round(math.sin(2 * math.pi * t / 52.0), 4)
            control_rows.append((date, geo, "seasonality_index", control_value))

            for ci, ch in enumerate(channels):
                phase = ci * 3
                spend_wiggle = ((t * 13 + ci * 7) % 17) - 8
                spend = channel_base[ch] * geo_mult[geo] * (1 + 0.15 * math.sin(2 * math.pi * (t + phase) / 26.0))
                spend = max(10.0, spend + spend_wiggle)
                paid_rows.append((date, geo, ch, round(spend, 2)))

    write_csv(os.path.join(out, "kpi.csv"), ["date_week", "geo", "kpi_name", "kpi_value"], kpi_rows)
    write_csv(os.path.join(out, "paid_media.csv"), ["date_week", "geo", "channel", "spend"], paid_rows)
    write_csv(os.path.join(out, "controls.csv"), ["date_week", "geo", "control_name", "control_value"], control_rows)
    # Deliberately no non_media_treatments.csv: the packet asks for a drop
    # with controls but no treatments file, to exercise PanelLoader's
    # existing "file absent -> zero controls from it" path for treatments.


# ---------------------------------------------------------------------------
# Malformed variants: minimal single-geo, single-channel, 52-week drops
# (the minimum weeks PanelLoader will accept), each carrying exactly one
# defect. No controls/treatments files -- both are optional inputs, so
# omitting them keeps these fixtures minimal without exercising anything
# these tests are not about.
# ---------------------------------------------------------------------------

def minimal_valid_rows(weeks=52, kpi_name="demo_requests", geo="us", channel="test_channel"):
    kpi_rows = []
    paid_rows = []
    for t in range(weeks):
        date = date_for_week(t)
        kpi_value = round(300.0 + 2.0 * t + 20.0 * math.sin(2 * math.pi * t / 13.0), 1)
        spend = round(150.0 + 1.0 * t + 10.0 * math.sin(2 * math.pi * t / 11.0), 2)
        kpi_rows.append([date, geo, kpi_name, kpi_value])
        paid_rows.append([date, geo, channel, spend])
    return kpi_rows, paid_rows


def build_fixture_nan_kpi():
    out = os.path.join(HERE, "fixture_nan_kpi")
    os.makedirs(out, exist_ok=True)
    kpi_rows, paid_rows = minimal_valid_rows()
    # Row 10 (1-based data row 10, i.e. index 9): kpi_value becomes "nan".
    kpi_rows[9][3] = "nan"
    write_csv(os.path.join(out, "kpi.csv"), ["date_week", "geo", "kpi_name", "kpi_value"], kpi_rows)
    write_csv(os.path.join(out, "paid_media.csv"), ["date_week", "geo", "channel", "spend"], paid_rows)


def build_fixture_inf_spend():
    out = os.path.join(HERE, "fixture_inf_spend")
    os.makedirs(out, exist_ok=True)
    kpi_rows, paid_rows = minimal_valid_rows()
    # Row 20 (1-based data row 20, i.e. index 19): spend becomes "inf".
    paid_rows[19][3] = "inf"
    write_csv(os.path.join(out, "kpi.csv"), ["date_week", "geo", "kpi_name", "kpi_value"], kpi_rows)
    write_csv(os.path.join(out, "paid_media.csv"), ["date_week", "geo", "channel", "spend"], paid_rows)


def build_fixture_short_12wk():
    out = os.path.join(HERE, "fixture_short_12wk")
    os.makedirs(out, exist_ok=True)
    kpi_rows, paid_rows = minimal_valid_rows(weeks=12)
    write_csv(os.path.join(out, "kpi.csv"), ["date_week", "geo", "kpi_name", "kpi_value"], kpi_rows)
    write_csv(os.path.join(out, "paid_media.csv"), ["date_week", "geo", "channel", "spend"], paid_rows)


def build_fixture_mixed_kpi_name():
    out = os.path.join(HERE, "fixture_mixed_kpi_name")
    os.makedirs(out, exist_ok=True)
    kpi_rows, paid_rows = minimal_valid_rows()
    # Row 30 (1-based data row 30, i.e. index 29): a second, conflicting
    # kpi_name value.
    kpi_rows[29][2] = "signups"
    write_csv(os.path.join(out, "kpi.csv"), ["date_week", "geo", "kpi_name", "kpi_value"], kpi_rows)
    write_csv(os.path.join(out, "paid_media.csv"), ["date_week", "geo", "channel", "spend"], paid_rows)


def build_fixture_negative_spend():
    out = os.path.join(HERE, "fixture_negative_spend")
    os.makedirs(out, exist_ok=True)
    kpi_rows, paid_rows = minimal_valid_rows()
    # Row 15 (1-based data row 15, i.e. index 14): a negative spend value.
    paid_rows[14][3] = -50.0
    write_csv(os.path.join(out, "kpi.csv"), ["date_week", "geo", "kpi_name", "kpi_value"], kpi_rows)
    write_csv(os.path.join(out, "paid_media.csv"), ["date_week", "geo", "channel", "spend"], paid_rows)


if __name__ == "__main__":
    build_foreign_drop()
    build_fixture_nan_kpi()
    build_fixture_inf_spend()
    build_fixture_short_12wk()
    build_fixture_mixed_kpi_name()
    build_fixture_negative_spend()
    print("wrote foreign_drop/ and 5 malformed fixture directories under", HERE)
