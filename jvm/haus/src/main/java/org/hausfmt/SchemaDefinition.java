package org.hausfmt;

import java.util.List;

/**
 * A type definition of a schema file, its own or imported.
 *
 * @param name its name in the file (imported types keep their names)
 * @param id its id (spec §13.3): {@code @haus-fmt/money@1#Money}, {@code file-id#Name}
 * @param params its type parameters
 * @param doc the {@code //} comment lines just above it
 * @param deprecated whether it is {@code @deprecated}
 * @param why the message of {@code @deprecated("…")}, or ""
 */
public record SchemaDefinition(
    String name, String id, List<String> params, String doc, boolean deprecated, String why) {}
