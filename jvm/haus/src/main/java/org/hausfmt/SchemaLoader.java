package org.hausfmt;

import java.io.IOException;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import org.hausfmt.SchemaSyntax.Fail;
import org.hausfmt.SchemaSyntax.TypeDef;
import org.hausfmt.SchemaSyntax.Ty;
import org.hausfmt.SchemaSyntax.TyKind;
import org.hausfmt.SchemaTypes.CaseType;
import org.hausfmt.SchemaTypes.FieldType;
import org.hausfmt.SchemaTypes.Instance;
import org.hausfmt.SchemaTypes.Kind;
import org.hausfmt.SchemaTypes.Payload;
import org.hausfmt.SchemaTypes.RecordType;
import org.hausfmt.SchemaTypes.Typ;
import org.hausfmt.SchemaTypes.VariantType;

/**
 * A schema file with its imports: names looked up, generic types applied, and every rule of spec
 * §14 checked. Generic types are applied by instantiating them ({@code List Int} is a type of its
 * own), which ends because no type parameter passes, inside a bigger type, along a cycle of
 * references back to itself (§9.10, the expansive-cycle rule); a limit on the number of instances
 * is a second guard.
 */
final class SchemaLoader {
  /** The most instances of generic types one schema makes. */
  static final int MAX_INSTANCES = 10_000;

  /** The prelude's types with parameters, and how many. */
  static final Map<String, Integer> GENERIC =
      Map.of("Array", 1, "Map", 1, "Maybe", 1, "Result", 2, "Secret", 1, "Stream", 1);

  private record DefRef(int u, int d) {}

  /** Where a file was first imported: the importing file, the import's offset there, the module as written. */
  private record Origin(int unit, int pos, String label) {}

  /** One schema file: the root, or one it imports. */
  private static final class Unit {
    final String text;
    final SchemaSyntax.File file;
    final String path; // its real path; null for a schema given as text
    final String id;
    final Origin origin;
    final Map<String, Integer> own = new HashMap<>(); // its own definitions: what other files can import
    final Map<String, DefRef> scope = new HashMap<>(); // every named type in scope
    final Map<String, String> std = new HashMap<>(); // the types imported from std/time

    Unit(String text, SchemaSyntax.File file, String path, String id, Origin origin) {
      this.text = text;
      this.file = file;
      this.path = path;
      this.id = id;
      this.origin = origin;
    }
  }

  /** A package a schema reaches: one per name. */
  private record Reached(String path, SchemaFiles.FoundPackage pkg, String text) {}

  private enum State { NEW, BUSY, DONE }

  private record RefAt(Instance inst, int unit, int pos) {}

  private final SchemaOptions opts;
  private final PackageLocator packages;
  private final SchemaFiles files;
  private final List<Unit> units = new ArrayList<>();
  private final Map<String, Integer> byPath = new HashMap<>();
  private final Map<String, Reached> reached = new TreeMap<>();
  private String base = "";
  private String baseDir;
  private boolean hasBase;
  private final List<Integer> loading = new ArrayList<>();
  private final Set<String> copies = new HashSet<>();
  private final List<Instance> instances = new ArrayList<>();
  private final List<DefRef> defOf = new ArrayList<>();
  private final List<State> states = new ArrayList<>();
  private final Map<String, Integer> byKey = new HashMap<>();
  // The key of each record's and variant's shape, and of each record and variant: see key.
  private final Map<String, String> shapes = new HashMap<>();
  private final Map<RecordType, String> recKeys = new IdentityHashMap<>();
  private final Map<VariantType, String> vrtKeys = new IdentityHashMap<>();
  private final ArrayDeque<Integer> queue = new ArrayDeque<>();
  private final List<RefAt> refs = new ArrayList<>();

  SchemaLoader(SchemaOptions opts, SchemaFiles files) {
    this.opts = opts;
    this.packages = opts.packages() == null ? PackageLocator.none() : opts.packages();
    this.files = files;
  }

  /** Reads a schema from text; its relative imports fail, as it has no place among files. */
  static Schema parse(String text, SchemaOptions opts) {
    return new SchemaLoader(opts, new SchemaFiles()).run(text, null);
  }

  /** Reads the schema file at {@code path}, its imports, and the packages it imports. */
  static Schema load(String path, SchemaOptions opts) {
    SchemaFiles files = new SchemaFiles();
    String[] root = files.rootSource(path);
    try {
      return new SchemaLoader(opts, files).run(root[1], root[0]);
    } catch (HausException e) {
      throw SchemaFiles.inFile(e, path);
    }
  }

  /** A mistake of file {@code u}. */
  private static Fail failIn(int u, int pos, ErrorCode code, String msg) {
    return new Fail(u, pos, code, msg);
  }

  /**
   * A mistake in a file as an error of the root file: errors inside an imported file are reported
   * at the import, with their place in that file.
   */
  private HausException lift(Fail f) {
    while (true) {
      Unit u = units.get(f.unit);
      int[] lc = SchemaSyntax.lineCol(u.text, f.pos);
      if (u.origin == null) {
        return new HausException(f.code, f.msg, lc[0], lc[1], null, null, null);
      }
      f = new Fail(u.origin.unit, u.origin.pos, f.code, u.origin.label + " (" + lc[0] + ":" + lc[1] + "): " + f.msg);
    }
  }

  private Schema run(String text, String path) {
    SchemaFiles.FoundPackage pkg = path != null ? files.packageOfFile(path) : null;
    if (opts.project() != null) {
      String dir = opts.projectDir();
      try {
        dir = SchemaFiles.realPath(dir);
      } catch (IOException | RuntimeException e) {
        // the directory as given
      }
      base = opts.project() + "/";
      baseDir = dir;
      hasBase = true;
    } else if (path != null) {
      baseDir = parent(path);
      hasBase = true;
    }
    String id = opts.id();
    if (id == null) {
      id = pkg != null ? pkg.manifest.id() : path != null ? appId(path) : "";
    }
    String name = null;
    if (pkg != null) {
      name = pkg.manifest.name();
      reached.put(name, new Reached(path, pkg, text));
    }
    int root = load(text, path, id, null);
    try {
      evaluateAll();
    } catch (Fail f) {
      throw lift(f);
    }
    return schema(root);
  }

  private static String parent(String path) {
    java.nio.file.Path p = java.nio.file.Paths.get(path).getParent();
    return p == null ? path : p.toString();
  }

