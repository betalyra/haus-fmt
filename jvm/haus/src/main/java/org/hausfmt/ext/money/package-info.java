/**
 * The codecs of the profile {@code @haus-fmt/money/iso} for the types of the schema package
 * {@code @haus-fmt/money} (extensions/money): {@link org.hausfmt.ext.money.Money}, an exact amount
 * with a currency, and {@link org.hausfmt.ext.money.Currency}, a bare tag.
 *
 * <p>The schema fixes the shape; the profile's rule, which these codecs check, is that a currency
 * is three capital letters A–Z, the shape of an ISO 4217 code
 * (extensions/money/profiles/iso.md). Whether the code is assigned is not checked.
 *
 * <p>The schema itself is found like any package's (spec §13.3), for example in a folder of
 * packages:
 *
 * <pre>{@code
 * Schema s = Schema.load(Path.of("order.schema.haus"),
 *     SchemaOptions.DEFAULT.withPackages(PackageLocator.explicit().folder(Path.of("node_modules/@haus-fmt"))));
 * DecodeOptions options = DecodeOptions.DEFAULT.withCodecs(Codecs.of(MoneyCodecs.ISO, MoneyCodecs.ISO_CURRENCY));
 * Value order = s.type("Order").decode(value, options);
 * }</pre>
 */
package org.hausfmt.ext.money;
