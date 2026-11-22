package org.hausfmt;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.Consumer;

/**
 * The syntax tree of one schema file (spec §14, grammar.ebnf "Schema files") and its parser: a
 * recursive descent over the text with a cursor. The text is a Java string; positions are char
 * offsets into it, turned into lines and columns (in code points) only for an error. The
 * grammar's structure is ASCII, so non-ASCII text only occurs in comments and quoted keys.
 */
final class SchemaSyntax {
  private SchemaSyntax() {}

  /** The deepest nesting of type expressions the parser reads ({@code type-too-deep}). */
  static final int MAX_TYPE_NESTING = 128;

  /** The prelude's types and their number of parameters (spec §13): a schema can't redefine them. */
  static final Map<String, Integer> PRELUDE = Map.ofEntries(
      Map.entry("Bool", 0), Map.entry("Maybe", 1), Map.entry("Result", 2), Map.entry("String", 0),
      Map.entry("Bytes", 0), Map.entry("Array", 1), Map.entry("Map", 1), Map.entry("Int", 0),
      Map.entry("Int8", 0), Map.entry("Int16", 0), Map.entry("Int32", 0), Map.entry("Int64", 0),
      Map.entry("UInt8", 0), Map.entry("UInt16", 0), Map.entry("UInt32", 0), Map.entry("UInt64", 0),
      Map.entry("Float32", 0), Map.entry("Float64", 0), Map.entry("Decimal", 0), Map.entry("Any", 0),
      Map.entry("Secret", 1), Map.entry("Stream", 1));

  private static final Set<String> KEYWORDS = Set.of("type", "import", "closed");
  /** The attributes this version defines (spec §14). */
  private static final Set<String> DEFINED_ATTRIBUTES = Set.of("deprecated");

  // ── The tree ──

  enum TyKind {
    NAME, // a named type applied to arguments: Array Point, Int
    PARAM, // a type parameter: a
    RECORD, // { … } or closed { … }
    VARIANT // < … > or closed < … >
  }

  /** A type expression as written. */
  static final class Ty {
    final TyKind kind;
    final int pos;
    String name; // NAME, PARAM
    final List<Ty> args = new ArrayList<>(); // NAME
    boolean closed;
    final List<FieldDef> fields = new ArrayList<>();
    final List<CaseDef> cases = new ArrayList<>();
    final List<SpreadDef> spreads = new ArrayList<>(); // ...Name, with how many own entries come before each

    Ty(TyKind kind, int pos) {
      this.kind = kind;
      this.pos = pos;
    }
  }

  static final class FieldDef {
    String key;
    boolean optional;
    Ty ty;
    final int pos;
    List<Attribute> attrs;

    FieldDef(int pos, List<Attribute> attrs) {
      this.pos = pos;
      this.attrs = attrs;
    }
  }

  static final class CaseDef {
    String tag;
    final List<Ty> payload = new ArrayList<>(); // Tag A B: positional; Tag { … }: one record
    int pos;
    List<Attribute> attrs;
  }

  /** {@code ...Name}: {@code at} own fields or cases come before it. */
  record SpreadDef(String name, int at, int pos, List<Attribute> attrs) {}

  /** {@code @name} or {@code @name(value, …)} (spec §14). */
  record Attribute(String name, List<Value> args, int pos) {}

  static final class TypeDef {
    String name;
    final List<String> params = new ArrayList<>();
    Ty ty;
    int pos;
    String doc = ""; // the // lines directly above
    List<Attribute> attrs;
  }

  record NameAt(String name, int pos) {}

  static final class ImportDecl {
    String module;
    final List<NameAt> names = new ArrayList<>();
    final int pos;

    ImportDecl(int pos) {
      this.pos = pos;
    }
  }

  static final class File {
    final List<ImportDecl> imports = new ArrayList<>();
    final List<TypeDef> types = new ArrayList<>();
    List<Fail> warnings = new ArrayList<>();
  }

  /**
   * A mistake at a char offset of a schema file; with {@code unit} set, of one file of a schema
   * (the loader's). Thrown, and caught where it is placed in the root file.
   */
  static final class Fail extends RuntimeException {
    private static final long serialVersionUID = 1L;
    final int unit;
    final int pos;
    final ErrorCode code;
    final String msg;

    Fail(int unit, int pos, ErrorCode code, String msg) {
      super(msg, null, false, false);
      this.unit = unit;
      this.pos = pos;
      this.code = code;
      this.msg = msg;
    }

    Fail(int pos, ErrorCode code, String msg) {
      this(-1, pos, code, msg);
    }
  }