  /** Builds the result for the root file. */
  private Schema schema(int root) {
    Unit u = units.get(root);
    List<SchemaDefinition> defs = new ArrayList<>();
    List<Instance> templates = new ArrayList<>();
    for (int d = 0; d < u.file.types.size(); d++) {
      add(defs, templates, u.file.types.get(d).name, new DefRef(root, d));
    }
    int own = defs.size();
    List<String> imported = new ArrayList<>();
    for (Map.Entry<String, DefRef> e : u.scope.entrySet()) {
      if (e.getValue().u != root) {
        imported.add(e.getKey());
      }
    }
    imported.sort(null);
    for (String name : imported) {
      add(defs, templates, name, u.scope.get(name));
    }
    List<HausException> warnings = new ArrayList<>();
    for (Fail w : u.file.warnings) {
      int[] lc = SchemaSyntax.lineCol(u.text, w.pos);
      warnings.add(new HausException(w.code, w.msg, lc[0], lc[1], null, null, null));
    }
    warnings.addAll(noJsonForms(root));
    warnings.sort(Comparator.comparingInt(HausException::line).thenComparingInt(HausException::column));
    List<SchemaPackage> pkgs = new ArrayList<>();
    for (Map.Entry<String, Reached> e : reached.entrySet()) {
      Reached r = e.getValue();
      pkgs.add(new SchemaPackage(e.getKey(), r.pkg.manifest.version(), r.pkg.dir));
    }
    return new Schema(defs, templates, own, warnings, pkgs);
  }

  private void add(List<SchemaDefinition> defs, List<Instance> templates, String name, DefRef at) {
    TypeDef def = units.get(at.u).file.types.get(at.d);
    boolean deprecated = SchemaSyntax.isDeprecated(def.attrs);
    defs.add(new SchemaDefinition(name, defId(at.u, at.d), List.copyOf(def.params), def.doc, deprecated,
        deprecated ? SchemaSyntax.deprecation(def.attrs) : ""));
    templates.add(instances.get(byKey.get(templateKey(at.u, at.d, def.params))));
  }

  /** The id of a file outside packages (spec §13.3): different for different files. */
  private String appId(String path) {
    if (hasBase) {
      return base + SchemaFiles.relativeID(baseDir, path);
    }
    return path.replace('\\', '/');
  }

  private String defId(int u, int d) {
    String name = units.get(u).file.types.get(d).name;
    String id = units.get(u).id;
    return id.isEmpty() ? name : id + "#" + name;
  }

  /** Parses a file, loads its imports and builds its scope. */
  private int load(String text, String path, String id, Origin from) {
    SchemaSyntax.File f;
    try {
      f = SchemaSyntax.parseFile(text);
    } catch (Fail e) {
      int[] lc = SchemaSyntax.lineCol(text, e.pos);
      if (from == null) {
        throw new HausException(e.code, e.msg, lc[0], lc[1], null, null, null);
      }
      throw lift(new Fail(from.unit, from.pos, e.code, from.label + " (" + lc[0] + ":" + lc[1] + "): " + e.msg));
    }
    if (opts.withoutAttributes()) {
      SchemaSyntax.withoutAttributes(f);
    }
    int u = units.size();
    if (path != null) {
      byPath.put(path, u);
    }
    units.add(new Unit(text, f, path, id, from));
    loading.add(u);
    try {
      imports(u);
    } finally {
      loading.remove(loading.size() - 1);
    }
    try {
      ownTypes(u);
    } catch (Fail e) {
      throw lift(e);
    }
    return u;
  }

  private void imports(int u) {
    for (SchemaSyntax.ImportDecl imp : units.get(u).file.imports) {
      if (imp.module.startsWith("std/")) {
        String module = imp.module.substring(4);
        List<String> names = new ArrayList<>();
        for (SchemaSyntax.NameAt n : imp.names) {
          names.add(n.name());
        }
        if (module.equals("money")) {
          throw lift(failIn(u, imp.pos, ErrorCode.UNKNOWN_MODULE, "std/money is no longer a standard module; it is the "
              + "package @haus-fmt/money: import @haus-fmt/money (" + String.join(", ", names) + ")"));
        }
        if (!module.equals("time")) {
          throw lift(failIn(u, imp.pos, ErrorCode.UNKNOWN_MODULE,
              "unknown standard module " + SchemaText.quote(imp.module) + " (there is std/time)"));
        }
        for (SchemaSyntax.NameAt n : imp.names) {
          if (!StdTime.isType(n.name())) {
            throw lift(failIn(u, n.pos(), ErrorCode.UNKNOWN_IMPORT, "std/time has no type " + n.name()
                + " (it has Date, Time, DateTime, Instant, ZonedDateTime, Duration, YearMonth, TimeZone)"));
          }
          bring(u, n, null, n.name());
        }
        continue;
      }
      boolean isModule = imp.module.startsWith("@") && imp.module.contains("/")
          || imp.module.startsWith("./") || imp.module.startsWith("../");
      if (!isModule) {
        throw lift(failIn(u, imp.pos, ErrorCode.UNKNOWN_MODULE, "unknown module " + SchemaText.quote(imp.module)
            + ": import std/…, a package @org/name or a file ./name"));
      }
      int dep = importFrom(u, imp.pos, imp.module, imp.module, units.get(u).path);
      for (SchemaSyntax.NameAt n : imp.names) {
        Integer d = units.get(dep).own.get(n.name());
        if (d == null) {
          List<String> has = new ArrayList<>();
          for (TypeDef t : units.get(dep).file.types) {
            has.add(t.name);
          }
          String list = has.isEmpty() ? "" : " (it has " + String.join(", ", has) + ")";
          throw lift(failIn(u, n.pos(), ErrorCode.UNKNOWN_IMPORT,
              SchemaText.quote(imp.module) + " has no type " + n.name() + list));
        }
        bring(u, n, new DefRef(dep, d), null);
      }
    }
  }

  /** Puts an imported name in scope, once. */
  private void bring(int u, SchemaSyntax.NameAt n, DefRef def, String std) {
    Unit unit = units.get(u);
    if (unit.scope.containsKey(n.name()) || unit.std.containsKey(n.name())) {
      throw lift(failIn(u, n.pos(), ErrorCode.DUPLICATE_IMPORT, n.name() + " is imported twice"));
    }
    if (def != null) {
      unit.scope.put(n.name(), def);
    }
    if (std != null) {
      unit.std.put(n.name(), std);
    }
  }

