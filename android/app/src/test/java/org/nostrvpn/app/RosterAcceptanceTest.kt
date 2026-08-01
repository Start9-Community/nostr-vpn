package org.nostrvpn.app

import org.junit.Assert.assertEquals
import org.junit.Test
import org.nostrvpn.app.core.parseAppState

class RosterAcceptanceTest {
    @Test
    fun productionJsonKeepsAcceptedRosterDuringTransientReconnect() {
        val participant = parseAppState(
            """{"networks":[{"participants":[{
                "npub":"npub1accepted",
                "rosterAccepted":true,
                "state":"pending"
            }]}]}""",
        ).networks.single().participants.single()

        assertEquals("accepted", rosterAcceptance(participant))
    }

    @Test
    fun productionJsonKeepsUnconfirmedRosterPendingWhenTransportIsReachable() {
        val participant = parseAppState(
            """{"networks":[{"participants":[{
                "npub":"npub1pending",
                "rosterAccepted":false,
                "reachable":true,
                "state":"online"
            }]}]}""",
        ).networks.single().participants.single()

        assertEquals("pending", rosterAcceptance(participant))
    }
}
