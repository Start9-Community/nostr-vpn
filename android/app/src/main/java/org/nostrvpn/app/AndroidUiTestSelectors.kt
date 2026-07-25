package org.nostrvpn.app

import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId

internal fun Modifier.mobileUiSelector(
    id: String,
    description: String,
): Modifier =
    testTag(id).semantics {
        contentDescription = description
    }

internal fun Modifier.exposeMobileUiSelectors(): Modifier =
    semantics {
        testTagsAsResourceId = true
    }
