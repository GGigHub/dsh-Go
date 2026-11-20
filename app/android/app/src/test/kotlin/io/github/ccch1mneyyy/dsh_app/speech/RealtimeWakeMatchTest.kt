package io.github.ccch1mneyyy.dsh_app.speech

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RealtimeWakeMatchTest {
    @Test
    fun matchesExactAndWithPunctuation() {
        assertTrue(RealtimeWakeService.matchesWake("小助手", "小助手"))
        assertTrue(RealtimeWakeService.matchesWake("嘿，小助手！", "小助手"))
        assertTrue(RealtimeWakeService.matchesWake("你好 小 助 手", "小助手"))
    }

    @Test
    fun rejectsUnrelated() {
        assertFalse(RealtimeWakeService.matchesWake("今天天气怎么样", "小助手"))
        assertFalse(RealtimeWakeService.matchesWake("", "小助手"))
        assertFalse(RealtimeWakeService.matchesWake("小助手", ""))
    }
}