  // ── Parsing ──

  /**
   * Parses a schema file and checks what the grammar allows but the spec doesn't (§14): duplicate
   * types, fields and tags, prelude names, parameters, imports without names or with a version
   * that isn't a major, {@code closed < >}, row parameters and attributes. Spreads, names and
   * arities need the other files and are checked when the schema is resolved.
   */
  static File parseFile(String src) {
    Cursor p = new Cursor(src);
    if (src.startsWith("﻿")) {
      p.pos = 1;
    }
    File f = p.file();
    List<Fail> warnings = check(f);
    warnings.addAll(deprecatedUses(f));
    f.warnings = warnings;
    for (TypeDef d : f.types) {
      int at = d.attrs.isEmpty() ? d.pos : d.attrs.get(0).pos();
      d.doc = docComment(src, at);
    }
    return f;
  }

  static boolean isUpper(char c) {
    return c >= 'A' && c <= 'Z';
  }

  static boolean isLower(char c) {
    return c >= 'a' && c <= 'z';
  }

  static boolean isDigit(char c) {
    return c >= '0' && c <= '9';
  }

  static boolean isWord(char c) {
    return isUpper(c) || isLower(c) || isDigit(c) || c == '_';
  }

  /** The 1-based line and column (in code points) of a char offset of the text (spec §8). */
  static int[] lineCol(String text, int pos) {
    pos = Math.min(pos, text.length());
    int line = 1;
    int start = 0;
    for (int i = 0; i < pos; i++) {
      if (text.charAt(i) == '\n') {
        line++;
        start = i + 1;
      }
    }
    return new int[] {line, 1 + text.codePointCount(start, pos)};
  }

  /** The char offset of a 1-based line and column (in code points) of the text from {@code base}. */
  static int offsetOf(String s, int base, int line, int col) {
    int i = base;
    for (int l = 1; l < line && i < s.length(); i++) {
      if (s.charAt(i) == '\n') {
        l++;
      }
    }
    for (int c = 1; c < col && i < s.length(); c++) {
      i += Character.charCount(s.codePointAt(i));
    }
    return i;
  }

  private static final class Cursor {
    final String s;
    int pos;
    int depth;

    Cursor(String s) {
      this.s = s;
    }

    boolean at(int i, char c) {
      return i < s.length() && s.charAt(i) == c;
    }

    /** Names what stands at {@code i}, for messages. */
    String found(int i) {
      if (i >= s.length()) {
        return "end of file";
      }
      int j = i;
      while (j < s.length() && isWord(s.charAt(j))) {
        j++;
      }
      if (j > i) {
        return "'" + SchemaText.quote(s.substring(i, j)) + "'";
      }
      return "'" + SchemaText.quote(new String(Character.toChars(s.codePointAt(i)))) + "'";
    }

    Fail expected(String what) {
      // A '/' that doesn't start a comment, where whitespace may be: as in data (§14).
      if (at(pos, '/')) {
        return new Fail(pos, ErrorCode.STRAY_SLASH, "unexpected '/' (comments are // or /* */)");
      }
      return new Fail(pos, ErrorCode.SCHEMA_SYNTAX, "expected " + what + ", found " + found(pos));
    }

    /** The error for a raw control or bidirectional character at {@code i} in a comment (§4), or null. */
    Fail rawChar(int i) {
      char c = s.charAt(i);
      if (c == '\t' || c == '\n') {
        return null;
      }
      if (c == '\r') {
        return at(i + 1, '\n') ? null : loneCr(i);
      }
      if (c < 0x20 || c == 0x7f || c >= 0x80 && c <= 0x9f) {
        return new Fail(i, ErrorCode.CONTROL_CHARACTER,
            String.format("a raw control character, U+%04X, in a comment", (int) c));
      }
      if (Scan.isBidi(c)) {
        return new Fail(i, ErrorCode.BIDI_CONTROL,
            String.format("a raw bidirectional control character, U+%04X, in a comment", (int) c));
      }
      return null;
    }

    Fail loneCr(int i) {
      return new Fail(i, ErrorCode.LONE_CARRIAGE_RETURN, "a carriage return not followed by a line feed");
    }

