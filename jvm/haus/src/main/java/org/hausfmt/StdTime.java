package org.hausfmt;

import java.util.List;

/**
 * The std/time profile (spec/std/time.md): which strings each type of std/time accepts. These are
 * built-in rules, like the range of {@code UInt8}, and a schema binding checks exactly these. Each
 * type reads its whole shape first, then checks the values, so that a string of the wrong shape
 * says how to write the type, whatever its values.
 *
 * <p>The profile is a strict grammar of ASCII characters, read character by character in one pass:
 * any other character, a lone surrogate included, is simply not part of it. Nothing here parses
 * with {@code java.time}, which accepts other spellings.
 */
public final class StdTime {
  private StdTime() {}

  /** The types of std/time, the only standard module. */
  public static final List<String> TYPES =
      List.of("Date", "Time", "DateTime", "Instant", "ZonedDateTime", "Duration", "YearMonth", "TimeZone");

  /** 2^32: years, months and weeks stay below it. */
  private static final long LIMIT_32 = 1L << 32;
  /** 2^53: days and time together stay below this many seconds. */
  private static final long LIMIT_53 = 1L << 53;
  /** The seconds in one of each duration unit from days on: days, hours, minutes, seconds. */
  private static final long[] SECONDS_PER = {86400, 3600, 60, 1};

  /** Whether {@code name} is a type of std/time, such as {@code Date} or {@code Instant}. */
  public static boolean isType(String name) {
    return TYPES.contains(name);
  }

  /**
   * Checks that {@code text} is a valid value of the std/time type {@code type}, throwing a {@link
   * HausException} with the code {@link ErrorCode#INVALID_TIME} that says why if it isn't.
   */
  public static void check(String type, String text) {
    String reason = problem(type, text);
    if (reason != null) {
      throw HausException.of(ErrorCode.INVALID_TIME, reason);
    }
  }

  /** Null if {@code text} is a valid value of the std/time type {@code type}, else why not. */
  static String problem(String type, String text) {
    String example = example(type);
    if (example == null) {
      return type + " is not a std/time type";
    }
    Cursor c = new Cursor(text);
    String reason;
    try {
      reason = c.read(type);
    } catch (Shape e) {
      return Quoting.forMessage(text) + " is not a " + type + "; write it like " + example;
    }
    return reason == null ? null : Quoting.forMessage(text) + " is not a valid " + type + ": " + reason;
  }

  private static String example(String type) {
    switch (type) {
      case "Date":
        return "2026-11-09";
      case "Time":
        return "14:30:00";
      case "DateTime":
        return "2026-11-09T14:30:00";
      case "Instant":
        return "2026-11-09T14:30:00Z";
      case "ZonedDateTime":
        return "2026-11-09T14:30:00+01:00[Europe/Lisbon]";
      case "Duration":
        return "PT1H30M";
      case "YearMonth":
        return "2026-11";
      case "TimeZone":
        return "Europe/Lisbon";
      default:
        return null;
    }
  }

  /**
   * A string that doesn't have its type's shape at all. Thrown while reading the shape, before any
   * value is checked; one shared instance, without a stack trace, as it is control flow.
   */
  private static final class Shape extends RuntimeException {
    private static final long serialVersionUID = 1L;
    static final Shape INSTANCE = new Shape();

    private Shape() {
      super(null, null, false, false);
    }
  }

  private static boolean isDigit(char c) {
    return c >= '0' && c <= '9';
  }

  private static boolean isLetter(char c) {
    return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z';
  }

  /** A number of at most four digits, such as a year or a minute. */
  private static int num(String digits) {
    return Integer.parseInt(digits);
  }

  /** Reads one type's shape, then checks its values: null if valid, else the reason. */
  private static final class Cursor {
    private final String s;
    private int i;

    Cursor(String s) {
      this.s = s;
    }

    String read(String type) {
      switch (type) {
        case "Date":
          return dateOnly();
        case "Time":
          return timeOnly();
        case "DateTime":
          return dateTime(false, false);
        case "Instant":
          return dateTime(true, false);
        case "ZonedDateTime":
          return dateTime(true, true);
        case "Duration":
          return duration();
        case "YearMonth":
          return yearMonth();
        default: // TimeZone
          return zone(s);
      }
    }

    boolean atEnd() {
      return i == s.length();
    }

    void finish() {
      if (!atEnd()) {
        throw Shape.INSTANCE;
      }
    }

    boolean opt(char c) {
      if (i < s.length() && s.charAt(i) == c) {
        i++;
        return true;
      }
      return false;
    }

    void lit(char c) {
      if (!opt(c)) {
        throw Shape.INSTANCE;
      }
    }

    /** Reads exactly n digits. */
    String digits(int n) {
      if (i + n > s.length()) {
        throw Shape.INSTANCE;
      }
      for (int j = i; j < i + n; j++) {
        if (!isDigit(s.charAt(j))) {
          throw Shape.INSTANCE;
        }
      }
      i += n;
      return s.substring(i - n, i);
    }

