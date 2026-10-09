package dev.bridge.companion

import org.junit.Assert.*
import org.junit.Test

class NotificationReplyPolicyTest {
    @Test fun preservesUnicodeMultilineAndExactByteBoundary() {
        assertTrue(NotificationReplyPolicy.validText("Hello 👋\nSecond line"))
        assertTrue(NotificationReplyPolicy.validText("a".repeat(4096)))
        assertTrue(NotificationReplyPolicy.validText("👋".repeat(1024)))
        assertFalse(NotificationReplyPolicy.validText("a".repeat(4097)))
        assertFalse(NotificationReplyPolicy.validText("👋".repeat(1025)))
    }
    @Test fun rejectsBlankAndNulWithoutChangingUserText() {
        for (invalid in listOf("", " \n\t", "hi\u0000")) assertFalse(NotificationReplyPolicy.validText(invalid))
        val text = "  Hello 👋\nWorld  "
        val message = Message("notificationReply", payload("key" to "key", "actionID" to "token", "text" to text))
        assertEquals(text, Message.read(message.encode().inputStream())!!.payload.getString("text"))
    }
    @Test fun leaseCannotReplayAfterConsumptionAndExpiryDoesNotDispatch() {
        val lease = NotificationActionLease(1000)
        assertTrue(lease.usable(1001))
        assertTrue(lease.consume(1001))
        assertFalse(lease.consume(1002))
        assertFalse(lease.usable(1002))
        val expired = NotificationActionLease(1000)
        assertFalse(expired.consume(301000))
        assertFalse(expired.consume(301001))
    }
    @Test fun actionExpiresAtFiveMinutesAndRejectsClockReversal() {
        assertTrue(NotificationReplyPolicy.fresh(1000, 1000))
        assertTrue(NotificationReplyPolicy.fresh(1000, 300999))
        assertFalse(NotificationReplyPolicy.fresh(1000, 301000))
        assertFalse(NotificationReplyPolicy.fresh(1000, 999))
    }
}
