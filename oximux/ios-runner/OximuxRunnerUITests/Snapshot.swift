import XCTest

/// Reading the screen: the app's frame, its accessibility tree, a picture.
/// Reading never brings an app to the front.
enum Snapshot {
    static func viewport(_ command: RunnerCommand) throws -> Done {
        let (app, _) = try Commands.target(command, gesture: false)
        let frame = app.frame
        // XCTest answers an empty frame when it could not read one.
        guard frame.width > 0, frame.height > 0 else { throw RunnerError.xctest("the app's frame could not be read") }
        return Done(data: [
            "x": frame.origin.x, "y": frame.origin.y, "width": frame.width, "height": frame.height,
            "orientation": XCUIDevice.shared.orientation.rawValue,
        ])
    }

    /// The tree, flattened depth first: role, label, value, identifier,
    /// frame (points, from the screen's top-left), enabled, depth. At most
    /// `RunnerProtocol.maxNodes`; `truncated` says when there were more.
    static func tree(_ command: RunnerCommand) throws -> Done {
        let (app, _) = try Commands.target(command, gesture: false)
        let root = try app.snapshot()
        var nodes: [[String: Any]] = []
        var truncated = false
        func walk(_ node: XCUIElementSnapshot, _ depth: Int) {
            guard nodes.count < RunnerProtocol.maxNodes else { truncated = true; return }
            let f = node.frame
            var entry: [String: Any] = [
                "role": role(node.elementType),
                "frame": [f.origin.x, f.origin.y, f.width, f.height],
                "enabled": node.isEnabled,
                "depth": depth,
            ]
            if !node.label.isEmpty { entry["label"] = node.label }
            if !node.identifier.isEmpty { entry["identifier"] = node.identifier }
            if let value = node.value.map({ "\($0)" }), !value.isEmpty { entry["value"] = value }
            nodes.append(entry)
            for child in node.children { walk(child, depth + 1) }
        }
        walk(root, 0)
        return Done(data: ["nodes": nodes, "truncated": truncated])
    }

    /// The whole screen as a PNG (base64): for when nothing captures it.
    static func screenshot() -> Done {
        Done(data: ["pngBase64": XCUIScreen.main.screenshot().pngRepresentation.base64EncodedString()])
    }

    /// A role name for the common element types; others by number.
    static func role(_ type: XCUIElement.ElementType) -> String {
        let names: [XCUIElement.ElementType: String] = [
            .application: "application", .window: "window", .other: "other", .group: "group",
            .button: "button", .staticText: "staticText", .textField: "textField",
            .secureTextField: "secureTextField", .searchField: "searchField", .textView: "textView",
            .image: "image", .icon: "icon", .cell: "cell", .table: "table", .collectionView: "collectionView",
            .scrollView: "scrollView", .switch: "switch", .toggle: "toggle", .slider: "slider",
            .stepper: "stepper", .picker: "picker", .pickerWheel: "pickerWheel", .segmentedControl: "segmentedControl",
            .link: "link", .navigationBar: "navigationBar", .tabBar: "tabBar", .tab: "tab", .toolbar: "toolbar",
            .alert: "alert", .sheet: "sheet", .keyboard: "keyboard", .key: "key", .menu: "menu",
            .menuItem: "menuItem", .webView: "webView", .progressIndicator: "progressIndicator",
            .activityIndicator: "activityIndicator", .pageIndicator: "pageIndicator", .map: "map",
        ]
        return names[type] ?? "element\(type.rawValue)"
    }
}