    /** Skips whitespace and comments, as in data files (grammar "ws"). */
    void ws() {
      while (pos < s.length()) {
        char c = s.charAt(pos);
        if (c == ' ' || c == '\t' || c == '\n') {
          pos++;
        } else if (c == '\r') {
          if (!at(pos + 1, '\n')) {
            throw loneCr(pos);
          }
          pos += 2;
        } else if (c == '/' && at(pos + 1, '/')) {
          int i = pos + 2;
          while (i < s.length() && s.charAt(i) != '\n') {
            if (s.charAt(i) == '\r' && at(i + 1, '\n')) {
              break;
            }
            checkRaw(i);
            i++;
          }
          pos = i;
        } else if (c == '/' && at(pos + 1, '*')) {
          int start = pos;
          int depth = 0;
          int i = pos;
          do {
            if (i >= s.length()) {
              throw new Fail(start, ErrorCode.UNTERMINATED_COMMENT, "a /* comment that is never closed");
            }
            if (s.startsWith("/*", i)) {
              depth++;
              i += 2;
            } else if (s.startsWith("*/", i)) {
              depth--;
              i += 2;
            } else {
              checkRaw(i);
              i++;
            }
          } while (depth != 0);
          pos = i;
        } else {
          return;
        }
      }
    }

    private void checkRaw(int i) {
      char c = s.charAt(i);
      if (c < 0x20 || c >= 0x7f) {
        Fail f = rawChar(i);
        if (f != null) {
          throw f;
        }
      }
    }

    /** The word at {@code pos}, without moving. */
    String peekWord() {
      int j = pos;
      while (j < s.length() && isWord(s.charAt(j))) {
        j++;
      }
      return s.substring(pos, j);
    }

    /** Reads an uppercase word and the whitespace after it, or fails with {@code what} expected. */
    NameAt upper(String what) {
      int at = pos;
      if (pos >= s.length() || !isUpper(s.charAt(pos))) {
        throw expected(what);
      }
      String w = peekWord();
      pos += w.length();
      ws();
      return new NameAt(w, at);
    }

    /** Whether the keyword {@code w} is at {@code pos}; reads it if so. */
    boolean keyword(String w) {
      if (!peekWord().equals(w)) {
        return false;
      }
      pos += w.length();
      ws();
      return true;
    }

    /** Reads the symbol {@code sym} if it is next. */
    boolean sym(String sym) {
      if (!s.startsWith(sym, pos)) {
        return false;
      }
      pos += sym.length();
      ws();
      return true;
    }

    void need(String sym) {
      if (!sym(sym)) {
        throw expected("'" + sym + "'");
      }
    }

    /** Whether a lowercase word that can be a type parameter is at {@code pos}. */
    boolean atParam() {
      if (pos >= s.length() || !isLower(s.charAt(pos)) && s.charAt(pos) != '_') {
        return false;
      }
      return !KEYWORDS.contains(peekWord());
    }

    // ── structure ──

    File file() {
      File f = new File();
      ws();
      while (pos < s.length()) {
        if (peekWord().equals("import")) {
          f.imports.add(importDecl());
        } else {
          f.types.add(typeDef());
        }
      }
      return f;
    }

    ImportDecl importDecl() {
      ImportDecl imp = new ImportDecl(pos);
      keyword("import");
      int start = pos;
      String what = "a module (std/time, @org/name, ./file)";
      if (s.startsWith("std/", pos)) {
        pos += 4;
        if (pos >= s.length() || !isLower(s.charAt(pos)) && s.charAt(pos) != '_') {
          throw expected(what);
        }
        pos += peekWord().length();
      } else if (at(pos, '@') || at(pos, '.')) {
        // A package module's version may hold a `~` (`@a/b@1~x`: import-version); a file path
        // (grammar `path`) has none, so `./a~b` ends before it, a syntax error.
        String more = at(pos, '@') ? "_.-/@~" : "_.-/@";
        pos++;
        while (pos < s.length() && (isWord(s.charAt(pos)) || more.indexOf(s.charAt(pos)) >= 0)) {
          pos++;
        }
        if (pos == start + 1) {
          pos = start;
          throw expected(what);
        }
      } else {
        throw expected(what);
      }
      imp.module = s.substring(start, pos);
      ws();
      need("(");
      while (pos < s.length() && isUpper(s.charAt(pos))) {
        imp.names.add(upper("a type name"));
        if (!sym(",")) {
          break;
        }
      }
      need(")");
      return imp;
    }

    TypeDef typeDef() {
      List<Attribute> attrs = attributes();
      if (!keyword("type")) {
        throw expected(attrs.isEmpty() ? "'type' or 'import'" : "'type' after the attributes");
      }
      TypeDef d = new TypeDef();
      d.attrs = attrs;
      NameAt name = upper("a type name");
      d.name = name.name();
      d.pos = name.pos();
      while (atParam()) {
        String w = peekWord();
        pos += w.length();
        ws();
        d.params.add(w);
      }
      need("=");
      d.ty = typ();
      return d;
    }

