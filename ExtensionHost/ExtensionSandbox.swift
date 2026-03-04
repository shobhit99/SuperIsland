import JavaScriptCore

enum ExtensionSandbox {
    static func configureContext(_ context: JSContext, extensionID: String, permissions: [String]) {
        context.exceptionHandler = { _, exception in
            let message = exception?.toString() ?? "Unknown JavaScript exception"
            ExtensionLogger.shared.log(extensionID, .error, message)
        }

        context.evaluateScript("delete globalThis.eval;")
        context.evaluateScript("delete globalThis.Function;")

        if !permissions.contains("network") {
            context.evaluateScript("globalThis.__dynamicIslandNetworkDisabled = true;")
        }
    }
}
