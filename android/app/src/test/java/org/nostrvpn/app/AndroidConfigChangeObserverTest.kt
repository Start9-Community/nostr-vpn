package org.nostrvpn.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidConfigChangeObserverTest {
    @Test
    fun wakesOnlyWhenTheDurableConfigContentsChange() {
        val contents = ConfigContents("pending".toByteArray())

        assertFalse(contents.replaceIfChanged("pending".toByteArray()))
        assertTrue(contents.replaceIfChanged("accepted".toByteArray()))
        assertFalse(contents.replaceIfChanged("accepted".toByteArray()))
    }
}