    /** The attributes before a type, field or tag. */
    List<Attribute> attributes() {
      List<Attribute> attrs = new ArrayList<>();
      while (at(pos, '@')) {
        attrs.add(attribute());
      }
      return attrs;
    }

    /** {@code @name} or {@code @name(value, …)}, whose arguments are haus values read by the data parser. */
    Attribute attribute() {
      int at = pos;
      pos++;
      if (pos >= s.length() || !isLower(s.charAt(pos)) && s.charAt(pos) != '_') {
        throw expected("an attribute name after '@': @deprecated");
      }
      String name = peekWord();
      pos += name.length();
      if (at(pos, '(')) {
        int end = closingParen(s, pos);
        if (end < 0) {
          throw unclosedArguments(pos, name);
        }
        List<Value> values = parseValues(s.substring(pos + 1, end), pos + 1, "in the arguments of @" + name);
        if (values.isEmpty()) {
          throw new Fail(pos, ErrorCode.ATTRIBUTE_ARGUMENTS, "empty parentheses: write @" + name + " without them");
        }
        pos = end + 1;
        ws();
        return new Attribute(name, values, at);
      }
      ws();
      if (at(pos, '(')) {
        throw new Fail(pos, ErrorCode.ATTRIBUTE_SPACE, "expected '(' right after the attribute's name, without a space");
      }
      return new Attribute(name, List.of(), at);
    }

    /**
     * The error of attribute arguments whose '(' at {@code open} has no ')': what reading them value
     * by value finds first. A value that isn't one is the data parser's error; after the last
     * value, a comma or nothing means the '(' is unclosed, anything else that a ',' or ')' is
     * missing.
     */
    Fail unclosedArguments(int open, String name) {
      String inner = s.substring(open + 1);
      List<Value> values = parseValues(inner, open + 1, "in the arguments of @" + name);
      if (values.isEmpty() || inner.stripTrailing().endsWith(",")) {
        return new Fail(open, ErrorCode.UNCLOSED_BRACKET, "unclosed '(' of an attribute");
      }
      return new Fail(s.length(), ErrorCode.MISSING_COMMA, "expected ',' or ')' in the attribute's arguments");
    }

    /**
     * Values within the file, as the data parser reads them: text that doesn't start the file, so
     * a byte order mark is a mistake there and #haus no version directive.
     */
    List<Value> parseValues(String text, int base, String where) {
      try {
        Source src = Source.of(text);
        try {
          return new Parser(src, Limits.DEFAULT, false, false).file();
        } catch (SyntaxError e) {
          throw src.error(e);
        }
      } catch (HausException e) {
        throw dataError(e, base, where);
      }
    }

    /** An error of the data parser, in text that starts at {@code base}, at its place in the file. */
    Fail dataError(HausException e, int base, String where) {
      int at = e.line() > 0 ? offsetOf(s, base, e.line(), e.column()) : base;
      return new Fail(at, e.code(), where + ": " + e.reason());
    }

    // ── types ──

    void enter(int at) {
      depth++;
      if (depth > MAX_TYPE_NESTING) {
        throw new Fail(at, ErrorCode.TYPE_TOO_DEEP, "types nested deeper than " + MAX_TYPE_NESTING + " levels");
      }
    }

    /** {@code Name atom+ | atom}. Only parentheses, records and variants count as a level of nesting. */
    Ty typ() {
      if (pos < s.length() && isUpper(s.charAt(pos))) {
        NameAt name = upper("a type name");
        Ty t = new Ty(TyKind.NAME, name.pos());
        t.name = name.name();
        for (Ty a; (a = atom()) != null; ) {
          t.args.add(a);
        }
        return t;
      }
      Ty a = atom();
      if (a == null) {
        throw expected("a type");
      }
      return a;
    }

    /** An atom, or null if none starts at {@code pos}. */
    Ty atom() {
      if (pos >= s.length()) {
        return null;
      }
      int at = pos;
      char c = s.charAt(pos);
      if (isUpper(c)) {
        NameAt name = upper("a type name");
        Ty t = new Ty(TyKind.NAME, name.pos());
        t.name = name.name();
        return t;
      }
      if (c == '(') {
        enter(at);
        sym("(");
        Ty t = typ();
        need(")");
        depth--;
        return t;
      }
      if (c == '{') {
        return record(false);
      }
      if (c == '<') {
        return variant(false);
      }
      if (isLower(c) || c == '_') {
        String w = peekWord();
        if (w.equals("closed")) {
          keyword("closed");
          if (at(pos, '{')) {
            return record(true);
          }
          if (at(pos, '<')) {
            return variant(true);
          }
          throw expected("'{' or '<' after closed");
        }
        if (KEYWORDS.contains(w)) {
          return null;
        }
        pos += w.length();
        Ty t = new Ty(TyKind.PARAM, at);
        t.name = w;
        ws();
        return t;
      }
      return null;
    }

