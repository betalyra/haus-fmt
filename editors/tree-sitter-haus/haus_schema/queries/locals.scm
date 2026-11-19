; Type names are defined for the whole file; type parameters for their
; definition.

(schema_file) @local.scope

(type_definition) @local.scope

((type_definition
  name: (type_name) @local.definition.type)
  (#set! definition.type.scope "parent"))

(import
  name: (type_name) @local.definition.import)

(type_definition
  parameter: (type_parameter) @local.definition.parameter)

(type_name) @local.reference

(type_parameter) @local.reference
