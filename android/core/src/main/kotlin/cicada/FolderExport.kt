package cicada

import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

object FolderExportFormat {
    fun name(s: Session): String {
        if (s.renamed ?: !s.title.startsWith("会议 ")) return s.title
        s.notes?.title?.takeIf { it.isNotEmpty() }?.let { return it }
        s.sourceFile?.let { f -> val dot = f.lastIndexOf('.'); return if (dot > 0) f.substring(0, dot) else f }
        return ""
    }

    private val banned = "/\\:*?\"<>|#^[]".codePoints().toArray().toSet()

    fun safeName(name: String): String {
        val spaced = StringBuilder()
        name.codePoints().forEach { cp -> if (cp in banned || cp < 0x20) spaced.append(' ') else spaced.appendCodePoint(cp) }
        var out = trim(spaced.split(Regex("[\\s\\p{Z}]+")).filter { it.isNotEmpty() }.joinToString(" "))
        if (out.toByteArray(Charsets.UTF_8).size > 120) {
            val cut = StringBuilder()
            var bytes = 0
            for (cp in out.codePoints().toArray()) {
                bytes += String(Character.toChars(cp)).toByteArray(Charsets.UTF_8).size
                if (bytes > 120) break
                cut.appendCodePoint(cp)
            }
            out = trim(cut.toString())
        }
        return out
    }

    private fun trim(s: String) = s.trim { it == ' ' || it == '.' }

    fun stem(s: Session, zone: ZoneId = ZoneId.systemDefault()): String {
        val date = format(s.startedAt, "yyyy-MM-dd HHmm", zone)
        val safe = safeName(name(s))
        return if (safe.isEmpty()) date else "$date $safe"
    }

    fun fileName(stem: String, taken: (String) -> Boolean): String {
        var n = 1
        while (true) {
            val name = if (n == 1) "$stem.md" else "$stem $n.md"
            if (!taken(name)) return name
            n++
        }
    }

    fun quote(s: String): String {
        val b = StringBuilder("\"")
        s.codePoints().forEach { cp ->
            when {
                cp == '\\'.code -> b.append("\\\\")
                cp == '"'.code -> b.append("\\\"")
                cp == '\n'.code -> b.append("\\n")
                cp == '\r'.code -> b.append("\\r")
                cp == '\t'.code -> b.append("\\t")
                cp < 0x20 -> b.append(String.format(Locale.ROOT, "\\u%04x", cp))
                else -> b.appendCodePoint(cp)
            }
        }
        return b.append('"').toString()
    }

    private fun byCodePoint(a: String, b: String): Int {
        val x = a.codePoints().toArray(); val y = b.codePoints().toArray()
        for (i in 0 until minOf(x.size, y.size)) if (x[i] != y[i]) return x[i].compareTo(y[i])
        return x.size.compareTo(y.size)
    }

    fun frontmatter(s: Session, zone: ZoneId = ZoneId.systemDefault()): String {
        val ended = s.endedAt ?: s.startedAt
        val languages = s.lines.map { it.srcLang }.distinct().sortedWith(::byCodePoint)
        val notes = s.notes?.let { if (it.isEmpty) "none" else if (it.final) "final" else "draft" } ?: "none"
        val minutes = maxOf(0L, (ended.toEpochMilli() - s.startedAt.toEpochMilli()) / 60_000)
        return "---\n" +
            "cicada: 1\n" +
            "id: ${quote(s.id)}\n" +
            "title: ${quote(name(s))}\n" +
            "started: ${quote(format(s.startedAt, "yyyy-MM-dd'T'HH:mm:ssxxx", zone))}\n" +
            "ended: ${quote(format(ended, "yyyy-MM-dd'T'HH:mm:ssxxx", zone))}\n" +
            "minutes: $minutes\n" +
            "languages: [${languages.joinToString(", ") { quote(it) }}]\n" +
            "source: ${quote(if (s.sourceFile == null) "meeting" else "file")}\n" +
            "notes: ${quote(notes)}\n" +
            "tags: [\"cicada\"]\n" +
            "---\n"
    }

    fun document(s: Session): String = frontmatter(s) + TranscriptExport.markdown(s)

    private fun format(at: Instant, pattern: String, zone: ZoneId) =
        DateTimeFormatter.ofPattern(pattern, Locale.ROOT).withZone(zone).format(at)
}

class FolderExportIndex(
    var folder: String = "",
    val files: MutableMap<String, String> = mutableMapOf(),
    val uris: MutableMap<String, String> = mutableMapOf(),
    val pending: MutableList<String> = mutableListOf(),
    var lastFile: String? = null,
    var lastAt: Instant? = null,
) {
    fun toJson(): Map<String, Any?> = mapOf(
        "folder" to folder, "files" to files.toSortedMap(), "uris" to uris.toSortedMap(), "pending" to pending.toList(),
        "lastFile" to lastFile, "lastAt" to lastAt?.let(Iso8601::write),
    )

    fun save(file: File) {
        try {
            val tmp = File(file.path + ".tmp")
            tmp.writeText(Json.write(toJson(), slashes = false))
            if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
        } catch (e: Exception) { Log.d("folder export: index not saved ${e.javaClass.simpleName}") }
    }

    companion object {
        fun from(o: Map<String, Any?>) = FolderExportIndex(
            folder = o["folder"].str() ?: "",
            files = strings(o["files"]), uris = strings(o["uris"]),
            pending = o["pending"].arr().mapNotNull { it.str() }.toMutableList(),
            lastFile = o["lastFile"].str(), lastAt = Iso8601.read(o["lastAt"].str()),
        )

        fun load(file: File): FolderExportIndex =
            try { if (file.isFile) Json.parseObject(file.readText())?.let(::from) else null } catch (_: Exception) { null } ?: FolderExportIndex()

        private fun strings(v: Any?): MutableMap<String, String> =
            v.obj()?.mapNotNull { (k, x) -> x.str()?.let { k to it } }?.toMap(mutableMapOf()) ?: mutableMapOf()
    }
}
