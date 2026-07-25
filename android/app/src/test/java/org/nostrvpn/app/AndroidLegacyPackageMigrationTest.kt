package org.nostrvpn.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AndroidLegacyPackageMigrationTest {
    @Test
    fun canonicalAppRequiresRemovalOfLegacyPackage() {
        assertEquals(
            AndroidLegacyPackageMigration.LEGACY_PACKAGE_NAME,
            AndroidLegacyPackageMigration.packageToRemove(
                currentPackageName = "fi.siriusbusiness.nvpn",
                installedPackageNames = setOf(
                    "fi.siriusbusiness.nvpn",
                    AndroidLegacyPackageMigration.LEGACY_PACKAGE_NAME,
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
    fun legacyBuildNeverAttemptsToRemoveItself() {
        assertNull(
            AndroidLegacyPackageMigration.packageToRemove(
                currentPackageName = AndroidLegacyPackageMigration.LEGACY_PACKAGE_NAME,
                installedPackageNames = setOf(AndroidLegacyPackageMigration.LEGACY_PACKAGE_NAME),
            ),
        )
    }
}
