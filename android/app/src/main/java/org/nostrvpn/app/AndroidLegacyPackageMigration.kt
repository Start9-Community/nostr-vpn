package org.nostrvpn.app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build

internal object AndroidLegacyPackageMigration {
    const val LEGACY_PACKAGE_NAME = "org.nostrvpn.app"

    fun packageToRemove(currentPackageName: String, installedPackageNames: Set<String>): String? {
        if (currentPackageName == LEGACY_PACKAGE_NAME) {
            return null
        }
        return LEGACY_PACKAGE_NAME.takeIf(installedPackageNames::contains)
    }

    fun packageToRemove(context: Context): String? =
        packageToRemove(
            currentPackageName = context.packageName,
            installedPackageNames = buildSet {
                if (context.packageManager.hasPackage(LEGACY_PACKAGE_NAME)) {
                    add(LEGACY_PACKAGE_NAME)
                }
            },
        )

    fun uninstallIntent(packageName: String): Intent =
        Intent(Intent.ACTION_DELETE, Uri.parse("package:$packageName"))
            .putExtra(Intent.EXTRA_RETURN_RESULT, true)

    private fun PackageManager.hasPackage(packageName: String): Boolean =
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                getPackageInfo(packageName, 0)
            }
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
}
