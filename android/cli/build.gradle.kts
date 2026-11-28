plugins { id("org.jetbrains.kotlin.jvm"); application }
kotlin { jvmToolchain(21) }
dependencies { implementation(project(":core")) }
application { mainClass = "cicada.cli.MainKt"; applicationName = "cicada-cli" }
