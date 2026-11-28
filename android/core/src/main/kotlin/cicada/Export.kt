package cicada

import java.io.ByteArrayOutputStream
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

object SpeakerLabels {
    const val SHOWN_AFTER = 5

    @Volatile var voices = true

    fun substantive(text: String): Boolean {
        val words = text.split(Regex("\\s+")).filter { w -> w.any { it.isLetter() } }
        if (words.size >= 3) return true
        return text.codePoints().filter { c ->
            Character.isIdeographic(c) || c in 0x3040..0x30FF || c in 0xAC00..0xD7A3
        }.count() >= 4
    }

    fun voiceNumbers(lines: List<TranscriptLine>): Map<Int, Int> {
        val count = HashMap<Int, Int>(); val reached = HashMap<Int, Int>()
        lines.forEachIndexed { i, l ->
            val v = l.voice
            if (l.speaker != "them" || v == null || !substantive(l.src)) return@forEachIndexed
            count[v] = (count[v] ?: 0) + 1
            if (count[v] == SHOWN_AFTER) reached[v] = i
        }
        val shown = reached.keys.sortedBy { reached[it] }
        if (shown.size < 2) return emptyMap()
        return shown.mapIndexed { i, v -> v to i + 1 }.toMap()
    }

    fun numbers(lines: List<TranscriptLine>): Map<String, Int> {
        if (!voices) return emptyMap()
        val number = voiceNumbers(lines)
        val out = HashMap<String, Int>()
        for (l in lines) if (l.speaker == "them") l.voice?.let { v -> number[v]?.let { out[l.id] = it } }
        return out
    }

    fun names(s: Session): Map<Int, String> {
        if (s.voiceNames == null && s.voiceGuesses == null) return emptyMap()
        val out = HashMap<Int, String>()
        for ((v, n) in voiceNumbers(s.lines)) {
            val mine = s.voiceNames?.get(v.toString())
            if (mine != null) { if (mine.isNotEmpty()) out[n] = mine }
            else s.voiceGuesses?.get(v.toString())?.let { out[n] = it.name }
        }
        return out
    }

    fun voiceOf(lines: List<TranscriptLine>, number: Int): Int? = voiceNumbers(lines).entries.firstOrNull { it.value == number }?.key

    fun label(number: Int, names: Map<Int, String>): String = names[number] ?: Strings.LF("说话人 %lld", number)

    fun named(notes: MeetingNotes, names: Map<Int, String>): MeetingNotes {
        val n = MeetingNotes.from(notes.toJson())
        if (names.isEmpty()) return n
        fun swap(text: String): String {
            if (!text.contains("说话人") && !text.contains("Speaker")) return text
            var out = text
            for ((k, name) in names.entries.sortedByDescending { it.key })
                for (form in listOf("说话人 $k", "说话人$k", "Speaker $k")) out = out.replace(form, name)
            return out
        }
        n.summary = swap(n.summary)
        for (t in n.topics) { t.title = swap(t.title); t.summary = swap(t.summary); t.points = t.points.map(::swap).toMutableList() }
        for (i in n.conclusions + n.todos) { i.text = swap(i.text); i.owner = i.owner?.let(::swap) }
        return n
    }

    fun saysWho(s: Session, numbers: Map<String, Int>): Boolean = s.sourceFile == null || numbers.isNotEmpty()

    fun speakerName(l: TranscriptLine, numbers: Map<String, Int>, names: Map<Int, String>): String {
        if (l.speaker == "me") return Strings.L("你 · 同传")
        numbers[l.id]?.let { return label(it, names) }
        return if (numbers.isEmpty()) Strings.L("对方") else Strings.L("未识别")
    }
}

object TranscriptExport {
    fun header(s: Session): String {
        val mins = (s.durationSeconds / 60).toInt()
        val at = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
            .withLocale(Strings.locale).withZone(ZoneId.systemDefault()).format(s.startedAt)
        return "$at · " + if (mins < 1) Strings.L("不到 1 分钟") else Strings.LF("%lld 分钟", mins)
    }

    fun notesMarkdown(n: MeetingNotes?): String {
        if (n == null || n.isEmpty) return ""
        val b = StringBuilder("## ${Strings.L("纪要")}\n\n${n.summary}\n\n")
        for (t in n.topics) {
            b.append("### ${Languages.clock(t.start)} ${t.title}\n\n")
            if (t.summary.isNotEmpty()) b.append("${t.summary}\n\n")
            for (p in t.points) b.append("- $p\n")
            t.fishbone?.let { f ->
                b.append("\n**${f.question}**\n\n")
                for (br in f.branches) b.append("- ${br.label}：${br.detail}\n")
            }
            b.append("\n")
        }
        if (n.conclusions.isNotEmpty()) b.append("### ${Strings.L("结论")}\n\n").append(n.conclusions.joinToString("") { "- ${it.text}\n" }).append("\n")
        if (n.todos.isNotEmpty()) b.append("### ${Strings.L("待办")}\n\n").append(n.todos.joinToString("") { "- [ ] ${it.withOwner}\n" }).append("\n")
        if (n.terms.isNotEmpty()) b.append("### ${Strings.L("人名和术语")}\n\n").append(n.terms.joinToString("") { "- **${it.name}** ${it.note}\n" }).append("\n")
        return b.toString()
    }