  /**
   * Loads the file {@code module} names for the file at {@code from}; errors are reported at the
   * offset {@code pos} of unit {@code u}, for the import {@code label}.
   */
  private int importFrom(int u, int pos, String module, String label, String from) {
    // @org/name@2: the package, and the major version wanted.
    String name = module;
    String wanted = null;
    if (module.startsWith("@")) {
      int i = module.lastIndexOf('@');
      if (i > 1 && i < module.length() - 1 && allDigits(module.substring(i + 1))) {
        name = module.substring(0, i);
        wanted = module.substring(i + 1);
      }
    }
    SchemaFiles.Source found;
    try {
      found = name.startsWith("@") ? files.openPackageFor(packages, name, from) : files.openRelative(name, from);
    } catch (HausException e) {
      throw lift(failIn(u, pos, e.code(), "can't import " + label + ": " + e.reason()));
    }
    if (wanted != null && found.pkg != null && !found.pkg.manifest.major().equals(wanted)) {
      throw lift(failIn(u, pos, ErrorCode.IMPORT_VERSION, label + " wants major version " + wanted
          + ", but version " + SchemaText.quote(found.pkg.manifest.version()) + " was found"));
    }
    // One package per name (spec §13.3): copies with the same files, whose imports reach the same
    // packages, are one.
    String path = found.path;
    String copyPath = null;
    if (found.pkg != null) {
      Reached old = reached.get(found.pkg.manifest.name());
      if (old != null) {
        if (old.path.equals(found.path)) {
          path = old.path;
        } else if (old.pkg.manifestText.equals(found.pkg.manifestText) && old.text.equals(found.text)) {
          copyPath = found.path;
          path = old.path;
        } else {
          HausException e = SchemaFiles.duplicate(old.pkg.manifest, old.pkg.dir, found.pkg.manifest, found.pkg.dir);
          throw lift(failIn(u, pos, e.code(), "can't import " + label + ": " + e.reason()));
        }
      }
    }
    for (int v : loading) {
      if (path.equals(units.get(v).path)) {
        throw lift(failIn(u, pos, ErrorCode.IMPORT_CYCLE, "import cycle: " + label + " imports this file again"));
      }
    }
    Integer cached = byPath.get(path);
    if (cached != null) {
      if (copyPath != null) {
        copyImports(u, pos, label, cached, copyPath);
      }
      return cached;
    }
    if (units.size() + copies.size() >= SchemaFiles.MAX_FILES) {
      throw lift(failIn(u, pos, ErrorCode.TOO_MANY_FILES, "more than " + SchemaFiles.MAX_FILES + " schema files are imported"));
    }
    Origin o = new Origin(u, pos, label);
    if (found.pkg != null) {
      reached.put(found.pkg.manifest.name(), new Reached(path, found.pkg, found.text));
      return load(found.text, path, found.pkg.manifest.id(), o);
    }
    return load(found.text, path, appId(path), o);
  }

  private static boolean allDigits(String s) {
    for (int i = 0; i < s.length(); i++) {
      if (!SchemaSyntax.isDigit(s.charAt(i))) {
        return false;
      }
    }
    return !s.isEmpty();
  }

  /**
   * Resolves the imports of a copy of a package (its schema.haus at {@code copyPath}), identical
   * to the package loaded as {@code original}, from the copy's place: they must reach the same
   * packages (spec §13.3).
   */
  private void copyImports(int u, int pos, String label, int original, String copyPath) {
    if (!copies.add(copyPath)) {
      return;
    }
    if (units.size() + copies.size() > SchemaFiles.MAX_FILES) {
      throw lift(failIn(u, pos, ErrorCode.TOO_MANY_FILES, "more than " + SchemaFiles.MAX_FILES + " schema files are imported"));
    }
    String dir = SchemaFiles.shown(parent(copyPath));
    for (SchemaSyntax.ImportDecl imp : units.get(original).file.imports) {
      if (imp.module.startsWith("@")) {
        importFrom(u, pos, imp.module, label + " (its copy in " + dir + " imports " + imp.module + ")", copyPath);
      }
    }
  }

  /**
   * Puts the file's own definitions in scope, unless a name is also imported, and checks that
   * generic ones can't grow without bound (§9.10).
   */
  private void ownTypes(int u) {
    Unit unit = units.get(u);
    for (int d = 0; d < unit.file.types.size(); d++) {
      TypeDef def = unit.file.types.get(d);
      if (unit.scope.containsKey(def.name) || unit.std.containsKey(def.name)) {
        throw failIn(u, def.pos, ErrorCode.DUPLICATE_TYPE, "type " + def.name + " is already imported");
      }
      unit.own.put(def.name, d);
    }
    for (int d = 0; d < unit.file.types.size(); d++) {
      unit.scope.put(unit.file.types.get(d).name, new DefRef(u, d));
    }
    new Growth(u).check();
  }

  // ── §9.10: the expansive-cycle rule ──

  /** An argument other than a bare parameter passed to a definition of the file: the P a a of B (P a a). */
  private static final class Pass {
    final int def;
    final int pos; // the definition the reference is in, and where
    final int to;
    final int index; // the definition referred to, and which of its parameters the argument is for
    final Ty arg;
    int from = -1; // the node of the argument's parameters; -1 if it has none

    Pass(int def, int pos, int to, int index, Ty arg) {
      this.def = def;
      this.pos = pos;
      this.to = to;
      this.index = index;
      this.arg = arg;
    }
  }

  /**
   * The parameter graph of §9.10 for one file. It has a node per type parameter of every
   * definition, and for each reference {@code B t₁ … tₙ} in the body of a definition A to a
   * definition B of the file, an edge from each parameter a of A occurring in tᵢ to the i-th
   * parameter of B: expanding unless tᵢ is a itself. A schema in which an expanding edge lies on
   * a cycle could have instances that grow without bound. It is built in linear time: an argument
   * with several parameters gets a node of its own that they flow into.
   */
  private final class Growth {
    final int unit;
    final List<TypeDef> types;
    final int[] first; // node first[d] + p is parameter p of definition d
    final List<Integer> owner = new ArrayList<>(); // per parameter node: its definition
    final List<List<Integer>> edges = new ArrayList<>();
    final List<Pass> passes = new ArrayList<>();

    Growth(int u) {
      unit = u;
      types = units.get(u).file.types;
      first = new int[types.size()];
      for (int d = 0; d < types.size(); d++) {
        first[d] = owner.size();
        for (int i = 0; i < types.get(d).params.size(); i++) {
          owner.add(d);
        }
      }
      for (int i = 0; i < owner.size(); i++) {
        edges.add(new ArrayList<>());
      }
      for (int d = 0; d < types.size(); d++) {
        flow(d, types.get(d).ty);
      }
    }

