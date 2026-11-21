package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.DynamicTest.dynamicTest;

import java.util.List;
import java.util.stream.Stream;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestFactory;

/**
 * The std/time profile (spec/std/time.md), with the vectors of the Go and TypeScript tests, which
 * cover every row of the spec's table, and the strings of the schema suite's std/time cases.
 */
class StdTimeTest {
  private static final String NINES = "9".repeat(400);

  private static final String[][] VALID = {
    {"Date", "2026-11-09"}, {"Date", "2024-02-29"}, {"Date", "2000-02-29"}, {"Date", "0000-01-01"},
    {"Date", "9999-12-31"}, {"Date", "2026-11-13"},
    {"Time", "00:00:00"}, {"Time", "23:59:59.999999999"}, {"Time", "14:30:00.250"},
    {"DateTime", "2026-11-09T14:30:00"}, {"DateTime", "2026-11-09T14:30:00.25"},
    {"Instant", "2026-11-09T14:30:00Z"}, {"Instant", "2026-11-09T14:30:00+01:00"},
    {"Instant", "2026-11-09T14:30:00.5-23:59"}, {"Instant", "2026-11-13T10:00:00.250+01:00"},
    {"Instant", "2026-11-13T10:00:00+00:00"},
    {"ZonedDateTime", "2027-03-29T10:00:00+01:00[Europe/Lisbon]"},
    {"ZonedDateTime", "2027-03-29T10:00:00+01:00[Europe/Atlantis]"},
    {"ZonedDateTime", "2027-03-29T10:00:00+05:00[Europe/Lisbon]"},
    {"ZonedDateTime", "2026-11-09T14:30:00Z[+01:00]"},
    {"ZonedDateTime", "2026-11-09T14:30:00-05:00[America/Port-au-Prince]"},
    {"ZonedDateTime", "2026-11-09T14:30:00Z[America/Argentina/Buenos_Aires]"},
    {"Duration", "PT30S"}, {"Duration", "P1Y2M3W4DT5H6M7.5S"}, {"Duration", "-PT1H"}, {"Duration", "PT0S"},
    {"Duration", "PT0.000S"}, {"Duration", "P1DT0.5S"}, {"Duration", "PT0.5S"}, {"Duration", "PT0.05S"},
    {"Duration", "-PT0.001S"}, {"Duration", "-P10D"}, {"Duration", "-P1DT12H"}, {"Duration", "PT1.50S"},
    {"Duration", "P4294967295Y"}, {"Duration", "P4294967295M"}, {"Duration", "P4294967295W"},
    {"Duration", "PT9007199254740991S"}, {"Duration", "P104249991374D"},
    {"Duration", "PT2501999792983H"}, {"Duration", "PT150119987579016M"},
    {"Duration", "P104249991374DT0.999999999S"}, {"Duration", "P104249991374DT27391S"},
    {"YearMonth", "2026-11"}, {"YearMonth", "0000-01"},
    {"TimeZone", "Europe/Lisbon"}, {"TimeZone", "UTC"}, {"TimeZone", "Etc/GMT+1"}, {"TimeZone", "-03:30"},
    {"TimeZone", "Z"}, {"TimeZone", "a/..."}, {"TimeZone", "x.y/_z"}, {"TimeZone", "a".repeat(255)},
  };