    /** Reads digits, as many as there are (none gives ""). */
    String run() {
      int j = i;
      while (j < s.length() && isDigit(s.charAt(j))) {
        j++;
      }
      String out = s.substring(i, j);
      i = j;
      return out;
    }

    /** Reads a fraction of 1–9 digits after a '.', if there is a '.'. */
    void fraction() {
      if (opt('.')) {
        int n = run().length();
        if (n < 1 || n > 9) {
          throw Shape.INSTANCE;
        }
      }
    }

    /** Reads YYYY-MM-DD: the year, month and day. */
    String[] date() {
      String y = digits(4);
      lit('-');
      String m = digits(2);
      lit('-');
      return new String[] {y, m, digits(2)};
    }

    /** Reads hh:mm:ss, then an optional fraction: the hour, minute and second. */
    String[] clock() {
      String h = digits(2);
      lit(':');
      String m = digits(2);
      lit(':');
      String sec = digits(2);
      fraction();
      return new String[] {h, m, sec};
    }

    /** Reads Z or ±hh:mm. */
    String offset() {
      int start = i;
      if (opt('+') || opt('-')) {
        digits(2);
        lit(':');
        digits(2);
      } else if (!opt('Z')) {
        throw Shape.INSTANCE;
      }
      return s.substring(start, i);
    }

    String dateOnly() {
      String[] d = date();
      finish();
      return checkDate(d);
    }

    String timeOnly() {
      String[] t = clock();
      finish();
      return checkClock(t);
    }

    /**
     * Reads a DateTime, with an offset for an Instant, and a zone in brackets for a
     * ZonedDateTime.
     */
    String dateTime(boolean withOffset, boolean withZone) {
      String[] d = date();
      lit('T');
      String[] t = clock();
      String o = withOffset ? offset() : "";
      String z = "";
      if (withZone) {
        lit('[');
        int end = s.indexOf(']', i);
        if (end < 0) {
          throw Shape.INSTANCE;
        }
        z = s.substring(i, end);
        i = end + 1;
      }
      finish();
      String reason = checkDate(d);
      if (reason == null) {
        reason = checkClock(t);
      }
      if (reason == null && withOffset) {
        reason = checkOffset(o);
      }
      if (reason == null && withZone) {
        reason = zone(z);
      }
      return reason;
    }

    String yearMonth() {
      digits(4);
      lit('-');
      String m = digits(2);
      finish();
      int month = num(m);
      return month < 1 || month > 12 ? "month " + m + " doesn't exist" : null;
    }

    /**
     * Reads a duration component, digits (and a fraction, if allowed) and its unit letter, if the
     * next one is that unit; otherwise it reads nothing and gives null.
     */
    String component(char unit, boolean withFraction) {
      int start = i;
      if (run().isEmpty()) {
        i = start;
        return null;
      }
      if (withFraction) {
        fraction();
      }
      String n = s.substring(start, i);
      if (opt(unit)) {
        return n;
      }
      i = start;
      return null;
    }

    /** Reads -?P[nY][nM][nW][nD][T[nH][nM][n[.f]S]]. */
    String duration() {
      boolean negative = opt('-');
      lit('P');
      // Years, months, weeks, days, hours, minutes, seconds (with their fraction); null if absent.
      String[] texts = new String[7];
      String units = "YMWD";
      for (int k = 0; k < 4; k++) {
        texts[k] = component(units.charAt(k), false);
      }
      boolean hasTime = opt('T');
      boolean endsWithT = hasTime && atEnd();
      if (hasTime) {
        texts[4] = component('H', false);
        texts[5] = component('M', false);
        texts[6] = component('S', true);
      }
      finish();
      String[] values = new String[7]; // without the fraction
      boolean given = false;
      for (int k = 0; k < 7; k++) {
        if (texts[k] != null) {
          int dot = texts[k].indexOf('.');
          values[k] = dot < 0 ? texts[k] : texts[k].substring(0, dot);
          given = true;
        }
      }
      if (!given) {
        return "a duration needs at least one component, like PT0S";
      }
      if (endsWithT) {
        return "a T must be followed by hours, minutes or seconds";
      }
      for (String v : values) {
        if (v != null && v.length() > 1 && v.charAt(0) == '0') {
          return v + " has a leading zero";
        }
      }
      boolean others = false;
      for (int k = 0; k < 6; k++) {
        if (texts[k] != null) {
          others = true;
          if (zero(texts[k])) {
            return "a duration leaves out components that are zero (zero is PT0S)";
          }
        }
      }
      if (texts[6] != null && zero(texts[6]) && others) {
        return "a duration leaves out components that are zero (zero is PT0S)";
      }
      if (negative && onlyOf(s, "-PYMWDTHS0.")) {
        return "a zero duration has no sign";
      }
      // Exact bounds, whatever the number of digits: the numbers have no leading zeros, so one
      // with more digits than a bound is past it, and the rest fit in a long.
      for (int k = 0; k < 3; k++) {
        if (values[k] != null && atLeast(values[k], LIMIT_32)) {
          return values[k] + " is too large (years, months and weeks stay below 2^32)";
        }
      }
      // Days and time below 2^53 seconds: the whole seconds decide, as a fraction is below one
      // second. Each term is capped at 2^53, so the sum of four can't overflow.
      long total = 0;
      for (int k = 3; k < 7; k++) {
        if (values[k] != null) {
          long per = SECONDS_PER[k - 3];
          total += atLeast(values[k], LIMIT_53 / per + 1) ? LIMIT_53 : Long.parseLong(values[k]) * per;
        }
      }
      if (total >= LIMIT_53) {
        return "days and time together must stay below 2^53 seconds";
      }
      return null;
    }
  }