    /** {@code ...Name} (a lowercase name is read too, for the checks to reject). */
    SpreadDef spread(int at, List<Attribute> attrs) {
      // ...Name is one token: nothing may come between the dots and the name (spec §14).
      pos += 3;
      int start = pos;
      if (pos >= s.length() || !isUpper(s.charAt(pos)) && !isLower(s.charAt(pos)) && s.charAt(pos) != '_') {
        throw new Fail(pos, ErrorCode.SCHEMA_SYNTAX,
            "expected a type name right after '...', with nothing between: ...UserEvent, found " + found(pos));
      }
      String name = peekWord();
      pos += name.length();
      ws();
      return new SpreadDef(name, at, start, attrs);
    }

    Ty record(boolean closed) {
      Ty t = new Ty(TyKind.RECORD, pos);
      t.closed = closed;
      enter(pos);
      need("{");
      while (!sym("}")) {
        List<Attribute> attrs = attributes();
        if (s.startsWith("...", pos)) {
          t.spreads.add(spread(t.fields.size(), attrs));
        } else {
          t.fields.add(field(attrs));
        }
        if (!sym(",")) {
          need("}");
          break;
        }
      }
      depth--;
      return t;
    }

    FieldDef field(List<Attribute> attrs) {
      FieldDef f = new FieldDef(pos, attrs);
      if (pos < s.length() && (isLower(s.charAt(pos)) || s.charAt(pos) == '_')) {
        f.key = peekWord();
        pos += f.key.length();
        ws();
      } else if (at(pos, '"')) {
        f.key = stringLit();
      } else {
        throw expected(attrs.isEmpty() ? "a field name" : "a field after the attributes");
      }
      f.optional = sym("?");
      need(":");
      f.ty = typ();
      return f;
    }

    /** A {@code "…"} key: the data grammar's basic string. */
    String stringLit() {
      int start = pos;
      // `"""` is the key "" and a '"' that no rule takes: the grammar has no block strings.
      if (s.startsWith("\"\"\"", start)) {
        pos = start + 2;
        return "";
      }
      int i = start + 1;
      while (i < s.length() && s.charAt(i) != '"' && s.charAt(i) != '\n') {
        if (s.charAt(i) == '\\') {
          i++;
        }
        i++;
      }
      // The string up to its closing '"', or to the line break or end where it stops, which
      // the data parser reports as in data (string-line-break, unterminated-string, …).
      Value v;
      try {
        v = Haus.parse(s.substring(start, Math.min(i + 1, s.length())));
      } catch (HausException e) {
        throw dataError(e, start, "in a field name");
      }
      pos = i + 1;
      ws();
      return v instanceof Value.Text ? ((Value.Text) v).value() : "";
    }

    Ty variant(boolean closed) {
      Ty t = new Ty(TyKind.VARIANT, pos);
      t.closed = closed;
      enter(pos);
      need("<");
      sym("|");
      if (sym(">")) {
        depth--;
        return t;
      }
      while (true) {
        List<Attribute> attrs = attributes();
        if (s.startsWith("...", pos)) {
          t.spreads.add(spread(t.cases.size(), attrs));
        } else if (pos < s.length() && isUpper(s.charAt(pos))) {
          CaseDef c = new CaseDef();
          c.attrs = attrs;
          NameAt tag = upper("a tag");
          c.tag = tag.name();
          c.pos = tag.pos();
          for (Ty a; (a = atom()) != null; ) {
            c.payload.add(a);
          }
          t.cases.add(c);
        } else {
          throw expected(attrs.isEmpty() ? "a tag" : "a tag after the attributes");
        }
        if (!sym("|")) {
          need(">");
          depth--;
          return t;
        }
      }
    }
  }

