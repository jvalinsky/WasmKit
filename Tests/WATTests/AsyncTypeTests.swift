#if ComponentModel
    import Testing
    import WAT
    import WasmKit
    import WasmParser

    /// Async Component Model type-surface tests for message-pinned validation rejections
    /// and flag-dependent behavior.
    @Suite struct AsyncTypeTests {
        private static let asyncFeatures: WasmFeatureSet = .all.union([.componentModelAsync])

        /// `(stream char)` is an invalid stream element type.
        @Test func streamCharRejected() throws {
            let error = #expect(throws: WatParserError.self) {
                _ = try wat2wasm("(component (type (stream char)))", features: Self.asyncFeatures)
            }
            #expect(error?.description.contains("stream char") == true)
        }

        /// With the feature OFF, `stream` is not a recognized type keyword.
        @Test func asyncSyntaxRequiresFlag() throws {
            let error = #expect(throws: WatParserError.self) {
                _ = try wat2wasm("(component (type (stream u8)))", features: .default)
            }
            #expect(error?.description.contains("Unsupported type definition keyword stream") == true)
        }

        /// Enabling the async feature must not change the encoding of a purely synchronous component.
        @Test func syncComponentEncodingUnchangedAcrossFlag() throws {
            let wat = "(component (type (func (result u32))))"
            let off = try wat2wasm(wat, features: .default)
            let on = try wat2wasm(wat, features: Self.asyncFeatures)
            #expect(off == on)
        }

        /// With the feature OFF, an async canon op keyword is not a recognized canon
        /// operation: the parser rejects it with the top-level "Unsupported … canon operation" error.
        @Test func asyncCanonOpRequiresFlag() throws {
            let error = #expect(throws: WatParserError.self) {
                _ = try wat2wasm(
                    "(component (canon task.return (result u32) (core func $tr)))", features: .default)
            }
            #expect(error?.description.contains("task.return") == true)
        }

        /// The binary decoder gates `stream`/`future` value types like it gates memory64,
        /// threads, reference-types, and `func async`: a flag-OFF parser must reject them.
        @Test func streamBinaryDecodeRequiresFlag() throws {
            let bytes = try wat2wasm("(component (type (stream u8)))", features: Self.asyncFeatures)
            _ = try parseComponent(bytes: bytes, features: Self.asyncFeatures)  // flag ON: decodes
            #expect(throws: (any Error).self) {  // flag OFF: rejected at decode
                _ = try parseComponent(bytes: bytes, features: .default)
            }
        }
    }
#endif