  /**
   * Whether the digits {@code n}, without leading zeros, are at least {@code bound} (below 2^63):
   * by their number of digits first, so that no long overflows.
   */
  private static boolean atLeast(String n, long bound) {
    int boundDigits = Long.toString(bound).length();
    if (n.length() != boundDigits) {
      return n.length() > boundDigits;
    }
    return Long.parseLong(n) >= bound;
  }

  /** Whether a duration component's text is zero: zeros and a '.' only. */
  private static boolean zero(String text) {
    return onlyOf(text, "0.");
  }

  /** Whether every character of {@code text} is one of {@code set}. */
  private static boolean onlyOf(String text, String set) {
    for (int k = 0; k < text.length(); k++) {
      if (set.indexOf(text.charAt(k)) < 0) {
        return false;
      }
    }
    return true;
  }

  private static String checkDate(String[] d) {
    int year = num(d[0]);
    int month = num(d[1]);
    int day = num(d[2]);
    if (month < 1 || month > 12) {
      return "month " + d[1] + " doesn't exist";
    }
    boolean leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    int last = 31;
    if (month == 2) {
      last = leap ? 29 : 28;
    } else if (month == 4 || month == 6 || month == 9 || month == 11) {
      last = 30;
    }
    if (day >= 1 && day <= last) {
      return null;
    }
    if (month == 2 && day == 29) {
      return d[0] + "-" + d[1] + " has no day " + d[2] + " (" + d[0] + " is not a leap year)";
    }
    return d[0] + "-" + d[1] + " has no day " + d[2];
  }

  private static String checkClock(String[] t) {
    int h = num(t[0]);
    int m = num(t[1]);
    int sec = num(t[2]);
    if (h == 24) {
      return "24:00 is not allowed; write 00:00 of the next day";
    } else if (h > 24) {
      return "hour " + t[0] + " doesn't exist";
    } else if (m >= 60) {
      return "minute " + t[1] + " doesn't exist";
    } else if (sec == 60) {
      return "leap seconds (:60) are not allowed";
    } else if (sec > 60) {
      return "second " + t[2] + " doesn't exist";
    }
    return null;
  }

  /** Checks Z or ±hh:mm: up to ±23:59, never -00:00. */
  private static String checkOffset(String o) {
    if (o.equals("Z")) {
      return null;
    } else if (o.equals("-00:00")) {
      return "-00:00 is not allowed; write Z";
    } else if (num(o.substring(1, 3)) > 23 || num(o.substring(4, 6)) > 59) {
      return "offset " + o + " is out of range (±23:59 at most)";
    }
    return null;
  }

  /**
   * Checks an IANA zone name by its syntax (it is never looked up), or an offset. A name is ASCII,
   * so its length in chars is its length in UTF-8 bytes.
   */
  private static String zone(String z) {
    if (z.equals("Z")) {
      return "\"Z\" is the offset letter, not a zone: write an IANA zone name (like Europe/Lisbon) or an offset (like +00:00)";
    }
    Cursor c = new Cursor(z);
    try {
      String o = c.offset();
      if (c.atEnd()) {
        return checkOffset(o);
      }
    } catch (Shape e) {
      // not an offset: a name, then
    }
    boolean ok = z.length() <= 255 && !z.isEmpty() && isLetter(z.charAt(0));
    int start = 0;
    while (ok) {
      int end = z.indexOf('/', start);
      if (end < 0) {
        end = z.length();
      }
      ok = part(z, start, end);
      if (end == z.length()) {
        break;
      }
      start = end + 1;
    }
    return ok
        ? null
        : Quoting.forMessage(z) + " is not an IANA zone name (like Europe/Lisbon) or an offset (like +01:00)";
  }

  /** Whether z[start, end) is a part of a zone name: not empty, '.' or '..', of A–Z a–z 0–9 . _ + -. */
  private static boolean part(String z, int start, int end) {
    int n = end - start;
    if (n == 0 || n == 1 && z.charAt(start) == '.' || n == 2 && z.startsWith("..", start)) {
      return false;
    }
    for (int k = start; k < end; k++) {
      char c = z.charAt(k);
      if (!isLetter(c) && !isDigit(c) && "._+-".indexOf(c) < 0) {
        return false;
      }
    }
    return true;
  }
}