  /**
   * The offset of the ')' that matches the '(' at {@code s[i]}, skipping strings, comments and
   * nested brackets, or -1.
   */
  static int closingParen(String s, int i) {
    int depth = 0;
    int n = s.length();
    while (i < n) {
      char c = s.charAt(i);
      if (c == '(' || c == '[' || c == '{') {
        depth++;
        i++;
      } else if (c == ')' || c == ']' || c == '}') {
        depth--;
        if (depth == 0) {
          return c == ')' ? i : -1;
        }
        if (depth < 0) {
          return -1;
        }
        i++;
      } else if (s.startsWith("\"\"\"", i)) {
        int j = i + 3;
        while (j < n && !s.startsWith("\"\"\"", j)) {
          j += s.charAt(j) == '\\' ? 2 : 1;
        }
        if (j >= n) {
          return -1;
        }
        i = j + 3;
      } else if (c == '"') {
        int j = i + 1;
        while (j < n && s.charAt(j) != '"' && s.charAt(j) != '\n') {
          j += s.charAt(j) == '\\' ? 2 : 1;
        }
        i = j + 1;
      } else if (s.startsWith("//", i)) {
        int j = s.indexOf('\n', i);
        if (j < 0) {
          return -1;
        }
        i = j;
      } else if (s.startsWith("/*", i)) {
        int nested = 0;
        while (true) {
          if (i >= n) {
            return -1;
          }
          if (s.startsWith("/*", i)) {
            nested++;
            i += 2;
          } else if (s.startsWith("*/", i)) {
            nested--;
            i += 2;
            if (nested == 0) {
              break;
            }
          } else {
            i++;
          }
        }
      } else {
        i++;
      }
    }
    return -1;
  }

  /** The // lines directly above the line of {@code pos}. */
  static String docComment(String src, int pos) {
    String before = src.substring(0, pos);
    int nl = before.lastIndexOf('\n');
    if (nl < 0) {
      return "";
    }
    before = before.substring(0, nl);
    List<String> lines = new ArrayList<>();
    while (!before.isEmpty()) {
      int i = before.lastIndexOf('\n');
      String line = before.substring(i + 1).strip();
      if (!line.startsWith("//")) {
        break;
      }
      String text = line.substring(2);
      lines.add(text.startsWith(" ") ? text.substring(1) : text);
      if (i < 0) {
        break;
      }
      before = before.substring(0, i);
    }
    Collections.reverse(lines);
    return String.join("\n", lines);
  }

  // ── Checks ──

  /** Reports what the grammar allows but the spec doesn't (§14); returns the warnings. */
  static List<Fail> check(File f) {
    Set<String> names = new HashSet<>();
    for (TypeDef d : f.types) {
      if (!names.add(d.name)) {
        throw new Fail(d.pos, ErrorCode.DUPLICATE_TYPE, d.name + " is defined twice");
      }
    }
    for (TypeDef d : f.types) {
      if (PRELUDE.containsKey(d.name)) {
        throw new Fail(d.pos, ErrorCode.REDEFINE_PRELUDE, d.name + " is a prelude type and can't be redefined");
      }
    }
    for (ImportDecl imp : f.imports) {
      if (imp.names.isEmpty()) {
        String m = SchemaText.quote(imp.module);
        throw new Fail(imp.pos, ErrorCode.UNKNOWN_IMPORT, "import " + m + " names no type: import " + m + " (Name, …)");
      }
    }
    for (ImportDecl imp : f.imports) {
      String why = importVersion(imp.module);
      if (why != null) {
        throw new Fail(imp.pos, ErrorCode.IMPORT_VERSION, why);
      }
    }
    for (ImportDecl imp : f.imports) {
      if (imp.module.startsWith("@") && !Manifest.isPackageName(packageOf(imp.module))) {
        throw new Fail(imp.pos, ErrorCode.UNKNOWN_MODULE, "unknown module " + SchemaText.quote(imp.module)
            + ": a package is @org/name, in lowercase letters, digits, -, . and _ (not node_modules)");
      }
    }
    for (TypeDef d : f.types) {
      Set<String> seen = new HashSet<>();
      for (String prm : d.params) {
        if (prm.startsWith("_")) {
          throw new Fail(d.pos, ErrorCode.INVALID_PARAMETER,
              prm + " can't be a parameter name: a parameter starts with a lowercase letter");
        }
        if (!seen.add(prm)) {
          throw new Fail(d.pos, ErrorCode.INVALID_PARAMETER, "parameter " + prm + " appears twice");
        }
      }
    }
    for (TypeDef d : f.types) {
      checkTy(d.ty);
    }
    List<Fail> warnings = new ArrayList<>();
    eachAttributes(f, attrs -> warnings.addAll(checkAttributes(attrs)));
    return warnings;
  }

