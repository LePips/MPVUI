// This gradle project is part of a conventional Skip app project.
pluginManagement {
    // Initialize the Skip plugin folder and perform a pre-build for non-Xcode builds
    val pluginPath = File.createTempFile("skip-plugin-path", ".tmp")

    val skipPluginResult = providers.exec {
        commandLine("/bin/sh", "-c", "exec skip plugin --prebuild --package-path \"\$1\" --plugin-ref \"\$2\"",
            "skip-bootstrap", settings.rootDir.parent, pluginPath.absolutePath)
        environment("SKIP_DYNAMIC_LIBRARIES", "1")
        environment("PATH", "${System.getenv("PATH")}:/opt/homebrew/bin")
    }
    val skipPluginOutput = skipPluginResult.standardOutput.asText.get()
    print(skipPluginOutput)
    val skipPluginError = skipPluginResult.standardError.asText.get()
    print(skipPluginError)

    val includedPluginPath = pluginPath.readText()
    pluginPath.delete()
    includeBuild(includedPluginPath) {
        name = "skip-plugins"
    }
}

plugins {
    id("skip-plugin") apply true
}

// Build the same Android library used by Kotlin consumers directly from this checkout.
includeBuild("../../Android") {
    dependencySubstitution {
        substitute(module("io.github.lepips:mpvui")).using(project(":mpvui"))
    }
}
