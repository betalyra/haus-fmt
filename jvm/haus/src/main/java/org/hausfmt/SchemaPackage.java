package org.hausfmt;

/**
 * A schema package a schema reaches, directly or through other packages.
 *
 * @param name its name: {@code @haus-fmt/money}
 * @param version the version of its manifest: {@code 1.2.0}
 * @param dir its directory, a real path
 */
public record SchemaPackage(String name, String version, String dir) {}