  private static void checkTy(Ty t) {
    for (SpreadDef sp : t.spreads) {
      if (!isUpper(sp.name().charAt(0))) {
        throw new Fail(sp.pos(), ErrorCode.ROW_PARAMETER, "row parameters (..." + sp.name()
            + ") aren't supported; spread a named type instead: ...UserEvent");
      }
    }
    for (SpreadDef sp : t.spreads) {
      if (!sp.attrs().isEmpty()) {
        throw new Fail(sp.attrs().get(0).pos(), ErrorCode.ATTRIBUTE_ON_SPREAD,
            "a spread can't have attributes; the fields or tags of " + sp.name() + " keep their own");
      }
    }
    switch (t.kind) {
      case NAME:
        for (Ty a : t.args) {
          checkTy(a);
        }
        break;
      case PARAM:
        if (t.name.equals("_")) {
          throw new Fail(t.pos, ErrorCode.UNDERSCORE_TYPE,
              "types are open by default, so there is no _: write < > for any tag, or use a type parameter");
        }
        break;
      case RECORD: {
        Set<String> seen = new HashSet<>();
        for (FieldDef f : t.fields) {
          if (!seen.add(f.key)) {
            throw new Fail(f.pos, ErrorCode.DUPLICATE_FIELD, "duplicate field " + SchemaText.quoteKey(f.key));
          }
        }
        for (FieldDef f : t.fields) {
          checkTy(f.ty);
        }
        break;
      }
      case VARIANT: {
        if (t.closed && t.cases.isEmpty() && t.spreads.isEmpty()) {
          throw new Fail(t.pos, ErrorCode.CLOSED_EMPTY_VARIANT, "a closed variant needs at least one tag");
        }
        Set<String> seen = new HashSet<>();
        for (CaseDef c : t.cases) {
          if (!seen.add(c.tag)) {
            throw new Fail(c.pos, ErrorCode.DUPLICATE_TAG, "duplicate tag " + c.tag);
          }
        }
        for (CaseDef c : t.cases) {
          for (Ty a : c.payload) {
            checkTy(a);
          }
        }
        break;
      }
    }
  }

  /** Calls {@code f} with every list of attributes in the file: of its types, fields and tags. */
  private static void eachAttributes(File file, Consumer<List<Attribute>> f) {
    for (TypeDef d : file.types) {
      f.accept(d.attrs);
      walkTy(d.ty, t -> {
        for (FieldDef fd : t.fields) {
          f.accept(fd.attrs);
        }
        for (CaseDef c : t.cases) {
          f.accept(c.attrs);
        }
      });
    }
  }

  /**
   * Checks the attributes of one type, field or tag: defined ones take the right arguments and
   * are written once. Unknown ones are accepted, with a warning (spec §14).
   */
  private static List<Fail> checkAttributes(List<Attribute> attrs) {
    List<Fail> warnings = new ArrayList<>();
    for (int i = 0; i < attrs.size(); i++) {
      Attribute a = attrs.get(i);
      if (!DEFINED_ATTRIBUTES.contains(a.name())) {
        warnings.add(new Fail(a.pos(), ErrorCode.UNKNOWN_ATTRIBUTE,
            "unknown attribute @" + a.name() + ": this version of haus ignores it"));
        continue;
      }
      for (Attribute b : attrs.subList(0, i)) {
        if (b.name().equals(a.name())) {
          throw new Fail(a.pos(), ErrorCode.ATTRIBUTE_TWICE, "@" + a.name() + " is written twice here");
        }
      }
      if (a.name().equals("deprecated") && (a.args().size() > 1 || a.args().size() == 1 && !hasValidDeprecation(attrs))) {
        throw new Fail(a.pos(), ErrorCode.ATTRIBUTE_ARGUMENTS,
            "@deprecated takes at most one argument, a string: @deprecated(\"use email\")");
      }
    }
    return warnings;
  }

  private static boolean hasValidDeprecation(List<Attribute> attrs) {
    for (Attribute a : attrs) {
      if (a.name().equals("deprecated")) {
        return a.args().isEmpty() || a.args().size() == 1 && a.args().get(0) instanceof Value.Text;
      }
    }
    return false;
  }

  /** The message of the first {@code @deprecated} of {@code attrs}: "" without one or without a string. */
  static String deprecation(List<Attribute> attrs) {
    for (Attribute a : attrs) {
      if (a.name().equals("deprecated")) {
        return a.args().size() == 1 && a.args().get(0) instanceof Value.Text ? ((Value.Text) a.args().get(0)).value() : "";
      }
    }
    return "";
  }

