pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "nestlo-android"

// The protocol client and terminal emulator live in a standalone, JVM-only build so they
// can be tested without the Android SDK. It is substituted for dev.nestlo:nestlo-core.
includeBuild("core")

include(":app")
