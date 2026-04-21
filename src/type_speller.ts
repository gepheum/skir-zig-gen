import type {
  FieldPath,
  Primitive,
  PrimitiveType,
  RecordKey,
  RecordLocation,
  ResolvedRecordRef,
  ResolvedType,
} from "skir-internal";
import { KeyedArrayContext } from "./keyed_array_context.js";
import {
  getTypeName,
  modulePathToImportAlias,
  toFieldGetterName,
  toStructFieldName,
} from "./naming.js";

export class TypeSpeller {
  constructor(
    readonly recordMap: ReadonlyMap<RecordKey, RecordLocation>,
    readonly modulePath: string,
    readonly keyedArrayContext: KeyedArrayContext,
  ) {}

  getZigType(
    type: ResolvedType,
    options: { keyedSpecName?: string } = {},
  ): string {
    switch (type.kind) {
      case "record": {
        const recordLocation = this.recordMap.get(type.key)!;
        const typeName = getTypeName(recordLocation);
        if (recordLocation.modulePath === this.modulePath) {
          return typeName;
        }
        return `${modulePathToImportAlias(recordLocation.modulePath)}.${typeName}`;
      }
      case "array": {
        const keyedSpecName =
          options.keyedSpecName ??
          (type.key
            ? this.keyedArrayContext.getKeySpecForArrayType(type, this)?.specRef
            : undefined);
        if (keyedSpecName) {
          return `skir_client.KeyedArray(${keyedSpecName})`;
        }
        return `[]const ${this.getZigType(type.item)}`;
      }
      case "optional":
        return `?${this.getZigType(type.other, options)}`;
      case "primitive":
        return primitiveToZigType(type.primitive);
    }
  }

  getDefaultExpr(
    type: ResolvedType,
    options: { keyedSpecName?: string } = {},
  ): string {
    switch (type.kind) {
      case "record": {
        const recordLocation = this.recordMap.get(type.key)!;
        const defaultMember =
          recordLocation.record.recordType === "enum" ? "unknown" : "default";
        return `${this.getZigType(type)}.${defaultMember}`;
      }
      case "array": {
        const keyedSpecName =
          options.keyedSpecName ??
          (type.key
            ? this.keyedArrayContext.getKeySpecForArrayType(type, this)?.specRef
            : undefined);
        if (keyedSpecName) {
          return `skir_client.KeyedArray(${keyedSpecName}).empty()`;
        }
        return "&.{}";
      }
      case "optional":
        return "null";
      case "primitive":
        return primitiveDefaultExpr(type.primitive);
    }
  }

  getKeyType(keyType: PrimitiveType | ResolvedRecordRef): string {
    if (keyType.kind === "primitive") {
      return primitiveToZigType(keyType.primitive);
    }
    return `${this.getZigType(keyType)}.Kind`;
  }

  getTypeName(recordKey: RecordKey): string {
    const recordLocation = this.recordMap.get(recordKey)!;
    const typeName = getTypeName(recordLocation);
    if (recordLocation.modulePath === this.modulePath) {
      return typeName;
    }
    return `${modulePathToImportAlias(recordLocation.modulePath)}.${typeName}`;
  }

  getKeyAccessor(baseExpr: string, fieldPath: FieldPath): string {
    const parts = fieldPath.path;
    let expr = baseExpr;
    for (const [index, part] of parts.entries()) {
      const isLast = index === parts.length - 1;
      if (
        isLast &&
        fieldPath.keyType.kind === "record" &&
        part.name.text === "kind"
      ) {
        expr = `${expr}.kind()`;
        continue;
      }

      if (part.declaration?.isRecursive) {
        expr = `${expr}.${toFieldGetterName(part.name.text)}()`;
      } else {
        expr = `${expr}.${toStructFieldName(part.name.text)}`;
      }
    }
    return expr;
  }
}

function primitiveToZigType(primitive: Primitive): string {
  switch (primitive) {
    case "bool":
      return "bool";
    case "int32":
      return "i32";
    case "int64":
      return "i64";
    case "hash64":
      return "u64";
    case "float32":
      return "f32";
    case "float64":
      return "f64";
    case "timestamp":
      return "skir_client.Timestamp";
    case "string":
    case "bytes":
      return "[]const u8";
  }
}

function primitiveDefaultExpr(primitive: Primitive): string {
  switch (primitive) {
    case "bool":
      return "false";
    case "int32":
    case "int64":
    case "hash64":
      return "0";
    case "float32":
    case "float64":
      return "0.0";
    case "timestamp":
      return ".{}";
    case "string":
    case "bytes":
      return '""';
  }
}
