package org.nostrvpn.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidLegacyPackageMigrationTest {
    @Test
    fun canonicalAppRequiresRemovalOfEveryRetiredPackageInStableOrder() {
        assertEquals(
            AndroidLegacyPackageMigration.RETIRED_PACKAGE_NAMES,
            AndroidLegacyPackageMigration.packagesToRemove(
                currentPackageName = "fi.siriusbusiness.nvpn",
                installedPackageNames = setOf(
                    "fi.siriusbusiness.nvpn",
                    "fi.siriusbusiness.nvpn.test",
                    "fi.siriusbusiness.nvpn.mobileexit",
                    "fi.siriusbusiness.nvpn.releasegate",
                    "fi.siriusbusiness.nvpn.debug",
                    "fi.siriusbusiness.nvpn.joine2e",
                    "org.nostrvpn.app",
                ),
            ),
        )
    }

    @Test
    fun canonicalAppDoesNotPromptWithoutLegacyPackage() {
        assertNull(
            AndroidLegacyPackageMigration.packageToRemove(
                currentPackageName = "fi.siriusbusiness.nvpn",
                installedPackageNames = setOf("fi.siriusbusiness.nvpn"),
            ),
        )
    }

    @Test
    fun retiredBuildNeverAttemptsToRemoveItself() {
        for (packageName in AndroidLegacyPackageMigration.RETIRED_PACKAGE_NAMES) {
            assertFalse(
                AndroidLegacyPackageMigration.packagesToRemove(
                    currentPackageName = packageName,
                    installedPackageNames = AndroidLegacyPackageMigration.RETIRED_PACKAGE_NAMES.toSet(),
                ).contains(packageName),
            )
        }
    }

    @Test
    fun vpnStartIsBlockedUntilEveryRetiredPackageIsGone() {
        assertFalse(
            AndroidLegacyPackageMigration.vpnStartAllowed(
                currentPackageName = "fi.siriusbusiness.nvpn",
                installedPackageNames = setOf(
                    "fi.siriusbusiness.nvpn",
                    "fi.siriusbusiness.nvpn.mobileexit",
                ),
            ),
        )
        assertTrue(
            AndroidLegacyPackageMigration.vpnStartAllowed(
                currentPackageName = "fi.siriusbusiness.nvpn",
                installedPackageNames = setOf("fi.siriusbusiness.nvpn"),
            ),
        )
    }
}
