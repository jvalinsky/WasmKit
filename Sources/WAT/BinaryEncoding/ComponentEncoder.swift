#if ComponentModel
    import ComponentModel
    import WasmParser
    import WasmTypes

    /// Binary encoder for components. Iterates the normalized definitions array in order,
    /// batching consecutive same-type definitions into sections.
    package struct ComponentEncoder: Sendable {
        private var underlying = Encoder()
        private let features: WasmFeatureSet
        /// Pre-encoded bytes for nested components, consumed in definition order.
        private var preEncodedChildren: [[UInt8]] = []
        /// Consumption index into preEncodedChildren (avoids O(n) removeFirst).
        private var preEncodedChildrenOffset: Int = 0

        package init(features: WasmFeatureSet = .default) {
            self.features = features
        }

        mutating func writeHeader() {
            underlying.output.append(contentsOf: ComponentHeader.magic)
            underlying.output.append(contentsOf: ComponentHeader.version)
            underlying.output.append(contentsOf: ComponentHeader.layer)
        }

        /// Encode a component using the normalized definitions array.
        package mutating func encode(
            _ component: ComponentWatParser.ComponentDef,
            options: EncodeOptions
        ) throws(WatParserError) -> [UInt8] {
            // Post-order DFS: encode leaf components first, parents after.
            // Child counts are recorded during traversal to avoid re-scanning definitions.
            var postOrder: [(component: ComponentWatParser.ComponentDef, childCount: Int)] = []
            var stack: [(component: ComponentWatParser.ComponentDef, visited: Bool, childCount: Int)] =
                [(component, false, 0)]
            while let top = stack.popLast() {
                if top.visited {
                    postOrder.append((top.component, top.childCount))
                } else {
                    var childCount = 0
                    // Push visited marker FIRST (below children on stack)
                    // so children are popped and processed before parent
                    stack.append((top.component, true, 0))  // childCount filled below
                    let visitedIdx = stack.count - 1
                    for def in top.component.definitions.reversed() {
                        if case .nestedComponent(let nested) = def {
                            stack.append((nested, false, 0))
                            childCount += 1
                        }
                    }
                    stack[visitedIdx].childCount = childCount
                }
            }

            // Encode bottom-up: each component's children bytes are already on the stack
            var encodedStack: [[UInt8]] = []
            for (comp, childCount) in postOrder {
                let childStart = encodedStack.count - childCount
                preEncodedChildren = Array(encodedStack[childStart...])
                preEncodedChildrenOffset = 0
                encodedStack.removeSubrange(childStart...)

                let bytes = try encodeComponentBody(comp, options: options)
                assert(
                    preEncodedChildrenOffset == preEncodedChildren.count,
                    "Not all pre-encoded children were consumed"
                )
                encodedStack.append(bytes)
            }
            precondition(!encodedStack.isEmpty, "encodedStack should contain the root component")
            return encodedStack.removeLast()
        }

        /// Encode a single component (header + sections + name section).
        /// Nested components are resolved from preEncodedChildren.
        private mutating func encodeComponentBody(
            _ component: ComponentWatParser.ComponentDef,
            options: EncodeOptions
        ) throws(WatParserError) -> [UInt8] {
            underlying = Encoder()
            writeHeader()

            // Use pre-computed index mappings from the parser
            let typeIndexMapping = component.typeIndexMapping

            // Iterate through definitions with automatic batching
            var currentKind: ComponentSectionID? = nil
            var batchStart: Int = 0
            var batchCount: Int = 0

            for (index, definition) in component.definitions.enumerated() {
                if definition.sectionKind != currentKind {
                    // Flush current batch
                    if batchCount > 0, let kind = currentKind {
                        try encodeSection(
                            kind: kind,
                            definitions: component.definitions[batchStart..<batchStart + batchCount],
                            component: component,
                            typeIndexMapping: typeIndexMapping
                        )
                    }
                    currentKind = definition.sectionKind
                    batchStart = index
                    batchCount = 1
                } else {
                    batchCount += 1
                }
            }

            // Flush final batch
            if batchCount > 0, let kind = currentKind {
                try encodeSection(
                    kind: kind,
                    definitions: component.definitions[batchStart...],
                    component: component,
                    typeIndexMapping: typeIndexMapping
                )
            }

            // Encode name section if requested
            if options.nameSection {
                try encodeNameSection(component, typeIndexMapping: typeIndexMapping)
            }

            return underlying.output
        }

        private mutating func encodeSection(
            kind: ComponentSectionID,
            definitions: some Collection<NormalizedDefinition>,
            component: ComponentWatParser.ComponentDef,
            typeIndexMapping: [Int: Int]
        ) throws(WatParserError) {
            // Core modules and nested components are encoded one per section (no count prefix)
            // Other section types use vectors with count prefixes
            switch kind {
            case .coreModule, .component, .start:
                // Each definition gets its own section
                for definition in definitions {
                    var tempEncoder = Encoder()
                    try encodeDefinition(
                        definition,
                        encoder: &tempEncoder,
                        component: component,
                        typeIndexMapping: typeIndexMapping
                    )
                    underlying.section(id: kind.rawValue) { encoder in
                        encoder.output.append(contentsOf: tempEncoder.output)
                    }
                }

            default:
                // Vector sections with count prefix
                var tempEncoder = Encoder()
                tempEncoder.writeUnsignedLEB128(UInt32(definitions.count))
                for definition in definitions {
                    try encodeDefinition(
                        definition,
                        encoder: &tempEncoder,
                        component: component,
                        typeIndexMapping: typeIndexMapping
                    )
                }
                underlying.section(id: kind.rawValue) { encoder in
                    encoder.output.append(contentsOf: tempEncoder.output)
                }
            }
        }

        private mutating func encodeDefinition(
            _ definition: NormalizedDefinition,
            encoder: inout Encoder,
            component: ComponentWatParser.ComponentDef,
            typeIndexMapping: [Int: Int]
        ) throws(WatParserError) {
            switch definition {
            case .coreModule(let moduleDef):
                try Self.encodeCoreModule(moduleDef, encoder: &encoder)

            case .coreInstance(let instanceDef):
                try Self.encodeCoreInstance(
                    instanceDef,
                    encoder: &encoder,
                    component: component
                )

            case .coreType(let coreTypeDef):
                try Self.encodeCoreType(coreTypeDef, encoder: &encoder, component: component)

            case .componentType(let typeDef, _):
                try Self.encodeComponentType(
                    typeDef,
                    encoder: &encoder,
                    component: component,
                    typeIndexMapping: typeIndexMapping
                )

            case .nestedComponent:
                encoder.output.append(contentsOf: preEncodedChildren[preEncodedChildrenOffset])
                preEncodedChildrenOffset += 1

            case .componentInstance(let instanceDef):
                try Self.encodeComponentInstance(
                    instanceDef,
                    encoder: &encoder,
                    component: component,
                    typeIndexMapping: typeIndexMapping
                )

            case .alias(let aliasDef):
                try Self.encodeAlias(aliasDef, encoder: &encoder, component: component)

            case .canon(let canonDef):
                try Self.encodeCanon(
                    canonDef,
                    encoder: &encoder,
                    component: component,
                    typeIndexMapping: typeIndexMapping
                )

            case .componentStart(let startDef):
                try Self.encodeStart(
                    startDef,
                    encoder: &encoder,
                    component: component
                )

            case .componentImport(let importDef):
                try Self.encodeImport(
                    importDef,
                    encoder: &encoder,
                    component: component,
                    typeIndexMapping: typeIndexMapping
                )

            case .componentExport(let exportDef):
                try Self.encodeExport(
                    exportDef,
                    encoder: &encoder,
                    component: component,
                    typeIndexMapping: typeIndexMapping
                )
            }
        }

        // MARK: - Individual Definition Encoders

        private static func encodeCoreModule(
            _ moduleDef: ComponentWatParser.ModuleDef,
            encoder: inout Encoder
        ) throws(WatParserError) {
            switch moduleDef.content {
            case .binary(let bytes):
                encoder.output.append(contentsOf: bytes)
            case .wat(var mutableWat):
                if mutableWat.id == nil, let id = moduleDef.id {
                    mutableWat.id = .identifier(id.value)
                }
                let moduleBytes = try WAT.encode(
                    module: &mutableWat,
                    options: EncodeOptions(nameSection: true)
                )
                encoder.output.append(contentsOf: moduleBytes)
            case .placeholder:
                preconditionFailure("encodeCoreModule called for placeholder module (alias/inline-import)")
            }
        }

        private static func encodeCoreInstance(
            _ instanceDef: ComponentWatParser.CoreInstanceDef,
            encoder: inout Encoder,
            component: ComponentWatParser.ComponentDef
        ) throws(WatParserError) {
            switch instanceDef.form {
            case .instantiate(let moduleId, let arguments):
                // 0x00 = instantiate form
                encoder.output.append(0x00)

                // Module index
                let moduleIndex = try component.coreModulesMap.resolveIndex(use: moduleId)
                encoder.writeUnsignedLEB128(UInt32(moduleIndex))

                // Arguments
                encoder.writeUnsignedLEB128(UInt32(arguments.count))
                for arg in arguments {
                    encoder.encode(arg.importName)
                    switch arg.kind {
                    case .instance(let instanceRef):
                        encoder.output.append(0x12)  // instance sort
                        let index = try component.coreInstancesMap.resolveIndex(use: instanceRef)
                        encoder.writeUnsignedLEB128(UInt32(index))
                    case .exports:
                        // Inline exports are converted to instance references during parsing,
                        // so this case should not occur after desugaring.
                        fatalError("Inline exports should have been desugared during parsing")
                    }
                }

            case .exports(let exports):
                // 0x01 = exports-only form (synthetic instance from desugaring)
                // Binary.md: core:instanceexpr ::= 0x01 e*:vec(<core:inlineexport>)
                // core:inlineexport ::= n:<core:name> si:<core:sortidx>
                // core:sortidx ::= sort:<core:sort> idx:<u32>
                encoder.output.append(0x01)
                encoder.writeUnsignedLEB128(UInt32(exports.count))
                for export in exports {
                    encoder.encode(export.name)
                    encoder.output.append(export.sort.binaryEncoding)
                    encoder.writeUnsignedLEB128(export.index)
                }
            }
        }

        private static func encodeCoreType(
            _ coreTypeDef: ComponentWatParser.CoreTypeDef,
            encoder: inout Encoder,
            component: ComponentWatParser.ComponentDef
        ) throws(WatParserError) {
            switch coreTypeDef.kind {
            case .function(let funcType):
                encoder.output.append(0x60)  // func type
                encoder.writeUnsignedLEB128(UInt32(funcType.signature.parameters.count))
                for param in funcType.signature.parameters {
                    encoder.encode(param)
                }
                encoder.writeUnsignedLEB128(UInt32(funcType.signature.results.count))
                for result in funcType.signature.results {
                    encoder.encode(result)
                }

            case .module(let moduleTypeDef):
                encoder.output.append(0x50)  // module type
                encoder.writeUnsignedLEB128(UInt32(moduleTypeDef.declarations.count))
                for decl in moduleTypeDef.declarations {
                    try encodeModuleDecl(decl, encoder: &encoder, bindings: moduleTypeDef.localTypeBindings)
                }
            }
        }

        private static func encodeModuleDecl(
            _ decl: ComponentWatParser.CoreModuleDecl,
            encoder: inout Encoder,
            bindings: [String: Int]
        ) throws(WatParserError) {
            switch decl {
            case .type(let funcType):
                // Type declaration in module type body
                encoder.output.append(0x01)  // type declaration tag
                encoder.output.append(0x60)  // func type
                encoder.encodeVector(funcType.parameters) { param, encoder in
                    param.encode(to: &encoder)
                }
                encoder.encodeVector(funcType.results) { result, encoder in
                    result.encode(to: &encoder)
                }

            case .import(let importDef):
                encoder.output.append(0x00)  // import declaration
                encoder.encode(importDef.moduleName)
                encoder.encode(importDef.name)
                encodeCoreImportDesc(importDef.descriptor, encoder: &encoder, bindings: bindings)

            case .alias(let alias):
                encoder.output.append(0x02)  // alias declaration
                encoder.output.append(alias.sort.binaryEncoding)
                switch alias.target {
                case .outer(_, _, let resolvedIndex, let outerCount):
                    encoder.output.append(0x01)  // outer alias kind
                    encoder.writeUnsignedLEB128(UInt32(outerCount))
                    encoder.writeUnsignedLEB128(UInt32(resolvedIndex))
                }

            case .export(let exportDef):
                encoder.output.append(0x03)  // export declaration
                encoder.encode(exportDef.name)
                encodeCoreImportDesc(exportDef.descriptor, encoder: &encoder, bindings: bindings)
            }
        }

        /// Encode a core import/export descriptor (core:importdesc in the binary spec).
        /// Used for both import declarations and export declarations in module types.
        private static func encodeCoreImportDesc(
            _ desc: ComponentWatParser.CoreImportDesc,
            encoder: inout Encoder,
            bindings: [String: Int]
        ) {
            switch desc {
            case .func(let typeRef):
                encoder.output.append(0x00)  // func
                let typeIndex = resolveTypeRef(typeRef, bindings: bindings)
                encoder.writeUnsignedLEB128(UInt32(typeIndex))
            case .global(let globalType):
                encoder.output.append(0x03)  // global
                globalType.encode(to: &encoder)
            case .table(let tableType):
                encoder.output.append(0x01)  // table
                tableType.encode(to: &encoder)
            case .memory(let memoryType):
                encoder.output.append(0x02)  // memory
                memoryType.encode(to: &encoder)
            }
        }

        private static func resolveTypeRef(_ ref: Parser.IndexOrId, bindings: [String: Int]) -> Int {
            switch ref {
            case .index(let idx, _):
                return Int(idx)
            case .id(let name, _):
                return bindings[name.value] ?? 0
            }
        }

        private static func encodeComponentType(
            _ typeDef: ComponentWatParser.ComponentTypeDef,
            encoder: inout Encoder,
            component: ComponentWatParser.ComponentDef,
            typeIndexMapping: [Int: Int]
        ) throws(WatParserError) {
            switch typeDef.kind {
            case .function(let funcType):
                encoder.append(funcType.isAsync ? DefinedTypeOpcode.funcAsync : DefinedTypeOpcode.funcSync)
                try encodeFuncType(funcType, encoder: &encoder, component: component, typeIndexMapping: typeIndexMapping)

            case .value(let valueType):
                try encodeValueType(valueType, encoder: &encoder, component: component, typeIndexMapping: typeIndexMapping)

            case .instance(let decls):
                encoder.append(DefinedTypeOpcode.instanceType)
                try encodeComponentTypeDecls(decls, encoder: &encoder, component: component, typeIndexMapping: typeIndexMapping)

            case .component(let decls):
                encoder.append(DefinedTypeOpcode.componentType)
                try encodeComponentTypeDecls(decls, encoder: &encoder, component: component, typeIndexMapping: typeIndexMapping)
            }
        }

        private static func encodeFuncType(
            _ funcType: ComponentFuncType,
            encoder: inout Encoder,
            component: ComponentWatParser.ComponentDef,
            typeIndexMapping: [Int: Int]
        ) throws(WatParserError) {
            // Params
            encoder.writeUnsignedLEB128(UInt32(funcType.params.count))
            for param in funcType.params {
                encoder.encode(param.name)
                try encodeValueType(param.type, encoder: &encoder, component: component, typeIndexMapping: typeIndexMapping)
            }

            // Result
            if let result = funcType.result {
                encoder.output.append(0x00)  // single anonymous result
                try encodeValueType(result, encoder: &encoder, component: component, typeIndexMapping: typeIndexMapping)
            } else {
                encoder.output.append(0x01)  // named results form
                encoder.output.append(0x00)  // 0 named results = no result
            }
        }

        private static func encodeValueType(
            _ valueType: ComponentDefValType,
            encoder: inout Encoder,
            component: ComponentWatParser.ComponentDef,
            typeIndexMapping: [Int: Int]
        ) throws(WatParserError) {
            switch valueType {
            // Inlined types (primitive or indexed)
            case .inlined(let inlined):
                try encodeInlinedValueType(inlined, encoder: &encoder, typeIndexMapping: typeIndexMapping)
            case .own(let typeIndex):
                encoder.append(CompositeValTypeOpcode.own)
                let mappedIndex = typeIndexMapping[Int(typeIndex.rawValue)] ?? Int(typeIndex.rawValue)
                encoder.writeUnsignedLEB128(UInt32(mappedIndex))
            case .borrow(let typeIndex):
                encoder.append(CompositeValTypeOpcode.borrow)
                let mappedIndex = typeIndexMapping[Int(typeIndex.rawValue)] ?? Int(typeIndex.rawValue)
                encoder.writeUnsignedLEB128(UInt32(mappedIndex))
            case .list(let elemType):
                encoder.append(CompositeValTypeOpcode.list)
                try encodeInlinedValueType(elemType, encoder: &encoder, typeIndexMapping: typeIndexMapping)
            case .record(let fields):
                encoder.append(CompositeValTypeOpcode.record)
                encoder.writeUnsignedLEB128(UInt32(fields.count))
                for field in fields {
                    encoder.encode(field.name)
                    try encodeInlinedValueType(field.type, encoder: &encoder, typeIndexMapping: typeIndexMapping)
                }
            case .variant(let cases):
                encoder.append(CompositeValTypeOpcode.variant)
                encoder.writeUnsignedLEB128(UInt32(cases.count))
                for caseField in cases {
                    encoder.encode(caseField.name)
                    if let caseType = caseField.type {
                        encoder.append(OptionalMarker.present)
                        try encodeInlinedValueType(caseType, encoder: &encoder, typeIndexMapping: typeIndexMapping)
                    } else {
                        encoder.append(OptionalMarker.absent)
                    }
                    encoder.append(OptionalMarker.absent)  // refines: none
                }
            case .tuple(let types):
                encoder.append(CompositeValTypeOpcode.tuple)
                encoder.writeUnsignedLEB128(UInt32(types.count))
                for type in types {
                    try encodeInlinedValueType(type, encoder: &encoder, typeIndexMapping: typeIndexMapping)
                }
            case .flags(let names):
                encoder.append(CompositeValTypeOpcode.flags)
                encoder.writeUnsignedLEB128(UInt32(names.count))
                for name in names {
                    encoder.encode(name)
                }
            case .`enum`(let names):
                encoder.append(CompositeValTypeOpcode.`enum`)
                encoder.writeUnsignedLEB128(UInt32(names.count))
                for name in names {
                    encoder.encode(name)
                }
            case .option(let innerType):
                encoder.append(CompositeValTypeOpcode.option)
                try encodeInlinedValueType(innerType, encoder: &encoder, typeIndexMapping: typeIndexMapping)
            case .result(let okType, let errType):
                encoder.append(CompositeValTypeOpcode.result)
                if let okType {
                    encoder.append(OptionalMarker.present)
                    try encodeInlinedValueType(okType, encoder: &encoder, typeIndexMapping: typeIndexMapping)
                } else {
                    encoder.append(OptionalMarker.absent)
                }
                if let errType {
                    encoder.append(OptionalMarker.present)
                    try encodeInlinedValueType(errType, encoder: &encoder, typeIndexMapping: typeIndexMapping)
                } else {
                    encoder.append(OptionalMarker.absent)
                }
            case .resource(let destructor):
                encoder.append(DefinedTypeOpcode.resourceSync)
                encoder.output.append(resourceRepI32Marker)
                if let dtor = destructor {
                    encoder.append(OptionalMarker.present)
                    encoder.writeUnsignedLEB128(UInt32(dtor.rawValue))
                } else {
                    encoder.append(OptionalMarker.absent)
                }
            case .stream(let element, let end):
                // The binary `stream` type carries only the element type; the WIT-only `end`
                // channel has no binary representation. A non-nil `end` cannot be encoded.
                guard end == nil else {
                    throw WatParserError("binary `stream` type cannot encode a WIT `end` type", location: nil)
                }
                encoder.append(CompositeValTypeOpcode.stream)
                try Self.encodeOptionalElement(element, encoder: &encoder, typeIndexMapping: typeIndexMapping)
            case .future(let element):
                encoder.append(CompositeValTypeOpcode.future)
                try Self.encodeOptionalElement(element, encoder: &encoder, typeIndexMapping: typeIndexMapping)
            }
        }

        /// Encode an optional element type (`<T>? = 0x00 | 0x01 t`), shared by the `stream` and
        /// `future` value types.
        private static func encodeOptionalElement(
            _ element: ComponentValType?, encoder: inout Encoder, typeIndexMapping: [Int: Int]
        ) throws(WatParserError) {
            if let element {
                encoder.append(OptionalMarker.present)
                try encodeInlinedValueType(element, encoder: &encoder, typeIndexMapping: typeIndexMapping)
            } else {
                encoder.append(OptionalMarker.absent)
            }
        }

        private static func encodeInlinedValueType(
            _ valType: ComponentValType,
            encoder: inout Encoder,
            typeIndexMapping: [Int: Int]
        ) throws(WatParserError) {
            switch valType {
            case .primitive(let prim):
                encodePrimitiveType(prim, encoder: &encoder)
            case .index(let typeIndex):
                // Local type indices within inline type definitions may not be in
                // typeIndexMapping; they are relative indices written directly.
                // Value types use s33 encoding: primitives are negative (0x64-0x7F single bytes),
                // type indices are non-negative signed LEB128. Signed encoding ensures
                // indices >= 100 (0x64) don't collide with primitive opcodes.
                let mappedIndex = typeIndexMapping[Int(typeIndex.rawValue)] ?? Int(typeIndex.rawValue)
                encoder.writeSignedLEB128(Int64(mappedIndex))
            }
        }

        private static func encodePrimitiveType(_ prim: ComponentPrimValType, encoder: inout Encoder) {
            switch prim {
            case .bool: encoder.append(PrimitiveValTypeOpcode.bool)
            case .s8: encoder.append(PrimitiveValTypeOpcode.s8)
            case .u8: encoder.append(PrimitiveValTypeOpcode.u8)
            case .s16: encoder.append(PrimitiveValTypeOpcode.s16)
            case .u16: encoder.append(PrimitiveValTypeOpcode.u16)
            case .s32: encoder.append(PrimitiveValTypeOpcode.s32)
            case .u32: encoder.append(PrimitiveValTypeOpcode.u32)
            case .s64: encoder.append(PrimitiveValTypeOpcode.s64)
            case .u64: encoder.append(PrimitiveValTypeOpcode.u64)
            case .float32: encoder.append(PrimitiveValTypeOpcode.float32)
            case .float64: encoder.append(PrimitiveValTypeOpcode.float64)
            case .char: encoder.append(PrimitiveValTypeOpcode.char)
            case .string: encoder.append(PrimitiveValTypeOpcode.string)
            case .errorContext: encoder.append(PrimitiveValTypeOpcode.errorContext)
            }
        }

        private static func encodeComponentTypeDecls(
            _ decls: [ComponentWatParser.ComponentDecl],
            encoder: inout Encoder,
            component: ComponentWatParser.ComponentDef,
            typeIndexMapping: [Int: Int]
        ) throws(WatParserError) {
            encoder.writeUnsignedLEB128(UInt32(decls.count))
            for decl in decls {
                switch decl {
                case .coreType(let coreTypeDef):
                    encoder.append(TypeDeclTag.coreType)
                    try encodeCoreType(coreTypeDef, encoder: &encoder, component: component)
                case .type(let typeDef):
                    encoder.append(TypeDeclTag.type)
                    try encodeComponentType(typeDef, encoder: &encoder, component: component, typeIndexMapping: typeIndexMapping)
                case .alias(let aliasDecl):
                    encoder.append(TypeDeclTag.alias)
                    try encodeTypeAliasDecl(aliasDecl, encoder: &encoder)
                case .import(let externDecl):
                    encoder.append(TypeDeclTag.import)
                    encodeComponentExternName(externDecl.name, encoder: &encoder)
                    try encodeTypeExternDesc(externDecl.descriptor, encoder: &encoder, typeIndexMapping: typeIndexMapping)
                case .export(let externDecl):
                    encoder.append(TypeDeclTag.export)
                    encodeComponentExternName(externDecl.name, encoder: &encoder)
                    try encodeTypeExternDesc(externDecl.descriptor, encoder: &encoder, typeIndexMapping: typeIndexMapping)
                }
            }
        }

        private static func encodeTypeAliasDecl(
            _ aliasDecl: ComponentWatParser.TypeAliasDecl,
            encoder: inout Encoder,
            outerIndexMapping: [Int: Int] = [:]
        ) throws(WatParserError) {
            // Component Model Binary.md: alias ::= s:<sort> t:<aliastarget>
            // Sort comes FIRST, then target

            // Encode sort
            switch aliasDecl.sort {
            case .type:
                encoder.output.append(0x03)  // type sort
            case .instance:
                encoder.output.append(0x05)  // instance sort
            case .coreType:
                // core sort prefix (0x00) + core type sort (0x10)
                encoder.output.append(0x00)
                encoder.output.append(0x10)
            }

            // Encode alias target
            switch aliasDecl.target {
            case .export(let instanceIndex, let exportName):
                // Export alias: 0x00 <instance-idx> <name>
                encoder.output.append(0x00)  // export target (from component instance)
                encoder.writeUnsignedLEB128(instanceIndex)
                encoder.encode(exportName)

            case .outer(let outerCount, let typeIndex):
                // Outer alias: 0x02 <outer-count> <type-idx>
                encoder.output.append(0x02)  // outer target
                encoder.writeUnsignedLEB128(outerCount)
                // Remap the type index using the outer component's index mapping
                let mappedIndex = outerIndexMapping[Int(typeIndex)] ?? Int(typeIndex)
                encoder.writeUnsignedLEB128(UInt32(mappedIndex))
            }
        }

        /// Write a type index, resolving through typeIndexMapping if available.
        private static func writeTypeIndex(
            _ typeIndex: UInt32,
            encoder: inout Encoder,
            typeIndexMapping: [Int: Int]
        ) {
            let resolved = typeIndexMapping[Int(typeIndex)].map(UInt32.init) ?? typeIndex
            encoder.writeUnsignedLEB128(resolved)
        }

        private static func encodeTypeExternDesc(
            _ desc: ComponentWatParser.TypeExternDesc,
            encoder: inout Encoder,
            typeIndexMapping: [Int: Int]
        ) throws(WatParserError) {
            switch desc {
            case .coreModule(_, let coreTypeIndex):
                encoder.append(ExternDescKind.coreModule)
                encoder.output.append(coreModuleMarker)
                encoder.writeUnsignedLEB128(coreTypeIndex)

            case .function(_, let typeIndex):
                encoder.append(ExternDescKind.function)
                if let typeIndex = typeIndex {
                    writeTypeIndex(typeIndex, encoder: &encoder, typeIndexMapping: typeIndexMapping)
                } else {
                    encoder.writeUnsignedLEB128(UInt32(0))  // placeholder
                }

            case .type(_, let bound):
                encoder.append(ExternDescKind.type)
                encodeTypeBound(bound, encoder: &encoder, typeIndexMapping: typeIndexMapping)

            case .instance(_, let typeIndex):
                encoder.append(ExternDescKind.instance)
                if let typeIndex = typeIndex {
                    writeTypeIndex(typeIndex, encoder: &encoder, typeIndexMapping: typeIndexMapping)
                } else {
                    encoder.writeUnsignedLEB128(UInt32(0))  // placeholder
                }

            case .value(_, let typeIndex):
                encoder.append(ExternDescKind.value)
                if let typeIndex = typeIndex {
                    writeTypeIndex(typeIndex, encoder: &encoder, typeIndexMapping: typeIndexMapping)
                } else {
                    encoder.writeUnsignedLEB128(UInt32(0))  // placeholder
                }

            case .component(_, let typeIndex):
                encoder.append(ExternDescKind.component)
                if let typeIndex = typeIndex {
                    writeTypeIndex(typeIndex, encoder: &encoder, typeIndexMapping: typeIndexMapping)
                } else {
                    encoder.writeUnsignedLEB128(UInt32(0))  // placeholder
                }
            }
        }

        private static func encodeTypeBound(
            _ bound: ComponentWatParser.TypeBound,
            encoder: inout Encoder,
            typeIndexMapping: [Int: Int]
        ) {
            switch bound {
            case .subResource:
                encoder.append(TypeBoundOpcode.subResource)
            case .eq(let typeIndex):
                encoder.append(TypeBoundOpcode.eq)
                writeTypeIndex(typeIndex, encoder: &encoder, typeIndexMapping: typeIndexMapping)
            }
        }

        private static func encodeComponentInstance(
            _ instanceDef: ComponentWatParser.ComponentInstanceDef,
            encoder: inout Encoder,
            component: ComponentWatParser.ComponentDef,
            typeIndexMapping: [Int: Int]
        ) throws(WatParserError) {
            if instanceDef.componentRef == nil {
                // Value-based instance: (instance (export "name" (<sort> $ref)) ...)
                encoder.append(InstanceForm.inlineExports)
                encoder.writeUnsignedLEB128(UInt32(instanceDef.exports.count))
                for export in instanceDef.exports {
                    encodeComponentExternName(export.name, encoder: &encoder)
                    switch export.sort {
                    case .type:
                        encoder.append(ComponentSortOpcode.type)
                        let typeIndex = try component.resolveTypeIndex(use: export.ref)
                        guard let mappedIndex = typeIndexMapping[typeIndex] else {
                            throw WatParserError("Unmapped type index \(typeIndex) in export arg type", location: nil)
                        }
                        encoder.writeUnsignedLEB128(UInt32(mappedIndex))
                    case .func:
                        encoder.append(ComponentSortOpcode.function)
                        let funcIndex = try component.componentFunctions.resolveIndex(use: export.ref)
                        encoder.writeUnsignedLEB128(UInt32(funcIndex))
                    case .instance:
                        encoder.append(ComponentSortOpcode.instance)
                        let instanceIndex = try component.componentInstancesMap.resolveIndex(use: export.ref)
                        encoder.writeUnsignedLEB128(UInt32(instanceIndex))
                    case .component:
                        encoder.append(ComponentSortOpcode.component)
                        let componentIndex = try component.componentsMap.resolveIndex(use: export.ref)
                        encoder.writeUnsignedLEB128(UInt32(componentIndex))
                    case .module:
                        encoder.append(ComponentSortOpcode.core)
                        encoder.append(CoreSortOpcode.module)
                        let moduleIndex = try component.coreModulesMap.resolveIndex(use: export.ref)
                        encoder.writeUnsignedLEB128(UInt32(moduleIndex))
                    }
                }
                return
            }

            encoder.append(InstanceForm.instantiate)

            if let componentRef = instanceDef.componentRef {
                let componentIndex = try component.componentsMap.resolveIndex(use: componentRef)
                encoder.writeUnsignedLEB128(UInt32(componentIndex))
            } else {
                encoder.writeUnsignedLEB128(UInt32(0))
            }

            encoder.writeUnsignedLEB128(UInt32(instanceDef.arguments.count))
            for arg in instanceDef.arguments {
                encoder.encode(arg.name)
                switch arg.kind {
                case .instance(let instanceRef):
                    encoder.append(ComponentSortOpcode.instance)
                    let instanceIndex = try component.componentInstancesMap.resolveIndex(use: instanceRef)
                    encoder.writeUnsignedLEB128(UInt32(instanceIndex))
                case .type(let typeRef):
                    encoder.append(ComponentSortOpcode.type)
                    let typeIndex = try component.resolveTypeIndex(use: typeRef)
                    guard let mappedIndex = typeIndexMapping[typeIndex] else {
                        throw WatParserError("Unmapped type index \(typeIndex) in alias target", location: nil)
                    }
                    encoder.writeUnsignedLEB128(UInt32(mappedIndex))
                case .component(let componentRef):
                    encoder.output.append(0x04)  // component
                    let componentIndex = try component.componentsMap.resolveIndex(use: componentRef)
                    encoder.writeUnsignedLEB128(UInt32(componentIndex))
                case .funcRef(let funcRef):
                    encoder.append(ComponentSortOpcode.function)
                    let funcIndex = try component.componentFunctions.resolveIndex(use: funcRef)
                    encoder.writeUnsignedLEB128(UInt32(funcIndex))
                case .coreModule(let moduleRef):
                    encoder.append(ComponentSortOpcode.core)
                    encoder.append(CoreSortOpcode.module)
                    let moduleIndex = try component.coreModulesMap.resolveIndex(use: moduleRef)
                    encoder.writeUnsignedLEB128(UInt32(moduleIndex))
                }
            }
        }

        private static func encodeAlias(
            _ aliasDef: ComponentWatParser.ComponentAlias,
            encoder: inout Encoder,
            component: ComponentWatParser.ComponentDef
        ) throws(WatParserError) {
            // Encode sort: core sorts use 0x00 prefix + core sub-sort, component sorts use single byte
            if aliasDef.sort.requiresCorePrefix {
                encoder.output.append(0x00)  // core sort prefix
            }
            encoder.output.append(aliasDef.sort.sortOpcode)

            switch aliasDef.target {
            case .coreExport(let instanceIndex, let exportName):
                encoder.output.append(0x01)  // core export target
                let index = try component.coreInstancesMap.resolveIndex(use: instanceIndex)
                encoder.writeUnsignedLEB128(UInt32(index))
                encoder.encode(exportName)

            case .componentExport(let instanceIndex, let exportName):
                encoder.output.append(0x00)  // component export target
                let index = try component.componentInstancesMap.resolveIndex(use: instanceIndex)
                encoder.writeUnsignedLEB128(UInt32(index))
                encoder.encode(exportName)

            case .outer(let outerCount, let targetIndex):
                encoder.output.append(0x02)  // outer target
                encoder.writeUnsignedLEB128(outerCount)
                encoder.writeUnsignedLEB128(targetIndex)
            }
        }

        private static func encodeCanon(
            _ canonDef: ComponentWatParser.CanonDef,
            encoder: inout Encoder,
            component: ComponentWatParser.ComponentDef,
            typeIndexMapping: [Int: Int]
        ) throws(WatParserError) {
            switch canonDef.kind {
            case .lift(let funcIndex):
                encoder.append(CanonOpcode.lift)
                encoder.append(CoreSortOpcode.function)

                // Encode the core function index based on the reference form
                switch funcIndex {
                case .direct(let indexOrId):
                    // Direct core function reference: resolve from coreFunctionsMap.
                    let resolvedIndex = try component.coreFunctionsMap.resolveIndex(use: indexOrId)
                    encoder.writeUnsignedLEB128(UInt32(resolvedIndex))

                case .export:
                    // Should have been desugared to .direct during parsing
                    throw WatParserError("Canon lift core function reference should have been desugared to direct index", location: nil)
                }

                try encodeCanonOptions(canonDef.options, encoder: &encoder, component: component)
                // Emit the type index
                if let liftTypeIndex = canonDef.liftTypeIndex {
                    guard let mappedIndex = typeIndexMapping[liftTypeIndex] else {
                        throw WatParserError("Unmapped type index \(liftTypeIndex) in canon lift", location: nil)
                    }
                    encoder.writeUnsignedLEB128(UInt32(mappedIndex))
                } else {
                    encoder.writeUnsignedLEB128(UInt32(0))  // Default to type 0
                }

            case .lower(let componentFuncIndex):
                encoder.append(CanonOpcode.lower)
                encoder.append(CoreSortOpcode.function)
                encoder.writeUnsignedLEB128(componentFuncIndex.rawValue)
                try encodeCanonOptions(canonDef.options, encoder: &encoder, component: component)

            case .resourceNew(let typeRef):
                encoder.append(CanonOpcode.resourceNew)
                let typeIndex = try component.resolveTypeIndex(use: typeRef)
                guard let mappedIndex = typeIndexMapping[typeIndex] else {
                    throw WatParserError("Unmapped type index \(typeIndex) in canon resource.new", location: nil)
                }
                encoder.writeUnsignedLEB128(UInt32(mappedIndex))

            case .resourceDrop(let typeRef):
                encoder.append(CanonOpcode.resourceDrop)
                let typeIndex = try component.resolveTypeIndex(use: typeRef)
                guard let mappedIndex = typeIndexMapping[typeIndex] else {
                    throw WatParserError("Unmapped type index \(typeIndex) in canon resource.drop", location: nil)
                }
                encoder.writeUnsignedLEB128(UInt32(mappedIndex))

            case .resourceRep(let typeRef):
                encoder.append(CanonOpcode.resourceRep)
                let typeIndex = try component.resolveTypeIndex(use: typeRef)
                guard let mappedIndex = typeIndexMapping[typeIndex] else {
                    throw WatParserError("Unmapped type index \(typeIndex) in canon resource.rep", location: nil)
                }
                encoder.writeUnsignedLEB128(UInt32(mappedIndex))

            case .asyncBuiltin(let opcode, let immediate):
                encoder.append(opcode)
                try encodeAsyncImmediate(
                    immediate, encoder: &encoder, component: component, typeIndexMapping: typeIndexMapping)
            }
        }

        private static func encodeCanonOptions(
            _ options: [ComponentWatParser.CanonDef.Option],
            encoder: inout Encoder,
            component: ComponentWatParser.ComponentDef
        ) throws(WatParserError) {
            encoder.writeUnsignedLEB128(UInt32(options.count))
            for option in options {
                switch option {
                case .stringEncoding(let encoding):
                    switch encoding {
                    case .utf8:
                        encoder.append(CanonOptionTag.stringEncodingUtf8)
                    case .utf16:
                        encoder.append(CanonOptionTag.stringEncodingUtf16)
                    case .latin1UTF16:
                        encoder.append(CanonOptionTag.stringEncodingLatin1Utf16)
                    }
                case .memory:
                    fatalError("memory option should have been desugared during parsing")
                case .memoryIndex(let index):
                    encoder.append(CanonOptionTag.memory)
                    encoder.writeUnsignedLEB128(index)
                case .realloc(let funcIndex):
                    encoder.append(CanonOptionTag.realloc)
                    switch funcIndex {
                    case .direct(let indexOrId):
                        let idx = try component.coreFunctionsMap.resolveIndex(use: indexOrId)
                        encoder.writeUnsignedLEB128(UInt32(idx))
                    case .export:
                        fatalError("realloc option should have been desugared during parsing")
                    }
                case .postReturn(let funcIndex):
                    encoder.append(CanonOptionTag.postReturn)
                    switch funcIndex {
                    case .direct(let indexOrId):
                        let idx = try component.coreFunctionsMap.resolveIndex(use: indexOrId)
                        encoder.writeUnsignedLEB128(UInt32(idx))
                    case .export:
                        fatalError("postReturn option should have been desugared during parsing")
                    }
                case .async:
                    encoder.append(CanonOptionTag.async)
                case .callback(let funcIndex):
                    encoder.append(CanonOptionTag.callback)
                    switch funcIndex {
                    case .direct(let indexOrId):
                        let idx = try component.coreFunctionsMap.resolveIndex(use: indexOrId)
                        encoder.writeUnsignedLEB128(UInt32(idx))
                    case .export:
                        fatalError("callback option should have been desugared during parsing")
                    }
                }
            }
        }

        /// Encode the immediate bytes of an async canon built-in, the inverse of
        /// `ComponentParser.parseAsyncCanonicalImmediates`. Type refs are resolved here
        /// (like `resource.new`); memory refs were already desugared at parse time.
        private static func encodeAsyncImmediate(
            _ immediate: ComponentWatParser.CanonDef.AsyncImmediate,
            encoder: inout Encoder,
            component: ComponentWatParser.ComponentDef,
            typeIndexMapping: [Int: Int]
        ) throws(WatParserError) {
            switch immediate {
            case .none:
                break

            case .type(let typeRef):
                try encodeMappedTypeIndex(typeRef, encoder: &encoder, component: component, typeIndexMapping: typeIndexMapping)

            case .typeWithOptions(let typeRef, let options):
                try encodeMappedTypeIndex(typeRef, encoder: &encoder, component: component, typeIndexMapping: typeIndexMapping)
                try encodeCanonOptions(options, encoder: &encoder, component: component)

            case .typeWithAsyncFlag(let typeRef, let isAsync):
                try encodeMappedTypeIndex(typeRef, encoder: &encoder, component: component, typeIndexMapping: typeIndexMapping)
                encoder.output.append(isAsync ? 0x01 : 0x00)

            case .asyncFlag(let isAsync):
                encoder.output.append(isAsync ? 0x01 : 0x00)

            case .cancellableFlag(let cancellable):
                encoder.output.append(cancellable ? 0x01 : 0x00)

            case .cancellableWithMemory(let cancellable, let memoryIndex):
                encoder.output.append(cancellable ? 0x01 : 0x00)
                encoder.writeUnsignedLEB128(memoryIndex)

            case .resultListWithOptions(let result, let options):
                if let result {
                    encoder.output.append(0x00)  // single anonymous result
                    try encodeValueType(result, encoder: &encoder, component: component, typeIndexMapping: typeIndexMapping)
                } else {
                    encoder.output.append(0x01)  // named results form
                    encoder.output.append(0x00)  // 0 named results = no result
                }
                try encodeCanonOptions(options, encoder: &encoder, component: component)

            case .context(let valueType, let slot):
                switch valueType {
                case .i32: encoder.output.append(0x7f)
                case .i64: encoder.output.append(0x7e)
                }
                encoder.writeUnsignedLEB128(slot)

            case .typeWithTable(let typeRef, let tableRef):
                // thread.new-indirect references a CORE function type (e.g. `(core type $ft ...)`)
                // and a core table. Both live in core index spaces, not the component type space.
                let coreTypeIndex = try component.coreTypesMap.resolveIndex(use: typeRef)
                encoder.writeUnsignedLEB128(UInt32(coreTypeIndex))
                let tableIndex = try component.coreTablesMap.resolveIndex(use: tableRef)
                encoder.writeUnsignedLEB128(UInt32(tableIndex))
            }
        }

        /// Resolve a component type reference and emit its mapped binary type index,
        /// as used by `resource.new` and the async canon ops.
        private static func encodeMappedTypeIndex(
            _ typeRef: Parser.IndexOrId,
            encoder: inout Encoder,
            component: ComponentWatParser.ComponentDef,
            typeIndexMapping: [Int: Int]
        ) throws(WatParserError) {
            let typeIndex = try component.resolveTypeIndex(use: typeRef)
            guard let mappedIndex = typeIndexMapping[typeIndex] else {
                throw WatParserError("Unmapped type index \(typeIndex) in async canon op", location: nil)
            }
            encoder.writeUnsignedLEB128(UInt32(mappedIndex))
        }

        private static func encodeStart(
            _ startDef: ComponentWatParser.StartDef, encoder: inout Encoder,
            component: ComponentWatParser.ComponentDef
        ) throws(WatParserError) {
            // start ::= f:<funcidx> arg*:vec(<valueidx>) r:<u32>
            let funcIndex = try component.componentFunctions.resolveIndex(use: startDef.funcRef)
            encoder.writeUnsignedLEB128(UInt32(funcIndex))
            encoder.writeUnsignedLEB128(UInt32(startDef.args.count))
            for argRef in startDef.args {
                switch argRef {
                case .index(let idx, _):
                    encoder.writeUnsignedLEB128(idx)
                case .id:
                    let idx = try component.valuesMap.resolveIndex(use: argRef)
                    encoder.writeUnsignedLEB128(UInt32(idx))
                }
            }
            encoder.writeUnsignedLEB128(UInt32(startDef.resultCount))
        }

        private static func encodeComponentExternName(
            _ name: ComponentWatParser.ComponentExternName,
            encoder: inout Encoder
        ) {
            // Per Binary.md: importname'/exportname' uses 0x00 for plain names.
            // The (interface "...") WAT syntax is just textual sugar; the name
            // string itself contains the interface path. Both encode as 0x00.
            encoder.output.append(0x00)
            encoder.encode(name.string)
        }

        private static func encodeImport(
            _ importDef: ComponentWatParser.ImportDef,
            encoder: inout Encoder,
            component: ComponentWatParser.ComponentDef,
            typeIndexMapping: [Int: Int]
        ) throws(WatParserError) {
            // Import name
            encodeComponentExternName(importDef.importName, encoder: &encoder)

            // Descriptor
            try encodeExternDesc(importDef.descriptor, encoder: &encoder, component: component, typeIndexMapping: typeIndexMapping)
        }

        private static func encodeExport(
            _ exportDef: ComponentWatParser.ExportDef,
            encoder: inout Encoder,
            component: ComponentWatParser.ComponentDef,
            typeIndexMapping: [Int: Int]
        ) throws(WatParserError) {
            // Export name
            encodeComponentExternName(exportDef.exportName, encoder: &encoder)

            // Helper to encode the type annotation (0x00 for none, 0x01 + sort + index for present)
            func encodeTypeAnnotation() throws(WatParserError) {
                if let annotation = exportDef.typeAnnotation {
                    guard let mappedIndex = typeIndexMapping[annotation.typeIndex] else {
                        throw WatParserError("Unmapped type index \(annotation.typeIndex) in export type annotation", location: nil)
                    }
                    encoder.output.append(0x01)  // externdesc present
                    encoder.output.append(annotation.sort.rawValue)  // externdesc sort
                    encoder.writeUnsignedLEB128(UInt32(mappedIndex))
                } else {
                    encoder.output.append(0x00)  // no externdesc
                }
            }

            // Descriptor kind
            switch exportDef.descriptor {
            case .module(let moduleRef):
                encoder.output.append(0x00)  // core prefix
                encoder.output.append(0x11)  // core module sort
                let index = try component.coreModulesMap.resolveIndex(use: moduleRef)
                encoder.writeUnsignedLEB128(UInt32(index))
                try encodeTypeAnnotation()

            case .coreModule(let coreTypeRef):
                encoder.output.append(0x00)  // core prefix
                encoder.output.append(0x11)  // core module sort
                let index: Int
                switch coreTypeRef {
                case .index(let idx, _): index = Int(idx)
                case .id: index = try component.coreTypesMap.resolveIndex(use: coreTypeRef)
                }
                encoder.writeUnsignedLEB128(UInt32(index))
                try encodeTypeAnnotation()

            case .function(let funcIndex):
                encoder.output.append(0x01)  // func
                encoder.writeUnsignedLEB128(UInt32(funcIndex.rawValue))
                try encodeTypeAnnotation()

            case .functionFromInstance:
                // Should have been desugared during parsing
                throw WatParserError("functionFromInstance should have been desugared to function index", location: nil)

            case .value(let valueRef):
                encoder.output.append(0x02)  // value
                let index = try component.resolveTypeIndex(use: valueRef)
                guard let mappedIndex = typeIndexMapping[index] else {
                    throw WatParserError("Unmapped type index \(index) in export arg value", location: nil)
                }
                encoder.writeUnsignedLEB128(UInt32(mappedIndex))
                try encodeTypeAnnotation()

            case .valueType(let valType):
                // value import: 0x02 <valtype> (gated)
                encoder.output.append(0x02)
                try encodeValueType(valType, encoder: &encoder, component: component, typeIndexMapping: typeIndexMapping)
                try encodeTypeAnnotation()

            case .type(let typeRef, _):
                encoder.append(ComponentSortOpcode.type)
                let index = try component.resolveTypeIndex(use: typeRef)
                guard let mappedIndex = typeIndexMapping[index] else {
                    throw WatParserError("Unmapped type index \(index) in export arg type", location: nil)
                }
                encoder.writeUnsignedLEB128(UInt32(mappedIndex))
                try encodeTypeAnnotation()

            case .component(let componentRef):
                encoder.output.append(0x04)  // component
                let index = try component.componentsMap.resolveIndex(use: componentRef)
                encoder.writeUnsignedLEB128(UInt32(index))
                try encodeTypeAnnotation()

            case .instance(let instanceRef):
                encoder.output.append(0x05)  // instance
                let index = try component.componentInstancesMap.resolveIndex(use: instanceRef)
                encoder.writeUnsignedLEB128(UInt32(index))
                try encodeTypeAnnotation()
            }
        }

        private static func encodeExternDesc(
            _ desc: ComponentWatParser.ExternDesc,
            encoder: inout Encoder,
            component: ComponentWatParser.ComponentDef,
            typeIndexMapping: [Int: Int]
        ) throws(WatParserError) {
            switch desc {
            case .module(let moduleRef):
                encoder.output.append(0x00)  // module
                let index = try component.coreModulesMap.resolveIndex(use: moduleRef)
                encoder.writeUnsignedLEB128(UInt32(index))

            case .coreModule(let coreTypeRef):
                // Core module import with type reference
                encoder.output.append(0x00)  // core prefix
                encoder.output.append(0x11)  // core module sort
                let index: Int
                switch coreTypeRef {
                case .index(let idx, _): index = Int(idx)
                case .id: index = try component.coreTypesMap.resolveIndex(use: coreTypeRef)
                }
                encoder.writeUnsignedLEB128(UInt32(index))

            case .function(let funcIndex):
                encoder.output.append(0x01)  // func
                // Imports encode the function's type index, not the function index.
                // Binary format: externdesc ::= 0x01 i:<typeidx>
                let funcDef = component.componentFunctions[Int(funcIndex.rawValue)]
                guard let funcType = funcDef.type else {
                    throw WatParserError("Function \(funcIndex.rawValue) has no known type in extern desc function", location: nil)
                }
                let typeIndex = Int(funcType.rawValue)
                guard let mappedTypeIndex = typeIndexMapping[typeIndex] else {
                    throw WatParserError("Unmapped type index \(typeIndex) in extern desc function", location: nil)
                }
                encoder.writeUnsignedLEB128(UInt32(mappedTypeIndex))

            case .functionFromInstance:
                // Should have been desugared to function index
                encoder.output.append(0x01)  // func
                encoder.writeUnsignedLEB128(UInt32(0))

            case .value(let valueRef):
                encoder.output.append(0x02)  // value
                let index = try component.resolveTypeIndex(use: valueRef)
                guard let mappedIndex = typeIndexMapping[index] else {
                    throw WatParserError("Unmapped type index \(index) in extern desc value", location: nil)
                }
                encoder.writeUnsignedLEB128(UInt32(mappedIndex))

            case .valueType(let valType):
                // value import: 0x02 <valtype> (gated)
                encoder.output.append(0x02)
                try encodeValueType(valType, encoder: &encoder, component: component, typeIndexMapping: typeIndexMapping)

            case .type(let typeRef, let bound):
                encoder.append(ExternDescKind.type)
                if let bound {
                    encodeTypeBound(bound, encoder: &encoder, typeIndexMapping: typeIndexMapping)
                } else {
                    let index = try component.resolveTypeIndex(use: typeRef)
                    guard let mappedIndex = typeIndexMapping[index] else {
                        throw WatParserError("Unmapped type index \(index) in extern desc type", location: nil)
                    }
                    encoder.writeUnsignedLEB128(UInt32(mappedIndex))
                }

            case .component(let componentRef):
                encoder.output.append(0x04)  // component
                let index = try component.resolveTypeIndex(use: componentRef)
                guard let mappedIndex = typeIndexMapping[index] else {
                    throw WatParserError("Unmapped type index \(index) in extern desc component", location: nil)
                }
                encoder.writeUnsignedLEB128(UInt32(mappedIndex))

            case .instance(let instanceRef):
                encoder.output.append(0x05)  // instance
                let index = try component.resolveTypeIndex(use: instanceRef)
                guard let mappedIndex = typeIndexMapping[index] else {
                    throw WatParserError("Unmapped type index \(index) in extern desc instance", location: nil)
                }
                encoder.writeUnsignedLEB128(UInt32(mappedIndex))
            }
        }

        // MARK: - Name Section

        private mutating func encodeNameSection(
            _ component: ComponentWatParser.ComponentDef,
            typeIndexMapping: [Int: Int]
        ) throws(WatParserError) {
            // Collect names for uniform sort name map blocks
            let coreFuncNames = component.coreFunctionsMap.enumerated().compactMap { i, decl -> (Int, String)? in
                guard let name = decl.id else { return nil }
                return (i, name.value)
            }
            let moduleNames = component.coreModulesMap.enumerated().compactMap { i, decl -> (Int, String)? in
                guard let name = decl.id else { return nil }
                return (i, name.value)
            }
            let coreInstanceNames = component.coreInstancesMap.enumerated().compactMap { i, decl -> (Int, String)? in
                guard let name = decl.id else { return nil }
                return (i, name.value)
            }
            let coreMemoryNames = component.coreMemoriesMap.enumerated().compactMap { i, decl -> (Int, String)? in
                guard let name = decl.id else { return nil }
                return (i, name.value)
            }
            let coreTableNames = component.coreTablesMap.enumerated().compactMap { i, decl -> (Int, String)? in
                guard let name = decl.id else { return nil }
                return (i, name.value)
            }
            let coreGlobalNames = component.coreGlobalsMap.enumerated().compactMap { i, decl -> (Int, String)? in
                guard let name = decl.id else { return nil }
                return (i, name.value)
            }
            let coreTagNames = component.coreTagsMap.enumerated().compactMap { i, decl -> (Int, String)? in
                guard let name = decl.id else { return nil }
                return (i, name.value)
            }
            let coreTypeNames = component.coreTypesMap.declarations.enumerated().compactMap { i, decl -> (Int, String)? in
                guard let name = decl.id else { return nil }
                return (i, name.value)
            }
            let componentFuncNames = component.componentFunctions.decls.enumerated().compactMap { i, decl -> (Int, String)? in
                guard let name = decl.id else { return nil }
                return (i, name.value)
            }
            let componentNames = component.componentsMap.enumerated().compactMap { i, decl -> (Int, String)? in
                guard let name = decl.id else { return nil }
                return (i, name.value)
            }
            let componentInstanceNames = component.componentInstancesMap.enumerated().compactMap { i, decl -> (Int, String)? in
                guard let name = decl.id else { return nil }
                return (i, name.value)
            }

            let hasComponentTypeNames = component.typeIndexSpace.hasNames

            guard
                component.id != nil
                    || !coreFuncNames.isEmpty || !moduleNames.isEmpty || !coreInstanceNames.isEmpty
                    || !coreMemoryNames.isEmpty || !coreTableNames.isEmpty || !coreGlobalNames.isEmpty
                    || !coreTagNames.isEmpty
                    || !coreTypeNames.isEmpty || !componentFuncNames.isEmpty || hasComponentTypeNames
                    || !componentNames.isEmpty || !componentInstanceNames.isEmpty
            else { return }

            underlying.section(id: 0) { encoder in
                encoder.encode("component-name")

                // Subsection 0: Component name
                if let componentName = component.id {
                    encoder.section(id: 0) { encoder in
                        encoder.encode(String(componentName.value.dropFirst()))
                    }
                }

                // Subsection 1: Sort name maps
                encoder.encodeSortNameMap(
                    sortBytes: [ComponentSortOpcode.core.rawValue, CoreSortOpcode.function.rawValue],
                    names: coreFuncNames
                )
                encoder.encodeSortNameMap(
                    sortBytes: [ComponentSortOpcode.core.rawValue, CoreSortOpcode.table.rawValue],
                    names: coreTableNames
                )
                encoder.encodeSortNameMap(
                    sortBytes: [ComponentSortOpcode.core.rawValue, CoreSortOpcode.memory.rawValue],
                    names: coreMemoryNames
                )
                encoder.encodeSortNameMap(
                    sortBytes: [ComponentSortOpcode.core.rawValue, CoreSortOpcode.global.rawValue],
                    names: coreGlobalNames
                )
                encoder.encodeSortNameMap(
                    sortBytes: [ComponentSortOpcode.core.rawValue, CoreSortOpcode.tag.rawValue],
                    names: coreTagNames
                )
                encoder.encodeSortNameMap(
                    sortBytes: [ComponentSortOpcode.core.rawValue, CoreSortOpcode.type.rawValue],
                    names: coreTypeNames
                )
                encoder.encodeSortNameMap(
                    sortBytes: [ComponentSortOpcode.core.rawValue, CoreSortOpcode.module.rawValue],
                    names: moduleNames
                )
                encoder.encodeSortNameMap(
                    sortBytes: [ComponentSortOpcode.core.rawValue, CoreSortOpcode.instance.rawValue],
                    names: coreInstanceNames
                )
                encoder.encodeSortNameMap(
                    sortBytes: [ComponentSortOpcode.function.rawValue],
                    names: componentFuncNames
                )

                // Component type names: single enumeration over typeIndexSpace
                if hasComponentTypeNames {
                    encoder.section(id: 1) { encoder in
                        encoder.output.append(ComponentSortOpcode.type.rawValue)

                        var typeNames = component.typeIndexSpace.entries.enumerated().compactMap { i, entry -> (Int, String)? in
                            guard let name = entry.name else { return nil }
                            guard let mappedIndex = typeIndexMapping[i] else { return nil }
                            return (mappedIndex, name.value)
                        }

                        typeNames.sort(by: { $0.0 < $1.0 })

                        encoder.encodeVector(typeNames) { entry, encoder in
                            let (index, name) = entry
                            encoder.writeUnsignedLEB128(UInt(index))
                            encoder.encode(String(name.dropFirst()))
                        }
                    }
                }

                encoder.encodeSortNameMap(
                    sortBytes: [ComponentSortOpcode.component.rawValue],
                    names: componentNames
                )
                encoder.encodeSortNameMap(
                    sortBytes: [ComponentSortOpcode.instance.rawValue],
                    names: componentInstanceNames
                )
            }
        }
    }

    extension Encoder {
        /// Encode a sort name map subsection (subsection id 1) for the component name section.
        /// Each block emits sort bytes followed by a vector of (index, name) pairs.
        fileprivate mutating func encodeSortNameMap(
            sortBytes: [UInt8],
            names: [(Int, String)]
        ) {
            guard !names.isEmpty else { return }
            section(id: 1) { encoder in
                for byte in sortBytes {
                    encoder.output.append(byte)
                }
                encoder.encodeVector(names) { entry, encoder in
                    let (index, name) = entry
                    encoder.writeUnsignedLEB128(UInt(index))
                    encoder.encode(String(name.dropFirst()))
                }
            }
        }
    }

#endif
