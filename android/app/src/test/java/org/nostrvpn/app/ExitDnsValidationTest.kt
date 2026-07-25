package org.nostrvpn.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ExitDnsValidationTest {
    @Test
    fun everyDnsModeRequiresOnlyItsActiveFields() {
        assertNull(exitDnsValidationError("automatic", "custom", "", "", ""))
        assertNull(exitDnsValidationError("encrypted", "cloudflare", "", "", ""))
        assertNull(exitDnsValidationError("encrypted", "quad9", "", "", ""))
        assertEquals(
            "Enter an HTTPS DoH URL.",
            exitDnsValidationError("encrypted", "custom", "", "", ""),
        )
        assertEquals(
            "DoH URL must use HTTPS.",
            exitDnsValidationError(
                "encrypted",
                "custom",
                "http://resolver.example/dns-query",
                "192.0.2.53",
                "",
            ),
        )
        assertEquals(
            "Enter at least one bootstrap IP.",
            exitDnsValidationError(
                "encrypted",
                "custom",
                "https://resolver.example/dns-query",
                "",
                "",
            ),
        )
        assertNull(
            exitDnsValidationError(
                "encrypted",
                "custom",
                "https://resolver.example/dns-query",
                "192.0.2.53",
                "",
            ),
        )
        assertEquals(
            "Enter at least one DNS server IP.",
            exitDnsValidationError("through_exit", "cloudflare", "", "", ""),
        )
        assertNull(
            exitDnsValidationError(
                "through_exit",
                "cloudflare",
                "",
                "",
                "9.9.9.9",
            ),
        )
    }
}
