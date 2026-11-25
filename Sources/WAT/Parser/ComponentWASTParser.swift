#if ComponentModel

    import ComponentModel
    import WasmParser
    import WasmTypes

    // MARK: - Component WAST Directive Types

    /// A directive in a Component WAST script.
    /// Mirrors WASTDirective but for Component Model.
    package enum ComponentWASTDirective {
        /// A component definition
        case component(ComponentDirective)

        /// A component definition template (optionally named for reuse)
        /// Syntax: (component definition $name? ...body...)
        case componentDefinition(id: String?, component: ComponentDirective)

        /// Instantiate a previously defined component template
        /// Syntax: (component instance $id $componentRef)
        case componentInstance(id: String?, componentRef: String)

        /// Assert that a component is invalid (fails validation)
        /// Example: (assert_invalid (component ...) "error message")
        case assertInvalid(component: ComponentDirective, message: String)

        /// Assert that a component is malformed (fails parsing)
        /// Example: (assert_malformed (component quote "...") "error message")
        case assertMalformed(component: ComponentDirective, message: String)

        /// Assert that a component fails during linking/instantiation
        /// Example: (assert_unlinkable (component ...) "error message")
        case assertUnlinkable(component: ComponentDirective, message: String)

        /// Assert that invoking a function returns expected values
        /// Example: (assert_return (invoke "func" (u32.const 1)) (bool.const true))
        case assertReturn(execute: ComponentWASTExecute, results: [ComponentValue])

        /// Assert that invoking a function traps
        /// Example: (assert_trap (invoke "func") "trap message")
        case assertTrap(execute: ComponentWASTExecute, message: String)

        /// Register a component with a name for later use
        /// Example: (register "name" $id)
        case register(name: String, componentId: String?)

        /// Invoke a component function
        /// Example: (invoke "func" (u32.const 42))
        case invoke(ComponentWASTInvoke)
    }

    /// A component representation in "(component ...)" form in WAST.
    package struct ComponentDirective {
        /// The source of the component
        package let source: ComponentSource
        /// The name of the component specified in $id form
        package let id: String?
        /// The location of the component in the source
        package let location: Location
    }

    /// The source of a component in WAST.
    package enum ComponentSource {
        /// A parsed Component WAT
        case text(ComponentWatParser.ComponentDef)
        /// A text form of Component WAT (quoted strings)
        case quote([UInt8])
        /// A binary form of WebAssembly component
        case binary([UInt8])
    }

    /// Component-level execution in WAST.
    package enum ComponentWASTExecute {
        /// Invoke a component function
        case invoke(ComponentWASTInvoke)
        /// Get a component export value
        case get(component: String?, exportName: String)
        /// Instantiate a component (used in assert_trap to test instantiation failures)
        case component(ComponentDirective)
    }

    /// A component function invocation in WAST.
    package struct ComponentWASTInvoke {
        /// Optional component name (if not specified, use current component)
        package let component: String?
        /// The function name to invoke
        package let name: String
        /// Arguments to pass to the function (reuses ComponentValue from ComponentModel)
        package let args: [ComponentValue]
    }

    // MARK: - ComponentWASTParser

    /// A parser for Component WAST format.
    /// Similar to WASTParser but for Component Model scripts.
    package struct ComponentWASTParser {
        var parser: Parser
        let features: WasmFeatureSet

        package init(_ input: String, features: WasmFeatureSet) {
            self.parser = Parser(input)
            self.features = features
        }

        // MARK: - Main Entry Point

        /// Saved parser state before the current directive, for error recovery
        private var savedParserBeforeDirective: Parser?

        /// Parse the next directive in the Component WAST script.
        package mutating func nextDirective() throws(WatParserError) -> ComponentWASTDirective? {
            guard (try parser.peek(.leftParen)) != nil else { return nil }
            savedParserBeforeDirective = parser  // Save state before consuming opening paren
            try parser.consume()
            guard try ComponentWASTDirective.peek(wastParser: self) else {
                if try peekComponentField() {
                    // Parse inline component, which doesn't include surrounding (component)
                    let location = savedParserBeforeDirective!.lexer.location()
                    let componentParser = ComponentWatParser(features: features)
                    var parserCopy = savedParserBeforeDirective!
                    let componentDef = try componentParser.parse(&parserCopy)
                    parser = parserCopy
                    savedParserBeforeDirective = nil
                    // Note: ComponentWatParser.parse() already consumes the closing )
                    return .component(
                        ComponentDirective(
                            source: .text(componentDef),
                            id: nil,
                            location: location
                        ))
                }
                throw WatParserError("unexpected component wast directive token", location: parser.lexer.location())
            }
            let directive = try ComponentWASTDirective.parse(wastParser: &self)
            savedParserBeforeDirective = nil
            return directive
        }

        /// Skip the current directive after an error.
        /// Call this after catching an error from `nextDirective()`.
        /// This restores to before the directive and skips the entire paren block.
        package mutating func skipCurrentDirective() {
            // Restore to the saved position (before the directive's opening paren)
            if let saved = savedParserBeforeDirective {
                parser = saved
                savedParserBeforeDirective = nil
            }
            // Now skip the entire paren block
            guard (try? parser.peek(.leftParen)) != nil else { return }
            _ = try? parser.consume()  // consume the opening (
            var depth = 1
            while depth > 0 {
                guard let token = try? parser.consume() else { return }
                switch token.kind {
                case .leftParen:
                    depth += 1
                case .rightParen:
                    depth -= 1
                default:
                    break
                }
            }
        }

        // MARK: - Helper Methods

        private func peekComponentField() throws(WatParserError) -> Bool {
            guard let keyword = try parser.peekKeyword() else { return false }
            switch keyword {
            case "core", "type", "func", "import", "export", "instance", "alias", "canon":
                return true
            default:
                return false
            }
        }

        mutating func parens<T>(_ body: (inout ComponentWASTParser) throws(WatParserError) -> T) throws(WatParserError) -> T {
            try parser.expect(.leftParen)
            let result = try body(&self)
            return result
        }

        // MARK: - Component Value Parsing

        /// Parse zero or more component const values (e.g. `(u32.const 42) (bool.const true)`).
        mutating func parseConstValues() throws(WatParserError) -> [ComponentValue] {
            var values: [ComponentValue] = []
            while try parseComponentConstValue(&values) {}
            return values
        }

        // MARK: - Component Const Value Parsing

        /// Parse a single component const value instruction.
        /// Returns true if a value was parsed.
        private mutating func parseComponentConstValue(_ values: inout [ComponentValue]) throws(WatParserError) -> Bool {
            // Check if we're at a left paren
            guard (try parser.peek(.leftParen)) != nil else { return false }

            // Peek at the keyword after the paren
            var lookahead = parser
            try lookahead.consume()  // consume left paren
            guard let keyword = try lookahead.peekKeyword() else { return false }

            // Parse based on keyword
            switch keyword {
            // Unsigned integers
            case "u8.const":
                try parser.expect(.leftParen)
                try parser.expectKeyword("u8.const")
                let value = try parser.expectUnsignedInt(UInt8.self)
                values.append(.u8(value))
                try parser.expect(.rightParen)
                return true

            case "u16.const":
                try parser.expect(.leftParen)
                try parser.expectKeyword("u16.const")
                let value = try parser.expectUnsignedInt(UInt16.self)
                values.append(.u16(value))
                try parser.expect(.rightParen)
                return true

            case "u32.const":
                try parser.expect(.leftParen)
                try parser.expectKeyword("u32.const")
                let value = try parser.expectUnsignedInt(UInt32.self)
                values.append(.u32(value))
                try parser.expect(.rightParen)
                return true

            case "u64.const":
                try parser.expect(.leftParen)
                try parser.expectKeyword("u64.const")
                let value = try parser.expectUnsignedInt(UInt64.self)
                values.append(.u64(value))
                try parser.expect(.rightParen)
                return true

            // Signed integers
            case "s8.const":
                try parser.expect(.leftParen)
                try parser.expectKeyword("s8.const")
                let value: Int8 = try parser.expectSignedInt(fromBitPattern: Int8.init(bitPattern:))
                values.append(.s8(value))
                try parser.expect(.rightParen)
                return true

            case "s16.const":
                try parser.expect(.leftParen)
                try parser.expectKeyword("s16.const")
                let value: Int16 = try parser.expectSignedInt(fromBitPattern: Int16.init(bitPattern:))
                values.append(.s16(value))
                try parser.expect(.rightParen)
                return true

            case "s32.const":
                try parser.expect(.leftParen)
                try parser.expectKeyword("s32.const")
                let value: Int32 = try parser.expectSignedInt(fromBitPattern: Int32.init(bitPattern:))
                values.append(.s32(value))
                try parser.expect(.rightParen)
                return true

            case "s64.const":
                try parser.expect(.leftParen)
                try parser.expectKeyword("s64.const")
                let value: Int64 = try parser.expectSignedInt(fromBitPattern: Int64.init(bitPattern:))
                values.append(.s64(value))
                try parser.expect(.rightParen)
                return true

            // Boolean
            case "bool.const":
                try parser.expect(.leftParen)
                try parser.expectKeyword("bool.const")
                let boolKeyword = try parser.expectKeyword()
                let value: Bool
                switch boolKeyword {
                case "true": value = true
                case "false": value = false
                default:
                    throw WatParserError("expected 'true' or 'false'", location: parser.lexer.location())
                }
                values.append(.bool(value))
                try parser.expect(.rightParen)
                return true

            // Floating point
            case "float32.const", "f32.const":
                try parser.expect(.leftParen)
                _ = try parser.expectKeyword()  // float32.const or f32.const
                if try parser.takeKeyword("nan:canonical") {
                    values.append(.float32(Float(bitPattern: 0x7FC0_0000)))
                } else if try parser.takeKeyword("nan:arithmetic") {
                    values.append(.float32(Float(bitPattern: 0x7FC0_0000)))
                } else {
                    let value = try parser.expectFloat32()
                    values.append(.float32(Float(bitPattern: value.bitPattern)))
                }
                try parser.expect(.rightParen)
                return true

            case "float64.const", "f64.const":
                try parser.expect(.leftParen)
                _ = try parser.expectKeyword()  // float64.const or f64.const
                if try parser.takeKeyword("nan:canonical") {
                    values.append(.float64(Double(bitPattern: 0x7FF8_0000_0000_0000)))
                } else if try parser.takeKeyword("nan:arithmetic") {
                    values.append(.float64(Double(bitPattern: 0x7FF8_0000_0000_0000)))
                } else {
                    let value = try parser.expectFloat64()
                    values.append(.float64(Double(bitPattern: value.bitPattern)))
                }
                try parser.expect(.rightParen)
                return true

            // Character
            case "char.const":
                try parser.expect(.leftParen)
                try parser.expectKeyword("char.const")
                let str = try parser.expectString()
                guard let scalar = str.unicodeScalars.first, str.unicodeScalars.count == 1 else {
                    throw WatParserError("char.const expects a single character", location: parser.lexer.location())
                }
                values.append(.char(scalar))
                try parser.expect(.rightParen)
                return true

            // String (using "str.const" per component model test syntax)
            case "str.const":
                try parser.expect(.leftParen)
                try parser.expectKeyword("str.const")
                let str = try parser.expectString()
                values.append(.string(str))
                try parser.expect(.rightParen)
                return true

            // List
            case "list.const":
                try parser.expect(.leftParen)
                try parser.expectKeyword("list.const")
                var elements: [ComponentValue] = []
                while try parseComponentConstValue(&elements) {}
                values.append(.list(elements))
                try parser.expect(.rightParen)
                return true

            // Record
            case "record":
                try parser.expect(.leftParen)
                try parser.expectKeyword("record")
                var fields: [(name: String, value: ComponentValue)] = []
                while try parser.peek(.leftParen) != nil {
                    try parser.expect(.leftParen)
                    try parser.expectKeyword("field")
                    let fieldName = try parser.expectString()
                    var fieldValues: [ComponentValue] = []
                    guard try parseComponentConstValue(&fieldValues) else {
                        throw WatParserError("expected field value", location: parser.lexer.location())
                    }
                    fields.append((name: fieldName, value: fieldValues[0]))
                    try parser.expect(.rightParen)
                }
                values.append(.record(fields))
                try parser.expect(.rightParen)
                return true

            // Tuple
            case "tuple":
                try parser.expect(.leftParen)
                try parser.expectKeyword("tuple")
                var elements: [ComponentValue] = []
                while try parseComponentConstValue(&elements) {}
                values.append(.tuple(elements))
                try parser.expect(.rightParen)
                return true

            // Flags
            case "flags":
                try parser.expect(.leftParen)
                try parser.expectKeyword("flags")
                var labels: Set<String> = []
                while let token = try parser.peek(), case .string = token.kind {
                    labels.insert(try parser.expectString())
                }
                values.append(.flags(labels))
                try parser.expect(.rightParen)
                return true

            // variant.const "case" (payload)?. Nullary works because parseComponentConstValue peeks
            // for `(` and returns false as a no-op when the next token is `)`, leaving payloadValues
            // empty; do not turn `_ =` into a required-payload guard.
            case "variant.const":
                try parser.expect(.leftParen)
                try parser.expectKeyword("variant.const")
                let caseName = try parser.expectString()
                var payloadValues: [ComponentValue] = []
                _ = try parseComponentConstValue(&payloadValues)
                values.append(.variant(caseName: caseName, payload: payloadValues.first))
                try parser.expect(.rightParen)
                return true

            case "enum.const":
                try parser.expect(.leftParen)
                try parser.expectKeyword("enum.const")
                let caseName = try parser.expectString()
                values.append(.enum(caseName))
                try parser.expect(.rightParen)
                return true

            // record.const (field NAME <bare-value>)..., fields are unparenthesized scalars, distinct
            // from the parenthesized-field `record` value form above.
            case "record.const":
                try parser.expect(.leftParen)
                try parser.expectKeyword("record.const")
                var fields: [(name: String, value: ComponentValue)] = []
                while try parser.peek(.leftParen) != nil {
                    try parser.expect(.leftParen)
                    try parser.expectKeyword("field")
                    let fieldName = try parser.expectString()
                    let fieldValue = try parseBareConstValue()
                    fields.append((name: fieldName, value: fieldValue))
                    try parser.expect(.rightParen)
                }
                values.append(.record(fields))
                try parser.expect(.rightParen)
                return true

            // Tuple (component test .const syntax)
            case "tuple.const":
                try parser.expect(.leftParen)
                try parser.expectKeyword("tuple.const")
                var elements: [ComponentValue] = []
                while try parseComponentConstValue(&elements) {}
                values.append(.tuple(elements))
                try parser.expect(.rightParen)
                return true

            // Flags (component test .const syntax); bare labels, empty set allowed
            case "flags.const":
                try parser.expect(.leftParen)
                try parser.expectKeyword("flags.const")
                var labels: Set<String> = []
                while let token = try parser.peek(), case .string = token.kind {
                    labels.insert(try parser.expectString())
                }
                values.append(.flags(labels))
                try parser.expect(.rightParen)
                return true

            // option.some ALWAYS carries a payload, so guard it (a nullary `option.some`
            // is malformed); option.none is empty. This differs deliberately from result.ok/err
            // below, which allow an absent payload; do not "harmonize" the two.
            case "option.some":
                try parser.expect(.leftParen)
                try parser.expectKeyword("option.some")
                var payload: [ComponentValue] = []
                guard try parseComponentConstValue(&payload) else {
                    throw WatParserError("option.some expects a payload value", location: parser.lexer.location())
                }
                values.append(.option(payload[0]))
                try parser.expect(.rightParen)
                return true

            case "option.none":
                try parser.expect(.leftParen)
                try parser.expectKeyword("option.none")
                values.append(.option(nil))
                try parser.expect(.rightParen)
                return true

            // result.ok / result.err; payload OPTIONAL (result<_, E> has an empty ok arm, and vice
            // versa). Use `.first` (not a guard) to admit the nullary form, mirroring variant.const above.
            case "result.ok":
                try parser.expect(.leftParen)
                try parser.expectKeyword("result.ok")
                var payload: [ComponentValue] = []
                _ = try parseComponentConstValue(&payload)
                values.append(.resultOk(payload.first))
                try parser.expect(.rightParen)
                return true

            case "result.err":
                try parser.expect(.leftParen)
                try parser.expectKeyword("result.err")
                var payload: [ComponentValue] = []
                _ = try parseComponentConstValue(&payload)
                values.append(.resultErr(payload.first))
                try parser.expect(.rightParen)
                return true

            default:
                return false
            }
        }

        /// Parses one unparenthesized scalar const value, the field-value grammar inside `record.const`
        /// (e.g. `u8.const 0`). Limited to the forms the vendored suite uses; a new form throws so support
        /// is added deliberately rather than silently mis-parsed.
        private mutating func parseBareConstValue() throws(WatParserError) -> ComponentValue {
            let keyword = try parser.expectKeyword()
            switch keyword {
            case "u8.const": return .u8(try parser.expectUnsignedInt(UInt8.self))
            case "u32.const": return .u32(try parser.expectUnsignedInt(UInt32.self))
            case "enum.const": return .enum(try parser.expectString())
            case "str.const": return .string(try parser.expectString())
            // `list.const` keyword is bare here, but its elements are the parenthesized grammar
            // (e.g. `list.const (u32.const 10) (u32.const 20)`); delegate to parseComponentConstValue,
            // which peeks for `(` and stops at the field's closing `)`.
            case "list.const":
                var elements: [ComponentValue] = []
                while try parseComponentConstValue(&elements) {}
                return .list(elements)
            default:
                throw WatParserError(
                    "unsupported bare record.const field value '\(keyword)'",
                    location: parser.lexer.location())
            }
        }
    }

    // MARK: - Directive Parsing

    extension ComponentWASTDirective {
        static func peek(wastParser: ComponentWASTParser) throws(WatParserError) -> Bool {
            guard let keyword = try wastParser.parser.peekKeyword() else { return false }
            return keyword.starts(with: "assert_")
                || keyword == "component"
                || keyword == "register"
                || keyword == "invoke"
        }

        /// Try to parse a component directive inside an assert directive. If parsing
        /// the inner component fails (e.g., because it uses syntax that's invalid in
        /// that context), recover by skipping the paren block and returning a placeholder
        /// that will fail during encoding/validation.
        private static func parseOrSkipComponent(wastParser: inout ComponentWASTParser) throws(WatParserError) -> ComponentDirective {
            let savedParser = wastParser.parser
            do {
                return try wastParser.parens { wp throws(WatParserError) in
                    try ComponentDirective.parse(wastParser: &wp)
                }
            } catch {
                // Recovery: restore to before the component paren and skip it
                wastParser.parser = savedParser
                if (try? wastParser.parser.peek(.leftParen)) != nil {
                    _ = try? wastParser.parser.consume()
                    var depth = 1
                    while depth > 0 {
                        guard let token = try? wastParser.parser.consume() else { break }
                        switch token.kind {
                        case .leftParen: depth += 1
                        case .rightParen: depth -= 1
                        default: break
                        }
                    }
                }
                let location = savedParser.lexer.location()
                return ComponentDirective(source: .binary([]), id: nil, location: location)
            }
        }

        /// Parse a directive in a Component WAST script from "keyword ...)" form.
        /// Leading left parenthesis is already consumed.
        static func parse(wastParser: inout ComponentWASTParser) throws(WatParserError) -> ComponentWASTDirective {
            let keyword = try wastParser.parser.peekKeyword()
            switch keyword {
            case "component":
                // Check for "component definition" or "component instance" sub-keywords
                var lookahead = wastParser.parser
                try lookahead.expectKeyword("component")  // consume "component" in lookahead
                if let subKeyword = try lookahead.peekKeyword() {
                    if subKeyword == "definition" {
                        // (component definition $id? ...body...)
                        try wastParser.parser.expectKeyword("component")
                        try wastParser.parser.expectKeyword("definition")
                        let id = try wastParser.parser.takeId()
                        let location = wastParser.parser.lexer.location()

                        // Check for binary/quote forms first
                        let source: ComponentSource
                        if let rawSource = try wastParser.parser.parseBinaryOrQuote() {
                            switch rawSource {
                            case .binary(let bytes): source = .binary(bytes)
                            case .quote(let bytes): source = .quote(bytes)
                            }
                        } else {
                            // Text form - parseComponentBody handles the body and closing )
                            let componentParser = ComponentWatParser(features: wastParser.features)
                            let componentDef = try componentParser.parseComponentBody(&wastParser.parser, id: id)
                            source = .text(componentDef)
                        }
                        return .componentDefinition(
                            id: id?.value,
                            component: ComponentDirective(
                                source: source,
                                id: id?.value,
                                location: location
                            )
                        )
                    } else if subKeyword == "instance" {
                        // (component instance $id? $componentRef)
                        try wastParser.parser.expectKeyword("component")
                        try wastParser.parser.expectKeyword("instance")
                        let id = try wastParser.parser.takeId()
                        guard let componentRefName = try wastParser.parser.takeId() else {
                            throw WatParserError("expected component reference id after 'component instance'", location: wastParser.parser.lexer.location())
                        }
                        try wastParser.parser.expect(.rightParen)
                        return .componentInstance(id: id?.value, componentRef: componentRefName.value)
                    }
                }
                // Fall through to standard component parsing
                return .component(try ComponentDirective.parse(wastParser: &wastParser))

            case "assert_invalid":
                try wastParser.parser.consume()
                let component = try parseOrSkipComponent(wastParser: &wastParser)
                let message = try wastParser.parser.expectString()
                try wastParser.parser.expect(.rightParen)
                return .assertInvalid(component: component, message: message)

            case "assert_malformed":
                try wastParser.parser.consume()
                let component = try parseOrSkipComponent(wastParser: &wastParser)
                let message = try wastParser.parser.expectString()
                try wastParser.parser.expect(.rightParen)
                return .assertMalformed(component: component, message: message)

            case "assert_unlinkable":
                try wastParser.parser.consume()
                let component = try wastParser.parens { wp throws(WatParserError) in
                    try ComponentDirective.parse(wastParser: &wp)
                }
                let message = try wastParser.parser.expectString()
                try wastParser.parser.expect(.rightParen)
                return .assertUnlinkable(component: component, message: message)

            case "assert_return":
                try wastParser.parser.consume()
                let execute = try wastParser.parens { wp throws(WatParserError) in
                    try ComponentWASTExecute.parse(wastParser: &wp)
                }
                let results = try wastParser.parseConstValues()
                try wastParser.parser.expect(.rightParen)
                return .assertReturn(execute: execute, results: results)

            case "assert_trap":
                try wastParser.parser.consume()
                let execute = try wastParser.parens { wp throws(WatParserError) in
                    try ComponentWASTExecute.parse(wastParser: &wp)
                }
                let message = try wastParser.parser.expectString()
                try wastParser.parser.expect(.rightParen)
                return .assertTrap(execute: execute, message: message)

            case "register":
                try wastParser.parser.consume()
                let name = try wastParser.parser.expectString()
                let componentId = try wastParser.parser.takeId()
                try wastParser.parser.expect(.rightParen)
                return .register(name: name, componentId: componentId?.value)

            case "invoke":
                let invoke = try ComponentWASTInvoke.parse(wastParser: &wastParser)
                return .invoke(invoke)

            case let keyword?:
                throw WatParserError(
                    "unexpected component wast directive \(keyword)",
                    location: wastParser.parser.lexer.location()
                )
            case nil:
                throw WatParserError("unexpected eof", location: wastParser.parser.lexer.location())
            }
        }
    }

    // MARK: - ComponentDirective Parsing

    extension ComponentDirective {
        static func parse(wastParser: inout ComponentWASTParser) throws(WatParserError) -> ComponentDirective {
            let location = wastParser.parser.lexer.location()
            try wastParser.parser.expectKeyword("component")
            let id = try wastParser.parser.takeId()
            let source = try ComponentSource.parse(wastParser: &wastParser, id: id)
            return ComponentDirective(source: source, id: id?.value, location: location)
        }
    }

    extension ComponentSource {
        static func parse(wastParser: inout ComponentWASTParser, id: Name?) throws(WatParserError) -> ComponentSource {
            if let rawSource = try wastParser.parser.parseBinaryOrQuote() {
                switch rawSource {
                case .binary(let bytes): return .binary(bytes)
                case .quote(let bytes): return .quote(bytes)
                }
            }

            // Parse as text component using ComponentWatParser
            // Note: `(component $id?` has already been consumed, so we use parseComponentBody
            let componentParser = ComponentWatParser(features: wastParser.features)
            let componentDef = try componentParser.parseComponentBody(&wastParser.parser, id: id)
            return .text(componentDef)
        }
    }

    // MARK: - ComponentWASTExecute Parsing

    extension ComponentWASTExecute {
        static func parse(wastParser: inout ComponentWASTParser) throws(WatParserError) -> ComponentWASTExecute {
            let keyword = try wastParser.parser.peekKeyword()
            switch keyword {
            case "invoke":
                return .invoke(try ComponentWASTInvoke.parse(wastParser: &wastParser))
            case "get":
                try wastParser.parser.consume()
                let component = try wastParser.parser.takeId()
                let exportName = try wastParser.parser.expectString()
                try wastParser.parser.expect(.rightParen)
                return .get(component: component?.value, exportName: exportName)
            case "component":
                // Parse a component definition for assert_trap (instantiation trap testing)
                return .component(try ComponentDirective.parse(wastParser: &wastParser))
            case let keyword?:
                throw WatParserError(
                    "unexpected component wast execute \(keyword)",
                    location: wastParser.parser.lexer.location()
                )
            case nil:
                throw WatParserError("unexpected eof", location: wastParser.parser.lexer.location())
            }
        }
    }

    // MARK: - ComponentWASTInvoke Parsing

    extension ComponentWASTInvoke {
        static func parse(wastParser: inout ComponentWASTParser) throws(WatParserError) -> ComponentWASTInvoke {
            try wastParser.parser.expectKeyword("invoke")
            let component = try wastParser.parser.takeId()
            let name = try wastParser.parser.expectString()
            let args = try wastParser.parseConstValues()
            try wastParser.parser.expect(.rightParen)
            return ComponentWASTInvoke(component: component?.value, name: name, args: args)
        }
    }

#endif
