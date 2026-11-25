#if ComponentModel

    import ComponentModel
    import WasmParser
    import WasmTypes

    // MARK: - Binary Format Extensions

    extension ComponentWatParser.ComponentAlias.Sort {
        /// Binary opcode for this sort, used in alias encoding.
        var sortOpcode: UInt8 {
            switch self {
            case .coreFunc: return CoreSortOpcode.function.rawValue
            case .coreMemory: return CoreSortOpcode.memory.rawValue
            case .coreTable: return CoreSortOpcode.table.rawValue
            case .coreGlobal: return CoreSortOpcode.global.rawValue
            case .coreTag: return CoreSortOpcode.tag.rawValue
            case .coreType: return CoreSortOpcode.type.rawValue
            case .coreModule: return CoreSortOpcode.module.rawValue
            case .componentFunc: return ComponentSortOpcode.function.rawValue
            case .componentType: return ComponentSortOpcode.type.rawValue
            case .componentInstance: return ComponentSortOpcode.instance.rawValue
            case .component: return ComponentSortOpcode.component.rawValue
            }
        }

        /// Whether this sort requires the core prefix byte (0x00) in the alias encoding.
        var requiresCorePrefix: Bool {
            switch self {
            case .coreFunc, .coreMemory, .coreTable, .coreGlobal, .coreTag: return true
            case .coreType, .coreModule: return true
            case .componentFunc, .componentType, .componentInstance, .component: return false
            }
        }
    }

#endif
