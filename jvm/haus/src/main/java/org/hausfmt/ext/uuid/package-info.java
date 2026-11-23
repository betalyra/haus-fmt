/**
 * The codecs of the profile {@code @haus-fmt/uuid/rfc9562} for the type of the schema package
 * {@code @haus-fmt/uuid} (extensions/uuid): {@code Uuid}, a universally unique identifier, {@code
 * Uuid("0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57")}.
 *
 * <p>The schema fixes the shape; the profile's rule, which these codecs check, is the text form of
 * RFC 9562 in lowercase (extensions/uuid/profiles/rfc9562.md): 32 digits 0–9, a–f in groups
 * 8-4-4-4-12, joined by hyphens. Any version and variant is accepted, the nil and the max UUID
 * too. {@link org.hausfmt.ext.uuid.UuidCodecs#RFC9562} gives the text, {@link
 * org.hausfmt.ext.uuid.UuidCodecs#RFC9562_AS_UUID} a {@link java.util.UUID}; both keep the value,
 * as the text is the UUID's one spelling.
 *
 * <pre>{@code
 * DecodeOptions options = DecodeOptions.DEFAULT.withCodecs(Codecs.of(UuidCodecs.RFC9562_AS_UUID));
 * Value user = s.type("User").decode(value, options);
 * }</pre>
 */
package org.hausfmt.ext.uuid;
