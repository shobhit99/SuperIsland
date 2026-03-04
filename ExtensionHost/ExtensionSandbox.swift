import JavaScriptCore

enum ExtensionSandbox {
    static func configureContext(_ context: JSContext, extensionID: String, permissions: [String]) {
        context.evaluateScript("delete globalThis.eval")
        context.evaluateScript("delete globalThis.Function")

        context.exceptionHandler = { _, exception in
            let message = exception?.toString() ?? "Unknown JavaScript exception"
            Task { @MainActor in
                ExtensionLogger.shared.log(extensionID, .error, message)
            }
        }

        if !permissions.contains("network") {
            context.evaluateScript(
                """
                if (globalThis.DynamicIsland && globalThis.DynamicIsland.http) {
                  globalThis.DynamicIsland.http.fetch = function() {
                    return Promise.reject(new Error("Permission denied: network"));
                  };
                }
                """
            )
        }
    }
}