    /**
     * Reports the first expanding edge on a cycle, at its reference: definitions in order,
     * references in body order (outermost first), then by argument.
     */
    void check() {
      int[] component = components(edges);
      for (Pass p : passes) {
        int to = first[p.to] + p.index;
        if (p.from < 0 || component[p.from] != component[to]) {
          continue;
        }
        // The first parameter in the argument that the cycle comes back to.
        int[] back = {-1};
        SchemaSyntax.walkTy(p.arg, t -> {
          if (t.kind != TyKind.PARAM || back[0] >= 0) {
            return;
          }
          int a = param(p.def, t.name);
          if (a >= 0 && component[a] == component[to]) {
            back[0] = a;
          }
        });
        if (back[0] >= 0) {
          throw failIn(unit, p.pos, ErrorCode.GROWING_RECURSION, growing(back[0], to, component));
        }
      }
    }

    /** The definition of the file {@code name} refers to; -1 if it isn't one. */
    int callee(String name) {
      if (GENERIC.containsKey(name)) {
        return -1;
      }
      Integer d = units.get(unit).own.get(name);
      return d == null ? -1 : d;
    }

    /** The node of parameter {@code name} of definition {@code d}; -1 if it has none. */
    int param(int d, String name) {
      int p = types.get(d).params.indexOf(name);
      return p >= 0 ? first[d] + p : -1;
    }

    /** Adds the edges of the references in {@code t}, and returns the node its parameters flow into; -1 if none. */
    int flow(int d, Ty t) {
      List<Integer> nodes = new ArrayList<>();
      switch (t.kind) {
        case PARAM:
          return param(d, t.name);
        case NAME: {
          int to = callee(t.name);
          int n = to >= 0 ? Math.min(t.args.size(), types.get(to).params.size()) : 0;
          // This reference's arguments are checked before those of the references inside them.
          int start = passes.size();
          List<Integer> nested = new ArrayList<>();
          for (int i = 0; i < n; i++) {
            Ty a = t.args.get(i);
            if (a.kind != TyKind.PARAM) {
              nested.add(i);
              passes.add(new Pass(d, t.pos, to, i, a));
            }
          }
          int[] argNodes = new int[t.args.size()];
          for (int i = 0; i < t.args.size(); i++) {
            argNodes[i] = flow(d, t.args.get(i));
            if (argNodes[i] >= 0) {
              nodes.add(argNodes[i]);
            }
          }
          for (int i = 0; i < n; i++) {
            if (argNodes[i] >= 0) {
              edges.get(argNodes[i]).add(first[to] + i);
            }
          }
          for (int k = 0; k < nested.size(); k++) {
            passes.get(start + k).from = argNodes[nested.get(k)];
          }
          break;
        }
        case RECORD:
          for (SchemaSyntax.FieldDef f : t.fields) {
            addNode(nodes, flow(d, f.ty));
          }
          break;
        case VARIANT:
          for (SchemaSyntax.CaseDef c : t.cases) {
            for (Ty p : c.payload) {
              addNode(nodes, flow(d, p));
            }
          }
          break;
      }
      return join(nodes);
    }

    private void addNode(List<Integer> nodes, int n) {
      if (n >= 0) {
        nodes.add(n);
      }
    }

    /** One node for {@code nodes}: -1 for none, the node for one, otherwise a new node they all flow into. */
    int join(List<Integer> nodes) {
      if (nodes.isEmpty()) {
        return -1;
      }
      int one = nodes.get(0);
      if (nodes.stream().allMatch(n -> n == one)) {
        return one;
      }
      int joined = edges.size();
      edges.add(new ArrayList<>());
      for (int n : nodes) {
        edges.get(n).add(joined);
      }
      return joined;
    }

    /** The message for parameter node {@code a} passed, inside a bigger type, to {@code to}, from where it comes back. */
    String growing(int a, int to, int[] component) {
      int def = owner.get(a);
      int b = owner.get(to);
      String name = types.get(def).name;
      String param = types.get(def).params.get(a - first[def]);
      if (a == to) {
        return name + " passes its parameter " + param + " to itself inside a bigger type: instances could grow without bound";
      }
      String target = b == def ? "itself" : types.get(b).name;
      List<String> names = new ArrayList<>(List.of(name, types.get(b).name));
      for (int n : way(to, a, component)) {
        names.add(types.get(owner.get(n)).name);
      }
      return name + " passes its parameter " + param + " to " + target + " inside a bigger type, and it comes back ("
          + String.join(" → ", names) + "): instances could grow without bound";
    }

    /** A shortest way along the edges between parameters from {@code from} to {@code to}: the nodes after {@code from}. */
    List<Integer> way(int from, int to, int[] component) {
      List<List<Integer>> paramEdges = new ArrayList<>();
      for (int i = 0; i < owner.size(); i++) {
        paramEdges.add(new ArrayList<>());
      }
      for (int d = 0; d < types.size(); d++) {
        int dd = d;
        SchemaSyntax.walkTy(types.get(d).ty, t -> {
          if (t.kind != TyKind.NAME) {
            return;
          }
          int b = callee(t.name);
          if (b < 0) {
            return;
          }
          for (int i = 0; i < Math.min(t.args.size(), types.get(b).params.size()); i++) {
            int ii = i;
            SchemaSyntax.walkTy(t.args.get(i), x -> {
              if (x.kind == TyKind.PARAM) {
                int p = param(dd, x.name);
                if (p >= 0) {
                  paramEdges.get(p).add(first[b] + ii);
                }
              }
            });
          }
        });
      }
      int[] before = new int[paramEdges.size()];
      Arrays.fill(before, -1);
      ArrayDeque<Integer> q = new ArrayDeque<>(List.of(from));
      while (!q.isEmpty()) {
        int n = q.poll();
        if (n == to) {
          break;
        }
        for (int m : paramEdges.get(n)) {
          if (m != from && before[m] < 0 && component[m] == component[from]) {
            before[m] = n;
            q.add(m);
          }
        }
      }
      List<Integer> way = new ArrayList<>();
      for (int n = to; before[n] >= 0; n = before[n]) {
        way.add(0, n);
      }
      return way;
    }
  }

