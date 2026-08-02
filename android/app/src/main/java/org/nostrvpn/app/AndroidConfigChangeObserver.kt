package org.nostrvpn.app

import android.os.FileObserver
import java.io.File

internal class AndroidConfigChangeObserver(
    private val configFile: File,
    private val onChanged: () -> Unit,
) {
    private val contents = ConfigContents(
        configFile.takeIf(File::isFile)?.let { runCatching(it::readBytes).getOrNull() },
    )

    @Suppress("DEPRECATION")
    private val observer =
        object : FileObserver(
            configFile.parentFile?.absolutePath.orEmpty(),
            CLOSE_WRITE or MOVED_TO,
        ) {
            override fun onEvent(event: Int, path: String?) {
                if (path != configFile.name) return
                val current = runCatching { configFile.readBytes() }.getOrNull() ?: return
                if (contents.replaceIfChanged(current)) {
                    onChanged()
                }
            }
        }

    fun start() = observer.startWatching()

    fun stop() = observer.stopWatching()
}

internal class ConfigContents(initial: ByteArray?) {
    private var value = initial?.copyOf()

    @Synchronized
    fun replaceIfChanged(current: ByteArray): Boolean {
        if (value?.contentEquals(current) == true) return false
        value = current.copyOf()
        return true
    }
}
