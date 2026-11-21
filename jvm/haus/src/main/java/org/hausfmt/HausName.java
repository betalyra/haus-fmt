package org.hausfmt;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * The name a schema gives a record component or a case class, for a {@link HausCodec}, where it
 * isn't the Java name: a field {@code "pt-BR"} or {@code default}, a tag {@code Other} for a class
 * {@code OtherCase}.
 *
 * <pre>{@code
 * record Labels(@HausName("pt-BR") String ptBr, @HausName("default") String fallback) {}
 * }</pre>
 */
@Retention(RetentionPolicy.RUNTIME)
@Target({ElementType.RECORD_COMPONENT, ElementType.PARAMETER, ElementType.TYPE})
public @interface HausName {
  /** The field's key or the case's tag in the schema. */
  String value();
}