  /**
   * The strongly connected component of each node of a graph (Tarjan's algorithm, with a stack of
   * its own rather than recursion).
   */
  static int[] components(List<List<Integer>> edges) {
    int n = edges.size();
    int[] index = new int[n];
    int[] low = new int[n];
    int[] component = new int[n];
    Arrays.fill(index, -1);
    Arrays.fill(component, -1);
    int[] stack = new int[n];
    int sp = 0;
    int[] workNode = new int[n];
    int[] workNext = new int[n];
    int wp = 0;
    int visited = 0;
    int count = 0;
    for (int start = 0; start < n; start++) {
      if (index[start] >= 0) {
        continue;
      }
      index[start] = low[start] = visited++;
      stack[sp++] = start;
      workNode[wp] = start;
      workNext[wp++] = 0;
      while (wp > 0) {
        int v = workNode[wp - 1];
        if (workNext[wp - 1] < edges.get(v).size()) {
          int w = edges.get(v).get(workNext[wp - 1]++);
          if (index[w] < 0) {
            index[w] = low[w] = visited++;
            stack[sp++] = w;
            workNode[wp] = w;
            workNext[wp++] = 0;
          } else if (component[w] < 0) {
            low[v] = Math.min(low[v], index[w]);
          }
          continue;
        }
        wp--;
        if (wp > 0) {
          int parent = workNode[wp - 1];
          low[parent] = Math.min(low[parent], low[v]);
        }
        if (low[v] == index[v]) {
          int w;
          do {
            w = stack[--sp];
            component[w] = count;
          } while (w != v);
          count++;
        }
      }
    }
    return component;
  }

  // ── Evaluation ──

  /**
   * Evaluates every definition of every file (templates for generic ones), so that all errors
   * surface, then checks references to streams and that every cycle of definitions consumes
   * input (§9.9).
   */
  private void evaluateAll() {
    for (int u = 0; u < units.size(); u++) {
      List<TypeDef> types = units.get(u).file.types;
      for (int d = 0; d < types.size(); d++) {
        TypeDef def = types.get(d);
        List<Typ> args = new ArrayList<>();
        for (String p : def.params) {
          args.add(Typ.named(Kind.PARAM, p));
        }
        instance(u, d, args, u, def.pos);
        while (!queue.isEmpty()) {
          evaluateInstance(queue.poll());
        }
      }
    }
    for (RefAt r : refs) {
      if (r.inst.stream) {
        throw failIn(r.unit, r.pos, ErrorCode.MISPLACED_STREAM,
            r.inst.name + " is a Stream; a stream can only be the whole file, not part of a type");
      }
    }
    // §9.9: every cycle passes through a record, array or variant (Secret is no step).
    for (int start = 0; start < instances.size(); start++) {
      Instance inst = instances.get(start);
      Set<Instance> seen = java.util.Collections.newSetFromMap(new IdentityHashMap<>());
      Typ t = inst.body;
      while (t.kind == Kind.REF || t.kind == Kind.SECRET) {
        if (t.kind == Kind.SECRET) {
          t = t.elem;
          continue;
        }
        if (!seen.add(t.inst)) {
          DefRef at = defOf.get(start);
          throw failIn(at.u, units.get(at.u).file.types.get(at.d).pos, ErrorCode.UNGUARDED_RECURSION,
              "type " + inst.name + " refers to itself without a record, array or variant in between");
        }
        t = t.inst.body;
      }
    }
    for (Instance inst : instances) {
      Typ t = inst.body;
      while (t.kind == Kind.REF) {
        t = t.inst.body;
      }
      inst.resolved = t;
    }
    markJsonNull();
  }

  /** The key of a definition's template instance. */
  private static String templateKey(int u, int d, List<String> params) {
    if (params.isEmpty()) {
      return u + ":" + d;
    }
    List<String> keys = new ArrayList<>();
    for (String p : params) {
      keys.add("'" + p);
    }
    return u + ":" + d + "(" + String.join(",", keys) + ")";
  }

  /** The instance of definition {@code d} of file {@code u} with {@code args}, created if new. */
  private Instance instance(int u, int d, List<Typ> args, int at, int pos) {
    String key = u + ":" + d;
    if (!args.isEmpty()) {
      List<String> keys = new ArrayList<>();
      for (Typ a : args) {
        keys.add(key(a));
      }
      key += "(" + String.join(",", keys) + ")";
    }
    Integer known = byKey.get(key);
    if (known != null) {
      return instances.get(known);
    }
    if (instances.size() >= MAX_INSTANCES) {
      throw failIn(at, pos, ErrorCode.GROWING_RECURSION,
          "more than " + MAX_INSTANCES + " type instances: a generic type grows without bound");
    }
    int id = instances.size();
    Instance inst = new Instance(units.get(u).file.types.get(d).name, defId(u, d), args, id);
    instances.add(inst);
    defOf.add(new DefRef(u, d));
    states.add(State.NEW);
    byKey.put(key, id);
    queue.add(id);
    return inst;
  }

  /**
   * A text that tells types apart, for instances. It never holds the whole of an argument, which
   * can grow exponentially with legitimate nesting: an instance is keyed by its number, a record
   * or variant by the number of its shape, so a key is as long as one type expression.
   */
  private String key(Typ t) {
    switch (t.kind) {
      case TIME:
        return t.name;
      case PARAM:
        return "'" + t.name;
      case ARRAY:
        return "Array(" + key(t.elem) + ")";
      case MAP:
        return "Map(" + key(t.elem) + ")";
      case MAYBE:
        return "Maybe(" + key(t.elem) + ")";
      case SECRET:
        return "Secret(" + key(t.elem) + ")";
      case REF:
        return "#" + t.inst.idx;
      case RECORD:
        return recordKey(t.rec);
      case VARIANT: {
        String known = vrtKeys.get(t.vrt);
        if (known != null) {
          return known;
        }
        List<String> cases = new ArrayList<>();
        for (CaseType c : t.vrt.cases) {
          switch (c.payload) {
            case NONE:
              cases.add(c.tag);
              break;
            case RECORD:
              cases.add(c.tag + recordKey(c.rec));
              break;
            case NAMED:
              // Not the key of one positional argument: X R and X a with R for a differ.
              cases.add(c.tag + "{" + key(c.named) + "}");
              break;
            default: {
              List<String> items = new ArrayList<>();
              for (Typ x : c.items) {
                items.add(key(x));
              }
              cases.add(c.tag + "(" + String.join(",", items) + ")");
            }
          }
        }
        String k = shapeKey("<" + String.join("|", cases) + (t.vrt.open ? "|_" : "") + ">");
        vrtKeys.put(t.vrt, k);
        return k;
      }
      default:
        return t.kind.builtin;
    }
  }

  private String shapeKey(String shape) {
    return shapes.computeIfAbsent(shape, s -> "~" + shapes.size());
  }

