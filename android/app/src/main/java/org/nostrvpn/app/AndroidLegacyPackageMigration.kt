package org.nostrvpn.app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build

internal object AndroidLegacyPackageMigration {
    val RETIRED_PACKAGE_NAMES = listOf(
        "org.nostrvpn.app",
        "fi.siriusbusiness.nvpn.releasegate",
        "fi.siriusbusiness.nvpn.mobileexit",
        "fi.siriusbusiness.nvpn.joine2e",
        "fi.siriusbusiness.nvpn.debug",
        "fi.siriusbusiness.nvpn.test",
    )

    fun packagesToRemove(
        currentPackageName: String,
        installedPackageNames: Set<String>,
    ): List<String> =
        RETIRED_PACKAGE_NAMES.filter { packageName ->
            packageName != currentPackageName && packageName in installedPackageNames
        }

    fun packageToRemove(
        currentPackageName: String,
        installedPackageNames: Set<String>,
    ): String? =
        packagesToRemove(currentPackageName, installedPackageNames).firstOrNull()

    fun vpnStartAllowed(
        currentPackageName: String,
        installedPackageNames: Set<String>,
    ): Boolean =
        packagesToRemove(currentPackageName, installedPackageNames).isEmpty()

    fun packagesToRemove(context: Context): List<String> =
        packagesToRemove(
            currentPackageName = context.packageName,
            installedPackageNames = RETIRED_PACKAGE_NAMES
                .filterTo(linkedSetOf()) { packageName ->
                    context.packageManager.hasPackage(packageName)
                },
        )

    fun packageToRemove(context: Context): String? =
        packagesToRemove(context).firstOrNull()

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
