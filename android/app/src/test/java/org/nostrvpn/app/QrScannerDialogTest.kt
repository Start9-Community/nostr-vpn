package org.nostrvpn.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class QrScannerDialogTest {
    @Test
    fun firstQrPayloadUsesFirstNonBlankDecodedValue() {
        assertEquals(
            "nvpn://join/example",
            firstQrPayload(listOf(null, "  ", "  nvpn://join/example  ", "ignored")),
        )
    }

    @Test
    fun firstQrPayloadRejectsImagesWithoutDecodedContent() {
        assertNull(firstQrPayload(listOf(null, "", " \n\t ")))
    }
}
