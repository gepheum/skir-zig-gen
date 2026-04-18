import { type Field, type RecordLocation, convertCase } from "skir-internal";

export function modulePathToOutputPath(modulePath: string): string {
  return modulePath
    .replace(/^@/, "external/")
    .replace(/-/g, "_")
    .replace(/\.skir$/, ".zig");
}

export function modulePathToImportAlias(modulePath: string): string {
  const alias = modulePathToOutputPath(modulePath)
    .replace(/\.zig$/, "")
    .replace(/[^A-Za-z0-9_]/g, "_");
  return RESERVED_LOWER_NAMES.has(alias) ? `${alias}_module` : alias;
}

export function getTypeName(record: RecordLocation): string {
  return record.recordAncestors
    .map((ancestor) => toTypeName(ancestor.name.text))
    .join(".");
}

export function toTypeName(input: string): string {
  const name = convertCase(input, "UpperCamel");
  return RESERVED_TYPE_NAMES.has(name) ? `${name}Type` : name;
}

export function toStructFieldName(input: string): string {
  const name = convertCase(input, "lower_underscore");
  if (name === "_unrecognized") {
    return "_unrecognized_field";
  }
  return RESERVED_LOWER_NAMES.has(name) ? `${name}_field` : name;
}

export function toFieldGetterName(field: Field | string): string {
  const source = typeof field === "string" ? field : field.name.text;
  const name = `get${convertCase(source, "UpperCamel")}`;
  return RESERVED_METHOD_NAMES.has(name) ? `${name}Value` : name;
}

export function toVariantName(input: string): string {
  const name = convertCase(input, "UpperCamel");
  if (name === "Unknown") {
    return "UnknownVariant";
  }
  return RESERVED_TYPE_NAMES.has(name) ? `${name}Variant` : name;
}

const RESERVED_LOWER_NAMES = new Set<string>([
  "addrspace",
  "align",
  "allowzero",
  "and",
  "anyframe",
  "anytype",
  "asm",
  "async",
  "await",
  "break",
  "callconv",
  "catch",
  "comptime",
  "const",
  "continue",
  "defer",
  "else",
  "enum",
  "errdefer",
  "error",
  "export",
  "extern",
  "false",
  "fn",
  "for",
  "if",
  "inline",
  "linksection",
  "noalias",
  "nosuspend",
  "null",
  "opaque",
  "or",
  "orelse",
  "packed",
  "pub",
  "resume",
  "return",
  "linksection",
  "struct",
  "suspend",
  "switch",
  "test",
  "threadlocal",
  "true",
  "try",
  "union",
  "unreachable",
  "usingnamespace",
  "var",
  "volatile",
  "while",
  "skir_client",
  "std",
]);

const RESERVED_TYPE_NAMES = new Set<string>([
  "AnyType",
  "DEFAULT",
  "Default",
  "Kind",
  "Self",
  "Unknown",
  "Void",
]);

const RESERVED_METHOD_NAMES = new Set<string>(["defaultRef", "kind"]);