  private static final String[][] INVALID = {
    {"Date", "2026-02-30", "2026-02 has no day 30"},
    {"Date", "2026-02-29", "2026 is not a leap year"},
    {"Date", "1900-02-29", "1900 is not a leap year"},
    {"Date", "2026-04-31", "2026-04 has no day 31"},
    {"Date", "2026-13-01", "month 13 doesn't exist"},
    {"Date", "2026-00-10", "month 00 doesn't exist"},
    {"Date", "20261109", "write it like 2026-11-09"},
    {"Date", "+12026-11-09", "write it like"},
    {"Date", "-0001-01-01", "write it like"},
    {"Date", "2026-W45-1", "write it like"},
    {"Date", "2026-313", "write it like"},
    {"Date", "2026-11-13T10:00:00Z", "write it like"},
    {"Time", "14:30", "write it like 14:30:00"},
    {"Time", "24:00:00", "24:00 is not allowed"},
    {"Time", "25:00:00", "hour 25 doesn't exist"},
    {"Time", "23:59:60", "leap seconds (:60) are not allowed"},
    {"Time", "23:59:61", "second 61 doesn't exist"},
    {"Time", "12:60:00", "minute 60 doesn't exist"},
    {"Time", "12:00:00.1234567890", "write it like"},
    {"Time", "12:00:00.", "write it like"},
    {"DateTime", "2026-11-09t14:30:00", "write it like"},
    {"DateTime", "2026-11-09 14:30:00", "write it like"},
    {"DateTime", "2026-11-09T14:30:00Z", "write it like"},
    {"Instant", "2026-11-09T14:30:00", "write it like 2026-11-09T14:30:00Z"},
    {"Instant", "2026-11-13T10:00:00", "write it like"},
    {"Instant", "2026-11-09T14:30:00z", "write it like"},
    {"Instant", "2026-11-09T14:30:00+0100", "write it like"},
    {"Instant", "2026-11-09T14:30:00-00:00", "-00:00 is not allowed; write Z"},
    {"Instant", "2026-11-09T14:30:00+24:00", "offset +24:00 is out of range"},
    {"Instant", "2026-11-09T14:30:00+01:60", "offset +01:60 is out of range"},
    {"Instant", "2016-12-31T23:59:60Z", "leap seconds"},
    {"ZonedDateTime", "2027-03-29T10:00:00[Europe/Lisbon]", "write it like"},
    {"ZonedDateTime", "2027-03-29T10:00:00+01:00", "write it like"},
    {"ZonedDateTime", "2027-03-29T10:00:00+01:00[!Europe/Lisbon]", "not an IANA zone name"},
    {"ZonedDateTime", "2027-03-29T10:00:00+01:00[Europe/Lisbon][u-ca=iso8601]", "write it like"},
    {"ZonedDateTime", "2027-03-29T10:00:00+01:00[Europe/../etc]", "not an IANA zone name"},
    {"ZonedDateTime", "2027-03-29T10:00:00+01:00[Europe//Lisbon]", "not an IANA zone name"},
    {"ZonedDateTime", "2027-03-29T10:00:00+01:00[-00:00]", "-00:00 is not allowed; write Z"},
    {"ZonedDateTime", "2027-02-29T10:00:00+01:00[!]", "2027 is not a leap year"},
    {"Duration", "P", "at least one component"},
    {"Duration", "PT", "at least one component"},
    {"Duration", "P1DT", "T must be followed"},
    {"Duration", "+PT1H", "write it like"},
    {"Duration", "PT1.5H", "write it like"},
    {"Duration", "PT1.S", "write it like"},
    {"Duration", "PT1.1234567890S", "write it like"},
    {"Duration", "p1d", "write it like"},
    {"Duration", "P1D2Y", "write it like"},
    {"Duration", "P4294967296Y", "too large"},
    {"Duration", "P4294967296W", "too large"},
    {"Duration", "P104249991375D", "below 2^53 seconds"},
    {"Duration", "PT9007199254740992S", "below 2^53 seconds"},
    {"Duration", "P104249991374DT27392S", "below 2^53 seconds"},
    {"Duration", "P" + NINES + "Y", "too large"},
    {"Duration", "PT" + NINES + "S", "below 2^53 seconds"},
    {"Duration", "P" + NINES + "D", "below 2^53 seconds"},
    {"Duration", "P01D", "leading zero"},
    {"Duration", "PT00S", "leading zero"},
    {"Duration", "PT01.5S", "leading zero"},
    {"Duration", "-P0D", "a duration leaves out components that are zero"},
    {"Duration", "-PT0S", "a zero duration has no sign"},
    {"Duration", "-PT0.000S", "a zero duration has no sign"},
    {"Duration", "-P0Y0M", "a duration leaves out components that are zero"},
    {"Duration", "P0D", "a duration leaves out components that are zero"},
    {"Duration", "P1DT0S", "a duration leaves out components that are zero"},
    {"Duration", "P0Y1D", "a duration leaves out components that are zero"},
    {"Duration", "PT1H0M", "a duration leaves out components that are zero"},
    {"Duration", "PT1M0.0S", "a duration leaves out components that are zero"},
    {"Duration", "P1DT0.00S", "a duration leaves out components that are zero"},
    {"Duration", "P1Y0W", "a duration leaves out components that are zero"},
    {"Duration", "PT0H1S", "a duration leaves out components that are zero"},
    {"Duration", "PT0M0S", "a duration leaves out components that are zero"},
    {"YearMonth", "2026-13", "month 13 doesn't exist"},
    {"YearMonth", "2026-00", "month 00 doesn't exist"},
    {"YearMonth", "2026-1", "write it like"},
    {"TimeZone", "europe lisbon", "not an IANA zone name"},
    {"TimeZone", "/Lisbon", "not an IANA zone name"},
    {"TimeZone", "Europe/", "not an IANA zone name"},
    {"TimeZone", "1abc", "not an IANA zone name"},
    {"TimeZone", "", "not an IANA zone name"},
    {"TimeZone", "a".repeat(256), "not an IANA zone name"},
    {"TimeZone", "Europe//Lisbon", "not an IANA zone name"},
    {"TimeZone", "Europe/./Lisbon", "not an IANA zone name"},
    {"TimeZone", "+24:00", "offset +24:00 is out of range"},
    // Only ASCII: a digit or letter of another script is not one of the profile.
    {"Date", "２026-11-09", "write it like"}, // a fullwidth 2
    {"Date", "2026-11-0٩", "write it like"}, // an Arabic-Indic 9
    {"Time", "14:30:00.٥", "write it like"},
    {"Duration", "P١D", "write it like"},
    {"TimeZone", "Europe/Lisbön", "not an IANA zone name"},
    {"TimeZone", "Éurope/Lisbon", "not an IANA zone name"},
    {"TimeZone", "Europe/😀", "not an IANA zone name"},
    // Lone surrogates, which no UTF-8 text holds, are characters outside the profile too.
    {"TimeZone", "Europe/\uD800", "not an IANA zone name"},
    {"Date", "2026-11-0\uDC00", "write it like"},
    {"Duration", "PT1\uD800S", "write it like"},
    {"ZonedDateTime", "2027-03-29T10:00:00+01:00[\uDFFF]", "not an IANA zone name"},
  };