  /** Whether {@code attrs} mark something deprecated. */
  static boolean isDeprecated(List<Attribute> attrs) {
    for (Attribute a : attrs) {
      if (a.name().equals("deprecated")) {
        return true;
      }
    }
    return false;
  }

  /**
   * Warns about uses of the file's deprecated types outside deprecated types, once where each is
   * written (spec §14), spreads included.
   */
  private static List<Fail> deprecatedUses(File f) {
    Map<String, String> deprecated = new HashMap<>();
    for (TypeDef d : f.types) {
      if (isDeprecated(d.attrs)) {
        deprecated.put(d.name, deprecation(d.attrs));
      }
    }
    List<Fail> out = new ArrayList<>();
    if (deprecated.isEmpty()) {
      return out;
    }
    for (TypeDef d : f.types) {
      if (deprecated.containsKey(d.name)) {
        continue;
      }
      walkTy(d.ty, t -> {
        if (t.kind == TyKind.NAME) {
          use(deprecated, t.name, t.pos, out);
        }
        for (SpreadDef sp : t.spreads) {
          use(deprecated, sp.name(), sp.pos(), out);
        }
      });
    }
    return out;
  }

  private static void use(Map<String, String> deprecated, String name, int pos, List<Fail> out) {
    String why = deprecated.get(name);
    if (why != null) {
      out.add(new Fail(pos, ErrorCode.DEPRECATED, name + " is deprecated" + (why.isEmpty() ? "" : ": " + why)));
    }
  }

  /** Drops every attribute of the file, as if none were written: decoding is the same (§15). */
  static void withoutAttributes(File f) {
    for (TypeDef d : f.types) {
      d.attrs = List.of();
      walkTy(d.ty, t -> {
        for (FieldDef fd : t.fields) {
          fd.attrs = List.of();
        }
        for (CaseDef c : t.cases) {
          c.attrs = List.of();
        }
      });
    }
    f.warnings = new ArrayList<>();
  }

  /** Calls {@code f} on every type expression in {@code t}, outermost first. */
  static void walkTy(Ty t, Consumer<Ty> f) {
    f.accept(t);
    for (Ty a : t.args) {
      walkTy(a, f);
    }
    for (FieldDef fd : t.fields) {
      walkTy(fd.ty, f);
    }
    for (CaseDef c : t.cases) {
      for (Ty a : c.payload) {
        walkTy(a, f);
      }
    }
  }

  /**
   * Why the version of a package import ({@code @org/name@1.1}) isn't a major version, {@code @N}
   * without leading zeros (spec §13.3), or null.
   */
  static String importVersion(String module) {
    if (!module.startsWith("@")) {
      return null;
    }
    int at = module.indexOf('@', 1);
    if (at < 0) {
      return null;
    }
    String name = SchemaText.quote(module.substring(0, at));
    String version = module.substring(at + 1);
    int end = 0;
    while (end < version.length() && isDigit(version.charAt(end))) {
      end++;
    }
    String digits = version.substring(0, end);
    String rest = version.substring(end);
    String major = digits.replaceFirst("^0+", "");
    if (major.isEmpty()) {
      major = "0";
    }
    String v = SchemaText.quote(version);
    if (digits.isEmpty() || !rest.isEmpty() && rest.charAt(0) != '.') {
      return name + "@" + v + ": expected a major version after '@', like " + name + "@1";
    }
    if (!rest.isEmpty()) {
      return name + "@" + v + ": an import names only the major version (" + name + "@" + major + ")";
    }
    if (digits.length() != major.length()) {
      return name + "@" + v + ": a major version has no leading zeros (" + name + "@" + major + ")";
    }
    return null;
  }

  /** The package a package import names, without its {@code @major}. */
  static String packageOf(String module) {
    int at = module.indexOf('@', 1);
    return at >= 0 ? module.substring(0, at) : module;
  }

  /** The message for an unknown type, with how to import it if it is a well-known one. */
  static String unknownType(String name) {
    if (name.equals("Money") || name.equals("Currency")) {
      return "unknown type " + name + " (import it with: import @haus-fmt/money (" + name
          + "), and install @haus-fmt/money with your package manager)";
    }
    if (name.equals("LatLng") || name.equals("BBox")) {
      return "unknown type " + name + " (import it with: import @haus-fmt/geo (" + name
          + "), and install @haus-fmt/geo with your package manager)";
    }
    if (StdTime.isType(name)) {
      return "unknown type " + name + " (import it with: import std/time (" + name + "))";
    }
    return "unknown type " + SchemaText.quote(name);
  }
}
