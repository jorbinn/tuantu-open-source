allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// 统一强制所有插件子模块用 compileSdk 36（部分插件还在用 33/34，
// 会被 androidx 新库的 AAR 元数据检查卡住）。必须在 evaluationDependsOn 之前注册。
subprojects {
    afterEvaluate {
        val androidExt = extensions.findByName("android") ?: return@afterEvaluate
        for (m in androidExt.javaClass.methods) {
            if (m.name == "setCompileSdk") {
                try { m.invoke(androidExt, 36) } catch (_: Throwable) {}
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