  private String recordKey(RecordType r) {
    String known = recKeys.get(r);
    if (known != null) {
      return known;
    }
    List<String> fields = new ArrayList<>();
    for (FieldType f : r.fields) {
      StringBuilder b = new StringBuilder();
      Quoting.appendQuoted(b, f.key());
      fields.add(b + (f.optional() ? "?" : "") + ":" + key(f.typ()));
    }
    String k = shapeKey("{" + (r.closed ? "|" : "") + String.join(",", fields) + "}");
    recKeys.put(r, k);
    return k;
  }

  /** Evaluates the body of an instance, now if it isn't yet (a spread needs it). */
  private void evaluateInstance(int id) {
    DefRef at = defOf.get(id);
    TypeDef def = units.get(at.u).file.types.get(at.d);
    switch (states.get(id)) {
      case DONE:
        return;
      case BUSY:
        throw failIn(at.u, def.pos, ErrorCode.SPREAD_CYCLE, "type " + def.name + " spreads itself (directly or through another type)");
      default:
        break;
    }
    states.set(id, State.BUSY);
    Instance inst = instances.get(id);
    Map<String, Typ> env = new HashMap<>();
    for (int i = 0; i < def.params.size(); i++) {
      env.put(def.params.get(i), inst.args.get(i));
    }
    Typ body;
    boolean stream = false;
    if (def.ty.kind == TyKind.NAME && def.ty.name.equals("Stream")) {
      if (def.ty.args.size() != 1) {
        throw failIn(at.u, def.ty.pos, ErrorCode.WRONG_ARITY, "Stream takes 1 argument(s), found " + def.ty.args.size());
      }
      body = eval(at.u, def.ty.args.get(0), env);
      stream = true;
    } else {
      body = eval(at.u, def.ty, env);
    }
    inst.body = body;
    inst.stream = stream;
    states.set(id, State.DONE);
  }

  private record Binding(String param, int u, Ty ty, List<Binding> env) {}

  /**
   * Whether {@code t}, written in file {@code u}, is a record (spec §15), decided where it is
   * written: names are followed through their definitions, with their arguments as written, and a
   * type parameter of the definition it is written in is not a record, whatever its argument is.
   */
  private boolean isRecord(int u, Ty t) {
    List<Binding> env = null;
    for (int step = 0; step < MAX_INSTANCES; step++) {
      switch (t.kind) {
        case RECORD:
          return true;
        case VARIANT:
          return false;
        case PARAM: {
          Binding found = null;
          if (env != null) {
            for (Binding b : env) {
              if (b.param.equals(t.name)) {
                found = b;
                break;
              }
            }
          }
          if (found == null) {
            return false;
          }
          u = found.u;
          t = found.ty;
          env = found.env;
          break;
        }
        case NAME: {
          if (GENERIC.containsKey(t.name)) {
            return false;
          }
          DefRef at = units.get(u).scope.get(t.name);
          if (at == null) {
            return false;
          }
          TypeDef def = units.get(at.u).file.types.get(at.d);
          List<Binding> bound = new ArrayList<>();
          for (int i = 0; i < def.params.size() && i < t.args.size(); i++) {
            bound.add(new Binding(def.params.get(i), u, t.args.get(i), env));
          }
          u = at.u;
          t = def.ty;
          env = bound;
          break;
        }
      }
    }
    return false;
  }

  /** The record or variant {@code ...Name} copies ({@code want}: "record" or "variant"). */
  private Typ spread(int u, SchemaSyntax.SpreadDef s, String want) {
    DefRef at = units.get(u).scope.get(s.name());
    if (at == null) {
      if (units.get(u).std.containsKey(s.name()) || SchemaSyntax.PRELUDE.containsKey(s.name())) {
        throw failIn(u, s.pos(), ErrorCode.INVALID_SPREAD, s.name() + " is not a " + want + ", so it can't be spread here");
      }
      throw failIn(u, s.pos(), ErrorCode.UNKNOWN_TYPE, SchemaSyntax.unknownType(s.name()));
    }
    List<String> params = units.get(at.u).file.types.get(at.d).params;
    if (!params.isEmpty()) {
      throw failIn(u, s.pos(), ErrorCode.INVALID_SPREAD, s.name() + " has parameters (" + s.name() + " "
          + String.join(" ", params) + "); only a type without parameters can be spread");
    }
    Instance inst = instance(at.u, at.d, List.of(), u, s.pos());
    Set<Instance> seen = java.util.Collections.newSetFromMap(new IdentityHashMap<>());
    while (true) {
      evaluateInstance(inst.idx);
      if (inst.stream) {
        throw failIn(u, s.pos(), ErrorCode.INVALID_SPREAD, s.name() + " is a Stream and can't be spread");
      }
      Typ b = inst.body;
      if (b.kind == Kind.REF && seen.add(b.inst)) {
        inst = b.inst;
        continue;
      }
      if (b.kind == Kind.RECORD && want.equals("record") || b.kind == Kind.VARIANT && want.equals("variant")) {
        return b;
      }
      throw failIn(u, s.pos(), ErrorCode.INVALID_SPREAD, s.name() + " is not a " + want + ", so it can't be spread here");
    }
  }

  /** Evaluates a type expression of file {@code u}, with the parameters in {@code env}. */
  private Typ eval(int u, Ty t, Map<String, Typ> env) {
    switch (t.kind) {
      case PARAM: {
        Typ a = env.get(t.name);
        if (a == null) {
          throw failIn(u, t.pos, ErrorCode.UNKNOWN_PARAMETER, "unknown type parameter " + t.name);
        }
        return a;
      }
      case RECORD: {
        Typ r = new Typ(Kind.RECORD);
        r.rec = record(u, t, env);
        return r;
      }
      case VARIANT:
        return variant(u, t, env);
      default:
        return named(u, t, env);
    }
  }

  private record Entry<T>(T item, int pos) {}

