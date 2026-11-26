#if ComponentModel
    import ComponentModel
    import WasmTypes

    // MARK: - Component Instance

    /// Internal representation of an instantiated component.
    /// This stores all the runtime state for a component instance.
    struct ComponentInstanceEntity {
        /// Core module instances created during instantiation
        var coreInstances: [InternalInstance]

        /// Exported values accessible by name
        var exports: [String: InternalComponentExternalValue]

        /// Component-level functions (lifted core functions)
        var functions: [InternalComponentFunction]

        /// Nested component instances
        var nestedComponents: [InternalComponentInstance]

        /// Creates an empty component instance entity
        static var empty: ComponentInstanceEntity {
            ComponentInstanceEntity(
                coreInstances: [],
                exports: [:],
                functions: [],
                nestedComponents: []
            )
        }
    }

    /// Type-safe handle to a component instance entity.
    typealias InternalComponentInstance = EntityHandle<ComponentInstanceEntity>

    extension InternalComponentInstance {
        var exports: [String: InternalComponentExternalValue] { withValue { $0.exports } }
    }

    /// A stateful instance of a WebAssembly component.
    /// Created by instantiating a component with resolved imports.
    public struct ComponentInstance {
        let handle: InternalComponentInstance
        let store: Store

        init(handle: InternalComponentInstance, store: Store) {
            self.handle = handle
            self.store = store
        }

        /// Returns the exported value with the given name.
        public func export(_ name: String) -> ComponentExternalValue? {
            guard let entity = handle.exports[name] else { return nil }
            return ComponentExternalValue(handle: entity, store: store)
        }

        /// Returns the exported component function with the given name.
        public func exportedFunction(_ name: String) -> ComponentFunction? {
            guard case .function(let function) = export(name) else { return nil }
            return function
        }

        /// A dictionary of exported values by name.
        public var exports: ComponentExports {
            ComponentExports(store: store, items: handle.exports)
        }
    }

    /// A map of exported component values by name.
    public struct ComponentExports: Sequence {
        let store: Store
        let items: [String: InternalComponentExternalValue]

        /// Returns the exported value with the given name.
        public subscript(_ name: String) -> ComponentExternalValue? {
            guard let entity = items[name] else { return nil }
            return ComponentExternalValue(handle: entity, store: store)
        }

        /// Returns the exported function with the given name.
        public subscript(function name: String) -> ComponentFunction? {
            guard case .function(let function) = self[name] else { return nil }
            return function
        }

        public struct Iterator: IteratorProtocol {
            private let store: Store
            private var iterator: Dictionary<String, InternalComponentExternalValue>.Iterator

            init(parent: ComponentExports) {
                self.store = parent.store
                self.iterator = parent.items.makeIterator()
            }

            public mutating func next() -> (name: String, value: ComponentExternalValue)? {
                guard let (name, entity) = iterator.next() else { return nil }
                return (name, ComponentExternalValue(handle: entity, store: store))
            }
        }

        public func makeIterator() -> Iterator {
            Iterator(parent: self)
        }
    }

    // MARK: - Component External Values

    /// Internal representation of component-level external values (import/export).
    enum InternalComponentExternalValue {
        case function(InternalComponentFunction)
        case value(ComponentValue)
        case type(ComponentTypeIndex)
        case instance(InternalComponentInstance)
        /// A core module definition (from modules index space)
        case coreModule(Module)
        /// A core module instance (from core instances index space)
        case coreInstance(InternalInstance)

        /// Describe an internal external value for error messages.
        var tagDescription: String {
            switch self {
            case .function: return "function"
            case .value: return "value"
            case .type: return "type"
            case .instance: return "instance"
            case .coreModule: return "coreModule"
            case .coreInstance: return "coreInstance"
            }
        }
    }

    /// Public representation of component-level external values.
    public enum ComponentExternalValue {
        case function(ComponentFunction)
        case value(ComponentValue)
        case type(ComponentTypeIndex)
        case instance(ComponentInstance)
        /// A core module definition (from modules index space)
        case coreModule(Module)
        /// A core module instance (from core instances index space)
        case coreInstance(Instance)

        init(handle: InternalComponentExternalValue, store: Store) {
            switch handle {
            case .function(let function):
                self = .function(ComponentFunction(handle: function, store: store))
            case .value(let value):
                self = .value(value)
            case .type(let typeIndex):
                self = .type(typeIndex)
            case .instance(let instance):
                self = .instance(ComponentInstance(handle: instance, store: store))
            case .coreModule(let module):
                self = .coreModule(module)
            case .coreInstance(let moduleInstance):
                self = .coreInstance(Instance(handle: moduleInstance, store: store))
            }
        }
    }

    // MARK: - Component Function

    /// Internal storage for a component function that wraps a core function with lifting/lowering.
    struct ComponentFunctionEntity {
        /// The lifted function type (component-level signature)
        let type: ComponentFuncType

        /// The underlying core function
        let coreFunction: InternalFunction

        /// Canon options (memory, realloc, etc.)
        let canonOptions: CanonOptions

        /// The instance that owns this function
        let instance: InternalComponentInstance

        /// Type resolver for nested type lookups during canonical ABI operations
        let resolveType: (ComponentTypeIndex) throws -> ComponentDefValType
    }

    /// Type-safe handle to a component function entity.
    typealias InternalComponentFunction = EntityHandle<ComponentFunctionEntity>

    extension InternalComponentFunction {
        var type: ComponentFuncType { withValue { $0.type } }
        var coreFunction: InternalFunction { withValue { $0.coreFunction } }
        var canonOptions: CanonOptions { withValue { $0.canonOptions } }
        var resolveType: (ComponentTypeIndex) throws -> ComponentDefValType { withValue { $0.resolveType } }
    }

    /// A component function that can be invoked with component-level values.
    /// Component functions lift core Wasm values to component values on return
    /// and lower component values to core Wasm values on call.
    public struct ComponentFunction {
        let handle: InternalComponentFunction
        let store: Store

        init(handle: InternalComponentFunction, store: Store) {
            self.handle = handle
            self.store = store
        }

        /// The type of a host component function implementation closure.
        ///
        /// Mirrors `Function.Implementation` one level up: the closure receives
        /// component-level values and returns component-level values, and WasmKit
        /// performs the canonical ABI lifting/lowering around the call.
        public typealias Implementation = (borrowing Caller, [ComponentValue]) throws -> [ComponentValue]

        /// Creates a component function backed by an existing host core function.
        ///
        /// Use this when you already have a `Function` whose type is the flattened
        /// form of `type` - one core value per flat primitive parameter, and the
        /// flattened result type. The component function lowers its arguments to
        /// core values before calling the host function and lifts its results back.
        ///
        /// - Parameters:
        ///   - store: The store to allocate the component function in.
        ///   - function: The host function backing this component function.
        ///   - type: The component-level function type.
        public init(store: Store, function: Function, type: ComponentFuncType) {
            self.init(store: store, type: type, coreFunction: function.handle)
        }

        /// Creates a component function backed by a native host closure.
        ///
        /// This is the component-level counterpart of `Function.init(store:type:body:)`.
        /// The closure works with component-level values; WasmKit lowers the arguments
        /// to flat core values, invokes the closure, and lifts the results back.
        /// Pass the result to `ComponentImports.define(name:function:)` to satisfy
        /// a component import of the same name.
        ///
        /// Only flat primitive parameter and result types are supported (booleans,
        /// integers, floats, and `char`): each flattens to exactly one core value.
        /// A `string`, list, record, tuple, or other compound type traps with a
        /// `CanonicalABIError` when the function is called, matching what
        /// canonical lowering supports today.
        ///
        /// - Parameters:
        ///   - store: The store to allocate the component function in.
        ///   - type: The component-level function type.
        ///   - body: The implementation of the function.
        public init(store: Store, type: ComponentFuncType, body: @escaping Implementation) {
            // Lower the component function to a core host function that lifts its
            // flat core arguments to component values, calls the closure, and
            // lowers the component results back to flat core values.
            // This mirrors the wrapper `ComponentLoader` builds for `canon.lower`.
            let coreFunction = Function(store: store, type: flattenComponentFuncType(type)) { caller, coreArgs in
                var componentArgs: [ComponentValue] = []
                componentArgs.reserveCapacity(type.params.count)
                var argIndex = 0
                for param in type.params {
                    // Reject non-flat types loudly instead of misaligning arguments:
                    // strings flatten to two core values, records/tuples/lists to none.
                    guard param.type.flattenedCount == 1, argIndex < coreArgs.count else {
                        throw CanonicalABIError(
                            description: "Host component function does not support parameter type \(param.type): only flat primitive types are supported"
                        )
                    }
                    componentArgs.append(try param.type.liftFlatCoreValue(coreArgs[argIndex]))
                    argIndex += 1
                }

                let results = try body(caller, componentArgs)

                switch type.result {
                case nil:
                    guard results.isEmpty else {
                        throw CanonicalABIError(
                            description: "Host component function with no result returned \(results.count) value(s)"
                        )
                    }
                    return []
                case let resultType?:
                    guard resultType.flattenedCount == 1, results.count == 1, let result = results.first else {
                        throw CanonicalABIError(
                            description: "Host component function with result type \(resultType) must return exactly one component value; only flat primitive result types are supported"
                        )
                    }
                    return try lowerFlat(result, paramType: resultType)
                }
            }
            self.init(store: store, type: type, coreFunction: coreFunction.handle)
        }

        /// Creates a component function from a core function handle.
        ///
        /// The entity holds no guest memory and no component type table: string
        /// and list values cannot cross this boundary yet, and indexed types
        /// (records/variants defined in a component) cannot be resolved.
        /// The owning component instance is a placeholder, as in canonical
        /// lifting - nothing reads it today.
        private init(store: Store, type: ComponentFuncType, coreFunction: InternalFunction) {
            let entity = ComponentFunctionEntity(
                type: type,
                coreFunction: coreFunction,
                canonOptions: CanonOptions(),
                instance: store.allocator.allocate(componentInstance: .empty),
                resolveType: { (index: ComponentTypeIndex) throws -> ComponentDefValType in
                    throw CanonicalABIError(
                        description: "Host component function cannot resolve component type index \(index.rawValue): host functions have no component type table"
                    )
                }
            )
            self.init(handle: store.allocator.allocate(componentFunction: entity), store: store)
        }

        /// The component-level function type.
        public var type: ComponentFuncType {
            handle.type
        }

        /// Resolves a type index to its component value type.
        /// Used for parsing nested types in WAVE arguments.
        public func resolveType(_ index: ComponentTypeIndex) throws -> ComponentDefValType {
            try handle.resolveType(index)
        }

        /// Invokes the component function with the given arguments.
        ///
        /// - Parameter arguments: The component-level arguments to pass to the function.
        /// - Returns: The component-level results.
        /// - Throws: A trap if the function invocation fails.
        @discardableResult
        public func invoke(_ arguments: [ComponentValue] = []) throws -> [ComponentValue] {
            // 1. Lower each argument to core values
            var coreArgs: [Value] = []
            for (index, arg) in arguments.enumerated() {
                let paramType = handle.type.params[index].type
                let lowered = try arg.lower(
                    to: paramType,
                    resolveType: handle.resolveType,
                    options: handle.canonOptions,
                    store: store
                )
                coreArgs.append(contentsOf: lowered)
            }

            // 2. Call underlying core function
            var stack = ExecutionStack(engine: store.engine)
            let coreResults = try handle.coreFunction.invoke(coreArgs, store: store, stack: &stack)

            // 3. Lift return values to component values
            let results: [ComponentValue]
            if let resultType = handle.type.result {
                // Check if indirect return is used (when flattened result count > MAX_FLAT_RESULTS)
                let flatCount = resultType.flattenedCount
                if flatCount > MAX_FLAT_RESULTS {
                    // Indirect return: core function returned a single i32 pointer
                    // Read the result values from memory at that pointer
                    guard case .i32(let retptr) = coreResults.first else {
                        throw CanonicalABIError(description: "Expected i32 return pointer for indirect result")
                    }
                    // Debug: Check if memory is available
                    guard handle.canonOptions.memory != nil else {
                        throw CanonicalABIError(description: "Indirect result requires memory but canon options has no memory")
                    }
                    results = try [
                        resultType.liftValueFromMemory(
                            at: retptr,
                            resolveType: handle.resolveType,
                            options: handle.canonOptions,
                            store: store
                        )
                    ]
                } else {
                    // Direct return: values are in coreResults
                    var iterator = coreResults.makeIterator()
                    results = try [
                        ComponentValue.lift(
                            from: &iterator,
                            to: resultType,
                            resolveType: handle.resolveType,
                            options: handle.canonOptions,
                            store: store
                        )
                    ]
                }
            } else {
                results = []
            }

            // 4. Execute post-return if specified
            if let postReturn = handle.canonOptions.postReturn {
                _ = try postReturn.invoke(coreResults, store: store, stack: &stack)
            }

            return results
        }

        /// Invokes the component function with the given arguments.
        @discardableResult
        public func callAsFunction(_ arguments: [ComponentValue] = []) throws -> [ComponentValue] {
            try invoke(arguments)
        }
    }

    // MARK: - Canon Options

    /// Options for canonical lifting/lowering operations.
    struct CanonOptions {
        /// The memory to use for string and list operations
        var memory: InternalMemory?

        /// The realloc function to use for allocating memory
        var realloc: InternalFunction?

        /// The post-return function to call after returning
        var postReturn: InternalFunction?

        /// The string encoding to use
        var stringEncoding: ComponentStringEncoding

        init(
            memory: InternalMemory? = nil,
            realloc: InternalFunction? = nil,
            postReturn: InternalFunction? = nil,
            stringEncoding: ComponentStringEncoding = .utf8
        ) {
            self.memory = memory
            self.realloc = realloc
            self.postReturn = postReturn
            self.stringEncoding = stringEncoding
        }
    }

#endif