  @TestFactory
  Stream<DynamicTest> valid() {
    return Stream.of(VALID).map(c -> dynamicTest(c[0] + " " + c[1], () -> assertNull(StdTime.problem(c[0], c[1]))));
  }

  @TestFactory
  Stream<DynamicTest> invalid() {
    return Stream.of(INVALID)
        .map(
            c ->
                dynamicTest(
                    c[0] + " " + c[1],
                    () -> {
                      String reason = StdTime.problem(c[0], c[1]);
                      assertTrue(reason != null && reason.contains(c[2]), () -> "got " + reason + ", want " + c[2]);
                    }));
  }

  @Test
  void messages() {
    assertEquals(
        "\"2026-02-30\" is not a valid Date: 2026-02 has no day 30", StdTime.problem("Date", "2026-02-30"));
    assertEquals("\"14:30\" is not a Time; write it like 14:30:00", StdTime.problem("Time", "14:30"));
    assertEquals(
        "\"2027-03-29T10:00:00+01:00[a b]\" is not a valid ZonedDateTime: \"a b\" is not an IANA zone name"
            + " (like Europe/Lisbon) or an offset (like +01:00)",
        StdTime.problem("ZonedDateTime", "2027-03-29T10:00:00+01:00[a b]"));
    assertEquals(
        "\"P4294967296Y\" is not a valid Duration: 4294967296 is too large (years, months and weeks stay below 2^32)",
        StdTime.problem("Duration", "P4294967296Y"));
    assertEquals("Clock is not a std/time type", StdTime.problem("Clock", "12:00:00"));
  }

  @Test
  void check() {
    StdTime.check("Instant", "2026-11-13T10:00:00Z");
    HausException e = assertThrows(HausException.class, () -> StdTime.check("Date", "2026-02-30"));
    assertEquals(ErrorCode.INVALID_TIME, e.code());
    assertEquals("\"2026-02-30\" is not a valid Date: 2026-02 has no day 30", e.reason());
    assertThrows(HausException.class, () -> StdTime.check("Clock", "12:00:00"));
  }

  @Test
  void types() {
    assertEquals(
        List.of("Date", "Time", "DateTime", "Instant", "ZonedDateTime", "Duration", "YearMonth", "TimeZone"),
        StdTime.TYPES);
    for (String type : StdTime.TYPES) {
      assertTrue(StdTime.isType(type));
    }
    assertFalse(StdTime.isType("Clock"));
    assertFalse(StdTime.isType("date"));
  }

  /** Long texts are read in one pass: a million digits or characters take no time to reject. */
  @Test
  void longTexts() {
    String million = "9".repeat(1_000_000);
    assertTrue(StdTime.problem("Duration", "P" + million + "Y").contains("too large"));
    assertTrue(StdTime.problem("Duration", "PT" + million + "S").contains("below 2^53 seconds"));
    assertTrue(StdTime.problem("Duration", "P" + "0".repeat(1_000_000) + "D").contains("leading zero"));
    assertTrue(StdTime.problem("TimeZone", "a/".repeat(500_000) + "b").contains("not an IANA zone name"));
    String zoned = "2027-03-29T10:00:00+01:00[" + "[".repeat(1_000_000);
    assertTrue(StdTime.problem("ZonedDateTime", zoned).contains("write it like"));
  }
}