  private Typ variant(int u, Ty t, Map<String, Typ> env) {
    List<Entry<CaseType>> own = new ArrayList<>();
    for (SchemaSyntax.CaseDef c : t.cases) {
      String deprecated = deprecatedOf(c.attrs);
      CaseType ct;
      if (c.payload.isEmpty()) {
        ct = new CaseType(c.tag, Payload.NONE, null, null, null, deprecated);
      } else if (c.payload.size() == 1 && c.payload.get(0).kind == TyKind.RECORD) {
        ct = new CaseType(c.tag, Payload.RECORD, record(u, c.payload.get(0), env), null, null, deprecated);
      } else {
        Typ[] items = new Typ[c.payload.size()];
        for (int i = 0; i < items.length; i++) {
          items[i] = eval(u, c.payload.get(i), env);
        }
        // A record case by name, if it is a record where it is written.
        if (items.length == 1 && c.payload.get(0).kind == TyKind.NAME && isRecord(u, c.payload.get(0))) {
          ct = new CaseType(c.tag, Payload.NAMED, null, items[0], null, deprecated);
        } else {
          ct = new CaseType(c.tag, Payload.POSITIONAL, null, null, items, deprecated);
        }
      }
      own.add(new Entry<>(ct, c.pos));
    }
    List<Entry<CaseType>> out = new ArrayList<>();
    for (int i = 0; i <= own.size(); i++) {
      for (SchemaSyntax.SpreadDef sp : t.spreads) {
        if (sp.at() == i) {
          for (CaseType c : spread(u, sp, "variant").vrt.cases) {
            out.add(new Entry<>(c, sp.pos()));
          }
        }
      }
      if (i < own.size()) {
        out.add(own.get(i));
      }
    }
    Set<String> seen = new HashSet<>();
    List<CaseType> cases = new ArrayList<>();
    for (Entry<CaseType> e : out) {
      if (!seen.add(e.item().tag)) {
        throw failIn(u, e.pos(), ErrorCode.DUPLICATE_TAG, "duplicate tag " + e.item().tag);
      }
      cases.add(e.item());
    }
    Typ v = new Typ(Kind.VARIANT);
    v.vrt = new VariantType(!t.closed, cases);
    return v;
  }

  private RecordType record(int u, Ty t, Map<String, Typ> env) {
    List<Entry<FieldType>> own = new ArrayList<>();
    for (SchemaSyntax.FieldDef fd : t.fields) {
      own.add(new Entry<>(new FieldType(fd.key, fd.optional, eval(u, fd.ty, env), deprecatedOf(fd.attrs)), fd.pos));
    }
    List<Entry<FieldType>> out = new ArrayList<>();
    for (int i = 0; i <= own.size(); i++) {
      for (SchemaSyntax.SpreadDef sp : t.spreads) {
        if (sp.at() == i) {
          for (FieldType f : spread(u, sp, "record").rec.fields) {
            out.add(new Entry<>(f, sp.pos()));
          }
        }
      }
      if (i < own.size()) {
        out.add(own.get(i));
      }
    }
    Set<String> seen = new HashSet<>();
    List<FieldType> fields = new ArrayList<>();
    for (Entry<FieldType> e : out) {
      if (!seen.add(e.item().key())) {
        throw failIn(u, e.pos(), ErrorCode.DUPLICATE_FIELD, "duplicate field " + SchemaText.quoteKey(e.item().key()));
      }
      fields.add(e.item());
    }
    return new RecordType(t.closed, fields);
  }

  private static String deprecatedOf(List<SchemaSyntax.Attribute> attrs) {
    return SchemaSyntax.isDeprecated(attrs) ? SchemaSyntax.deprecation(attrs) : null;
  }

  private Typ named(int u, Ty t, Map<String, Typ> env) {
    Integer n = GENERIC.get(t.name);
    if (n != null) {
      // Arity first, then where it is: `{ e: Stream }` is wrong-arity.
      arity(u, t, n);
      if (t.name.equals("Stream")) {
        throw failIn(u, t.pos, ErrorCode.MISPLACED_STREAM, "Stream is only allowed as the whole type of a definition");
      }
      List<Typ> args = evalArgs(u, t, env);
      switch (t.name) {
        case "Array":
          return Typ.of(Kind.ARRAY, args.get(0));
        case "Map":
          return Typ.of(Kind.MAP, args.get(0));
        case "Maybe":
          return Typ.of(Kind.MAYBE, args.get(0));
        case "Secret":
          return Typ.of(Kind.SECRET, args.get(0));
        default: {
          Typ v = new Typ(Kind.VARIANT);
          v.vrt = new VariantType(false, List.of(
              new CaseType("Err", Payload.POSITIONAL, null, null, new Typ[] {args.get(0)}, null),
              new CaseType("Ok", Payload.POSITIONAL, null, null, new Typ[] {args.get(1)}, null)));
          return v;
        }
      }
    }
    DefRef at = units.get(u).scope.get(t.name);
    if (at != null) {
      arity(u, t, units.get(at.u).file.types.get(at.d).params.size());
      Instance inst = instance(at.u, at.d, evalArgs(u, t, env), u, t.pos);
      refs.add(new RefAt(inst, u, t.pos));
      Typ r = new Typ(Kind.REF);
      r.inst = inst;
      return r;
    }
    String std = units.get(u).std.get(t.name);
    if (std != null) {
      arity(u, t, 0);
      return Typ.named(Kind.TIME, std);
    }
    Kind k = SchemaTypes.BUILTINS.get(t.name);
    if (k != null) {
      arity(u, t, 0);
      return new Typ(k);
    }
    throw failIn(u, t.pos, ErrorCode.UNKNOWN_TYPE, SchemaSyntax.unknownType(t.name));
  }

  private void arity(int u, Ty t, int n) {
    if (t.args.size() != n) {
      throw failIn(u, t.pos, ErrorCode.WRONG_ARITY, t.name + " takes " + n + " argument(s), found " + t.args.size());
    }
  }

  private List<Typ> evalArgs(int u, Ty t, Map<String, Typ> env) {
    List<Typ> out = new ArrayList<>();
    for (Ty a : t.args) {
      out.add(eval(u, a, env));
    }
    return out;
  }

  // ── Schema-based JSON (spec §16.3): decided when the schema loads ──

  /**
   * Decides, for every Maybe of the schema, whether its JSON writes None as null: when its item's
   * JSON can't be null, and it doesn't reach itself through Maybe, Secret and names only. A Maybe
   * is identified by where it is written: each MAYBE node of an instance is one.
   */
  private void markJsonNull() {
    List<Typ> maybes = new ArrayList<>();
    Set<Typ> seen = java.util.Collections.newSetFromMap(new IdentityHashMap<>());
    ArrayDeque<Typ> work = new ArrayDeque<>();
    for (Instance inst : instances) {
      work.push(inst.body);
    }
    while (!work.isEmpty()) {
      Typ t = work.pop();
      if (t == null || !seen.add(t)) {
        continue;
      }
      switch (t.kind) {
        case MAYBE:
          maybes.add(t);
          work.push(t.elem);
          break;
        case ARRAY:
        case MAP:
        case SECRET:
          work.push(t.elem);
          break;
        case RECORD:
          pushFields(work, t.rec);
          break;
        case VARIANT:
          for (CaseType c : t.vrt.cases) {
            if (c.rec != null) {
              pushFields(work, c.rec);
            }
            if (c.named != null) {
              work.push(c.named);
            }
            if (c.items != null) {
              for (Typ x : c.items) {
                work.push(x);
              }
            }
          }
          break;
        default:
          break;
      }
    }
    Map<Typ, Boolean> memo = new IdentityHashMap<>();
    for (Typ m : maybes) {
      m.jsonNull = usesNull(m, memo);
    }
  }

