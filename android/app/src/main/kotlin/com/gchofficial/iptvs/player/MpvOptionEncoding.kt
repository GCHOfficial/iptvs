package com.gchofficial.iptvs.player

/**
 * Pure encoding for mpv string-list options (e.g. `http-header-fields`), kept
 * free of Android/JNI imports so it's covered by a plain-JUnit test rather
 * than an instrumented one — see [ReconnectPolicy] for the same pattern.
 *
 * The libmpv binding here only exposes `setOptionString`/`setPropertyString`
 * (raw strings), never a native list/array setter, so a list-typed option has
 * to be serialized as mpv's own comma-separated string syntax. Naively
 * joining items with `,` corrupts any item whose value itself contains a
 * literal comma (e.g. a `User-Agent: ... (X11, Linux)` or a multi-pair
 * Cookie header) — mpv's list parser treats every comma as a separator.
 */
object MpvOptionEncoding {
    /**
     * Encodes [items] as an mpv string-list option value using mpv's `%n%`
     * raw-length quoting (mpv manual, "Escaping option values"): each item
     * becomes `%<byte-length>%<item>`, then the items are comma-joined. mpv
     * reads exactly the declared number of bytes for an `%n%`-quoted item
     * before looking for the next separator, so a comma (or any other
     * character) inside the item can never be misread as the list separator —
     * unlike plain comma-joining. `n` MUST be the item's UTF-8 byte length,
     * not its char count, or a multi-byte value gets truncated/misaligned.
     */
    fun encodeListOption(items: List<String>): String = items.joinToString(",") { rawQuote(it) }

    /** Convenience for header maps: formats each entry as `Key: Value` first. */
    fun encodeHeaderFields(headers: List<Pair<String, String>>): String =
        encodeListOption(headers.map { (key, value) -> "$key: $value" })

    private fun rawQuote(value: String): String {
        val byteLength = value.toByteArray(Charsets.UTF_8).size
        return "%$byteLength%$value"
    }
}
