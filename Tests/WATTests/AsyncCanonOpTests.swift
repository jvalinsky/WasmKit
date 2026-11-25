#if ComponentModel
    import ComponentModel
    import Testing
    import WAT
    import WasmParser

    /// Checks that the decoder maps each async canon built-in to its opcode and
    /// immediate shape. `ComponentTests` compares only encoder output with `wasm-tools`.
    @Suite struct AsyncCanonOpTests {
        private static let asyncFeatures: WasmFeatureSet = .all.union([.componentModelAsync])

        // MARK: - Decode helpers

        /// Encodes `wat` with the async feature on and returns every canonical
        /// definition in the binary. Uses `WasmParser.ComponentParser` directly
        /// because `parseComponent` throws for async canon built-ins.
        private func decodeCanonicalDefinitions(_ wat: String) throws -> [CanonicalDefinition] {
            let bytes = try WAT.wat2wasm(wat, features: Self.asyncFeatures)
            var parser = WasmParser.ComponentParser(bytes: bytes, features: Self.asyncFeatures)
            var defs: [CanonicalDefinition] = []
            while let payload = try parser.parseNext() {
                if case .canonSection(let canons) = payload {
                    defs.append(contentsOf: canons)
                }
            }
            return defs
        }

        /// Decode `wat` and require it contains exactly one async canon built-in.
        private func singleAsyncBuiltin(_ wat: String) throws -> AsyncCanonicalBuiltin {
            let builtins = try decodeCanonicalDefinitions(wat).compactMap {
                (def: CanonicalDefinition) -> AsyncCanonicalBuiltin? in
                if case .asyncBuiltin(let builtin) = def { return builtin }
                return nil
            }
            #expect(builtins.count == 1)
            return try #require(builtins.first)
        }

        private func optionsContainAsync(_ options: [CanonicalOption]) -> Bool {
            options.contains { if case .async = $0 { return true } else { return false } }
        }

        // MARK: - Shape 1: none (waitable.join)

        @Test func decodesNoneShape() throws {
            let builtin = try singleAsyncBuiltin("(component (canon waitable.join (core func $wj)))")
            #expect(builtin.opcode == .waitableJoin)
            guard case .none = builtin.immediates else {
                Issue.record("expected .none, got \(builtin.immediates)")
                return
            }
        }

        // MARK: - backpressure.inc / backpressure.dec (none shape)

        /// `backpressure.{inc,dec}` carry no immediate, using the same `()->()` shape
        /// as `waitable-set.new`. The form mirrors `waitable.join` above.
        @Test func decodesBackpressureIncDecAsNoneShape() throws {
            let inc = try singleAsyncBuiltin("(component (canon backpressure.inc (core func $bi)))")
            #expect(inc.opcode == .backpressureInc)
            guard case .none = inc.immediates else {
                Issue.record("expected .none for backpressure.inc, got \(inc.immediates)")
                return
            }

            let dec = try singleAsyncBuiltin("(component (canon backpressure.dec (core func $bd)))")
            #expect(dec.opcode == .backpressureDec)
            guard case .none = dec.immediates else {
                Issue.record("expected .none for backpressure.dec, got \(dec.immediates)")
                return
            }
        }

        // MARK: - Shape 2: type (stream.new)

        @Test func decodesTypeShape() throws {
            let builtin = try singleAsyncBuiltin(
                "(component (type $ST (stream u8)) (canon stream.new $ST (core func $sn)))")
            #expect(builtin.opcode == .streamNew)
            guard case .type = builtin.immediates else {
                Issue.record("expected .type, got \(builtin.immediates)")
                return
            }
        }

        // MARK: - Shape 3: typeWithOptions (stream.read async)

        @Test func decodesTypeWithOptionsShape() throws {
            let builtin = try singleAsyncBuiltin(
                "(component (type $ST (stream u8)) (canon stream.read $ST async (core func $sr)))")
            #expect(builtin.opcode == .streamRead)
            guard case .typeWithOptions(_, let options) = builtin.immediates else {
                Issue.record("expected .typeWithOptions, got \(builtin.immediates)")
                return
            }
            #expect(optionsContainAsync(options))
        }

        // MARK: - Shape 4: typeWithAsyncFlag (stream.cancel-read)

        @Test func decodesTypeWithAsyncFlagShape() throws {
            let plain = try singleAsyncBuiltin(
                "(component (type $ST (stream u8)) (canon stream.cancel-read $ST (core func $scr)))")
            #expect(plain.opcode == .streamCancelRead)
            guard case .typeWithAsyncFlag(_, let plainAsync) = plain.immediates else {
                Issue.record("expected .typeWithAsyncFlag, got \(plain.immediates)")
                return
            }
            #expect(plainAsync == false)

            // The `async` keyword variant exercises the flag-true decode path.
            let flagged = try singleAsyncBuiltin(
                "(component (type $ST (stream u8)) (canon stream.cancel-read $ST async (core func $scr)))")
            guard case .typeWithAsyncFlag(_, let flaggedAsync) = flagged.immediates else {
                Issue.record("expected .typeWithAsyncFlag, got \(flagged.immediates)")
                return
            }
            #expect(flaggedAsync == true)
        }

        // MARK: - Shape 5: asyncFlag (subtask.cancel)

        @Test func decodesAsyncFlagShape() throws {
            let plain = try singleAsyncBuiltin("(component (canon subtask.cancel (core func $sc)))")
            #expect(plain.opcode == .subtaskCancel)
            guard case .asyncFlag(let plainFlag) = plain.immediates else {
                Issue.record("expected .asyncFlag, got \(plain.immediates)")
                return
            }
            #expect(plainFlag == false)

            let flagged = try singleAsyncBuiltin("(component (canon subtask.cancel async (core func $sc)))")
            guard case .asyncFlag(let flag) = flagged.immediates else {
                Issue.record("expected .asyncFlag, got \(flagged.immediates)")
                return
            }
            #expect(flag == true)
        }

        // MARK: - Shape 6: cancellableFlag (thread.yield)

        @Test func decodesCancellableFlagShape() throws {
            let plain = try singleAsyncBuiltin("(component (canon thread.yield (core func $ty)))")
            #expect(plain.opcode == .threadYield)
            guard case .cancellableFlag(let plainFlag) = plain.immediates else {
                Issue.record("expected .cancellableFlag, got \(plain.immediates)")
                return
            }
            #expect(plainFlag == false)

            let flagged = try singleAsyncBuiltin("(component (canon thread.yield cancellable (core func $ty)))")
            guard case .cancellableFlag(let flag) = flagged.immediates else {
                Issue.record("expected .cancellableFlag, got \(flagged.immediates)")
                return
            }
            #expect(flag == true)
        }

        // MARK: - Shape 7: resultListWithOptions (task.return)

        @Test func decodesResultListWithOptionsShape() throws {
            // With a result type.
            let withResult = try singleAsyncBuiltin(
                "(component (canon task.return (result u32) (core func $tr)))")
            #expect(withResult.opcode == .taskReturn)
            guard case .resultListWithOptions(let result, let options) = withResult.immediates else {
                Issue.record("expected .resultListWithOptions, got \(withResult.immediates)")
                return
            }
            #expect(result != nil)
            #expect(options.isEmpty)

            // Empty result list.
            let noResult = try singleAsyncBuiltin("(component (canon task.return (core func $tr)))")
            guard case .resultListWithOptions(let emptyResult, _) = noResult.immediates else {
                Issue.record("expected .resultListWithOptions, got \(noResult.immediates)")
                return
            }
            #expect(emptyResult == nil)
        }

        // MARK: - Shape 8: context (context.get / context.set)

        @Test func decodesContextShape() throws {
            let get = try singleAsyncBuiltin("(component (canon context.get i32 0 (core func $cg)))")
            #expect(get.opcode == .contextGetI32)
            guard case .context(let getType, let getSlot) = get.immediates else {
                Issue.record("expected .context, got \(get.immediates)")
                return
            }
            #expect(getType == .i32)
            #expect(getSlot == 0)

            let set = try singleAsyncBuiltin("(component (canon context.set i64 3 (core func $cs)))")
            #expect(set.opcode == .contextSetI32)
            guard case .context(let setType, let setSlot) = set.immediates else {
                Issue.record("expected .context, got \(set.immediates)")
                return
            }
            #expect(setType == .i64)
            #expect(setSlot == 3)
        }

        // MARK: - Shape 9: cancellableWithMemory (waitable-set.wait)

        @Test func decodesCancellableWithMemoryShape() throws {
            let builtin = try singleAsyncBuiltin(
                """
                (component
                  (core module $Memory (memory (export "mem") 1))
                  (core instance $memory (instantiate $Memory))
                  (canon waitable-set.wait (memory $memory "mem") (core func $w)))
                """)
            #expect(builtin.opcode == .waitableSetWait)
            guard case .cancellableWithMemory(let cancellable, _) = builtin.immediates else {
                Issue.record("expected .cancellableWithMemory, got \(builtin.immediates)")
                return
            }
            #expect(cancellable == false)
        }

        // MARK: - Shape 10: typeWithTable (thread.new-indirect)

        @Test func decodesTypeWithTableShape() throws {
            let builtin = try singleAsyncBuiltin(
                """
                (component
                  (core module $Table (table (export "__indirect_function_table") 2 funcref))
                  (core instance $table (instantiate $Table))
                  (core type $start-func-ty (func (param i32)))
                  (alias core export $table "__indirect_function_table" (core table $ift))
                  (core func $tni (canon thread.new-indirect $start-func-ty (table $ift))))
                """)
            #expect(builtin.opcode == .threadNewIndirect)
            guard case .typeWithTable = builtin.immediates else {
                Issue.record("expected .typeWithTable, got \(builtin.immediates)")
                return
            }
        }

        // MARK: - `func async` parse positions

        /// `func async` in an inline import type. The inline
        /// type lands in the component type section; assert one decodes as async.
        @Test func decodesAsyncFuncInImportPosition() throws {
            let wat = #"(component (import "f" (func $f async (result u32))))"#
            let bytes = try WAT.wat2wasm(wat, features: Self.asyncFeatures)
            #expect(!bytes.isEmpty)

            var parser = WasmParser.ComponentParser(bytes: bytes, features: Self.asyncFeatures)
            var sawAsyncFunc = false
            while let payload = try parser.parseNext() {
                if case .typeSection(let types) = payload {
                    for type in types {
                        if case .function(let funcType) = type, funcType.isAsync {
                            sawAsyncFunc = true
                        }
                    }
                }
            }
            #expect(sawAsyncFunc)
        }

        /// `func async` exported from an inline instance type.
        /// Flag-gated parsing is the assertion here.
        @Test func parsesAsyncFuncInInstanceTypeExportPosition() throws {
            let wat = #"(component (type (instance (export "write4" (func async)))))"#
            let bytes = try WAT.wat2wasm(wat, features: Self.asyncFeatures)
            #expect(!bytes.isEmpty)
        }

        /// With the feature OFF, the `async` keyword between params and result is not
        /// consumed, so both new `func async` positions fail to parse.
        @Test func asyncFuncPositionsRejectedWithFlagOff() throws {
            #expect(throws: WatParserError.self) {
                _ = try WAT.wat2wasm(
                    #"(component (import "f" (func $f async (result u32))))"#, features: .default)
            }
            #expect(throws: WatParserError.self) {
                _ = try WAT.wat2wasm(
                    #"(component (type (instance (export "write4" (func async)))))"#, features: .default)
            }
        }
    }
#endif