  private static void pushFields(ArrayDeque<Typ> work, RecordType r) {
    for (FieldType f : r.fields) {
      work.push(f.typ());
    }
  }

  private static boolean usesNull(Typ m, Map<Typ, Boolean> memo) {
    Boolean known = memo.get(m);
    if (known != null) {
      return known;
    }
    memo.put(m, false); // a cycle back here is a Maybe that reaches itself
    boolean v = !reachesItself(m) && !jsonNullable(m.elem, memo);
    memo.put(m, v);
    return v;
  }

  /** Whether the Maybe {@code m} reaches itself through Maybe, Secret and names only. */
  private static boolean reachesItself(Typ m) {
    Set<Typ> seen = java.util.Collections.newSetFromMap(new IdentityHashMap<>());
    for (Typ t = m.elem; ; ) {
      switch (t.kind) {
        case REF:
          t = t.inst.body;
          break;
        case MAYBE:
        case SECRET:
          if (t == m) {
            return true;
          }
          if (!seen.add(t)) {
            return false;
          }
          t = t.elem;
          break;
        default:
          return false;
      }
    }
  }

  /** Whether a type's JSON can be null: a Maybe that uses null, directly or through names and Secret. */
  private static boolean jsonNullable(Typ t, Map<Typ, Boolean> memo) {
    while (true) {
      switch (t.kind) {
        case REF:
          t = t.inst.body;
          break;
        case SECRET:
          t = t.elem;
          break;
        case MAYBE:
          return usesNull(t, memo);
        default:
          return false;
      }
    }
  }

  /** The field named {@code _tag} or {@code _args} of a record case, which has no JSON form; null if none. */
  static String reservedField(CaseType c) {
    RecordType r = caseRecord(c);
    if (r == null) {
      return null;
    }
    for (FieldType f : r.fields) {
      if (f.key().equals("_tag") || f.key().equals("_args")) {
        return f.key();
      }
    }
    return null;
  }

  /** The record of a record case (written inline or by name); null for other cases. */
  static RecordType caseRecord(CaseType c) {
    if (c.payload == Payload.RECORD) {
      return c.rec;
    }
    if (c.payload == Payload.NAMED) {
      Typ t = c.named.resolve();
      return t.kind == Kind.RECORD ? t.rec : null;
    }
    return null;
  }

  private record Found(int pos, String msg) {}

  /**
   * The record cases written in file {@code u} with a field named {@code _tag} or {@code _args},
   * which have no schema-based JSON form (§16.3): checkers warn about them (no-json-form), at the
   * case.
   */
  private List<HausException> noJsonForms(int u) {
    Unit unit = units.get(u);
    List<Found> all = new ArrayList<>();
    for (int d = 0; d < unit.file.types.size(); d++) {
      TypeDef def = unit.file.types.get(d);
      Instance inst = instances.get(byKey.get(templateKey(u, d, def.params)));
      Ty t = def.ty;
      if (t.kind == TyKind.NAME && t.name.equals("Stream") && inst.stream && t.args.size() == 1) {
        t = t.args.get(0);
      }
      jsonCases(t, inst.body, all);
    }
    all.sort(Comparator.comparingInt(Found::pos));
    List<HausException> out = new ArrayList<>();
    int last = -1;
    for (Found f : all) {
      if (f.pos == last) {
        continue;
      }
      last = f.pos;
      int[] lc = SchemaSyntax.lineCol(unit.text, f.pos);
      out.add(new HausException(ErrorCode.NO_JSON_FORM, f.msg, lc[0], lc[1], null, null, null));
    }
    return out;
  }

  private void jsonCases(Ty t, Typ rt, List<Found> all) {
    if (t.kind == TyKind.NAME && t.name.equals("Result") && rt.kind == Kind.VARIANT) {
      String[] tags = {"Err", "Ok"};
      for (int i = 0; i < 2; i++) {
        CaseType c = rt.vrt.caseOf(tags[i]);
        if (c != null && c.payload == Payload.POSITIONAL && i < t.args.size()) {
          jsonCases(t.args.get(i), c.items[0], all);
        }
      }
    } else if (t.kind == TyKind.NAME
        && (rt.kind == Kind.ARRAY || rt.kind == Kind.MAP || rt.kind == Kind.MAYBE || rt.kind == Kind.SECRET)) {
      for (Ty a : t.args) {
        jsonCases(a, rt.elem, all);
      }
    } else if (t.kind == TyKind.RECORD && rt.kind == Kind.RECORD) {
      inFields(t.fields, rt.rec, all);
    } else if (t.kind == TyKind.VARIANT && rt.kind == Kind.VARIANT) {
      for (SchemaSyntax.CaseDef cd : t.cases) {
        CaseType c = rt.vrt.caseOf(cd.tag);
        if (c == null) {
          continue;
        }
        String f = reservedField(c);
        if (f != null) {
          all.add(new Found(cd.pos, cd.tag + " has a field named " + f + ", so it has no schema-based JSON form"));
        }
        if (c.payload == Payload.RECORD && cd.payload.size() == 1 && cd.payload.get(0).kind == TyKind.RECORD) {
          inFields(cd.payload.get(0).fields, c.rec, all);
        } else if (c.payload == Payload.NAMED && cd.payload.size() == 1) {
          jsonCases(cd.payload.get(0), c.named, all);
        } else if (c.payload == Payload.POSITIONAL && cd.payload.size() == c.items.length) {
          for (int i = 0; i < c.items.length; i++) {
            jsonCases(cd.payload.get(i), c.items[i], all);
          }
        }
      }
    }
    // Named types are checked where they are defined; parameters and scalars have no cases.
  }

  private void inFields(List<SchemaSyntax.FieldDef> fields, RecordType r, List<Found> all) {
    for (SchemaSyntax.FieldDef f : fields) {
      FieldType x = r.field(f.key);
      if (x != null) {
        jsonCases(f.ty, x.typ(), all);
      }
    }
  }
}