    fun markdown(s: Session): String {
        val b = StringBuilder("# ${SessionStore.displayTitle(s)}\n\n${header(s)}\n\n")
        val notes = notesMarkdown(s.notes)
        if (notes.isNotEmpty()) b.append(notes).append("## ${Strings.L("文字记录")}\n\n")
        val numbers = SpeakerLabels.numbers(s.lines); val names = SpeakerLabels.names(s)
        for (l in s.lines) {
            val who = if (SpeakerLabels.saysWho(s, numbers)) " ${SpeakerLabels.speakerName(l, numbers, names)}" else ""
            b.append("**[${Languages.clock(l.t)}]$who**  \n${l.shown}\n")
            l.dst?.takeIf { it != l.shown && it.isNotEmpty() }?.let { b.append("> $it\n") }
            b.append("\n")
        }
        return b.toString()
    }

    fun srt(s: Session): String {
        fun ts(t: Double): String {
            val ms = Math.round(maxOf(0.0, t) * 1000)
            return "%02d:%02d:%02d,%03d".format(ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        val b = StringBuilder()
        s.lines.forEachIndexed { i, l ->
            val next = if (i + 1 < s.lines.size) s.lines[i + 1].t else l.t + 4
            val end = maxOf(l.t + 1, minOf(next, l.t + 8))
            val tag = if (l.speaker == "me") "[${Strings.L("同传")}] " else ""
            b.append("${i + 1}\n${ts(l.t)} --> ${ts(end)}\n$tag${l.shown}\n")
            l.dst?.takeIf { it != l.shown && it.isNotEmpty() }?.let { b.append("$it\n") }
            b.append("\n")
        }
        return b.toString()
    }

    fun docx(s: Session): ByteArray {
        val body = StringBuilder()
        fun add(text: String, size: Double, bold: Boolean = false, color: String = "000000", after: Double = 4.0) {
            val esc = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            body.append("<w:p><w:pPr><w:spacing w:after=\"${(after * 20).toInt()}\"/></w:pPr><w:r><w:rPr>")
            if (bold) body.append("<w:b/>")
            body.append("<w:color w:val=\"$color\"/><w:sz w:val=\"${(size * 2).toInt()}\"/></w:rPr><w:t xml:space=\"preserve\">$esc</w:t></w:r></w:p>")
        }
        add(SessionStore.displayTitle(s), 20.0, bold = true, after = 6.0)
        add(header(s), 10.0, color = "555555", after = 14.0)
        val n = s.notes
        if (n != null && !n.isEmpty) {
            add(Strings.L("纪要"), 15.0, bold = true, after = 6.0)
            add(n.summary, 11.0, after = 10.0)
            for (t in n.topics) {
                add("${Languages.clock(t.start)}  ${t.title}", 12.0, bold = true, after = 3.0)
                if (t.summary.isNotEmpty()) add(t.summary, 11.0, color = "555555", after = 3.0)
                for (p in t.points) add("• $p", 11.0, after = 2.0)
                t.fishbone?.let { f ->
                    add(f.question, 11.0, bold = true, after = 2.0)
                    for (br in f.branches) add("  – ${br.label}：${br.detail}", 11.0, after = 2.0)
                }
                add("", 6.0, after = 4.0)
            }
            if (n.conclusions.isNotEmpty()) { add(Strings.L("结论"), 12.0, bold = true, after = 3.0); for (c in n.conclusions) add("• ${c.text}", 11.0, after = 2.0) }
            if (n.todos.isNotEmpty()) { add(Strings.L("待办"), 12.0, bold = true, after = 3.0); for (t in n.todos) add("☐ ${t.withOwner}", 11.0, after = 2.0) }
            add(Strings.L("文字记录"), 15.0, bold = true, after = 6.0)
        }
        val numbers = SpeakerLabels.numbers(s.lines); val names = SpeakerLabels.names(s)
        for (l in s.lines) {
            add("[${Languages.clock(l.t)}]" + if (SpeakerLabels.saysWho(s, numbers)) " ${SpeakerLabels.speakerName(l, numbers, names)}" else "", 9.0, bold = true, color = "555555", after = 2.0)
            add(l.shown, 11.0, after = 2.0)
            l.dst?.takeIf { it != l.shown && it.isNotEmpty() }?.let { add(it, 11.0, color = "4D4D4D", after = 10.0) }
        }
        val doc = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" +
            "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>$body" +
            "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\"/></w:sectPr></w:body></w:document>"
        val types = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" +
            "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" +
            "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" +
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
            "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>"
        val rels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" +
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
            "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { z ->
            for ((name, text) in listOf("[Content_Types].xml" to types, "_rels/.rels" to rels, "word/document.xml" to doc)) {
                z.putNextEntry(ZipEntry(name)); z.write(text.toByteArray(Charsets.UTF_8)); z.closeEntry()
            }
        }
        return out.toByteArray()
    }

    fun fileName(s: Session, ext: String) = SessionStore.displayTitle(s).replace(Regex("[\\\\/:*?\"<>|]"), "-") + "." + ext
}
