package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MpvOptionEncodingTest {
    @Test
    fun `simple headers are length-prefixed but read the same value back`() {
        val encoded = MpvOptionEncoding.encodeHeaderFields(listOf("X-Custom" to "abc"))

        // "X-Custom: abc" is 13 bytes.
        assertEquals("%13%X-Custom: abc", encoded)
    }

    @Test
    fun `a comma-containing value round-trips instead of being split`() {
        val userAgent = "Mozilla/5.0 (X11, Linux)"
        val entry = "User-Agent: $userAgent"
        val encoded = MpvOptionEncoding.encodeHeaderFields(listOf("User-Agent" to userAgent))

        val expectedLength = entry.toByteArray(Charsets.UTF_8).size
        assertEquals("%$expectedLength%$entry", encoded)

        // The comma inside the value must not have produced a second,
        // naively-split list item: there is exactly one `%n%` item here.
        assertEquals(1, encoded.count { it == '%' } / 2)
    }

    @Test
    fun `multiple headers join with a comma separator between quoted items`() {
        val encoded = MpvOptionEncoding.encodeHeaderFields(
            listOf("A" to "1, 2", "B" to "3"),
        )

        val firstEntry = "A: 1, 2"
        val secondEntry = "B: 3"
        val expected =
            "%${firstEntry.toByteArray(Charsets.UTF_8).size}%$firstEntry" +
                "," +
                "%${secondEntry.toByteArray(Charsets.UTF_8).size}%$secondEntry"
        assertEquals(expected, encoded)
    }

    @Test
    fun `multi-byte UTF-8 value is prefixed with byte length, not char length`() {
        // "é" is 1 char but 2 bytes in UTF-8; "Header: é" is 9 chars / 10 bytes.
        val entry = "Header: é"
        val encoded = MpvOptionEncoding.encodeHeaderFields(listOf("Header" to "é"))

        assertTrue(entry.length != entry.toByteArray(Charsets.UTF_8).size)
        assertEquals("%${entry.toByteArray(Charsets.UTF_8).size}%$entry", encoded)
        assertEquals("%10%$entry", encoded)
    }

    @Test
    fun `empty header list encodes to an empty string`() {
        assertEquals("", MpvOptionEncoding.encodeListOption(emptyList()))
        assertEquals("", MpvOptionEncoding.encodeHeaderFields(emptyList()))
    }
}
