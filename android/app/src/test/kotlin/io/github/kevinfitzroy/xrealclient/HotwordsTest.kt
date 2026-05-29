package io.github.kevinfitzroy.xrealclient

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** [Hotwords] 纯函数:merge 去重 + cap 字符预算。 */
class HotwordsTest {

    @Test fun `merge prepends BASE and dedups case-insensitively keeping first form`() {
        val merged = Hotwords.merge(listOf("compact", "Docker", "docker", "kubectl"))
        // BASE 里已有 "compact" → project 的 "compact" 被去掉
        assertEquals(1, merged.count { it.equals("compact", ignoreCase = true) })
        // "Docker"/"docker" 只留首次出现的 "Docker"
        assertTrue(merged.contains("Docker"))
        assertFalse(merged.contains("docker"))
        assertEquals(1, merged.count { it.equals("docker", ignoreCase = true) })
        assertTrue(merged.contains("kubectl"))
        // BASE 全部在前
        assertEquals(Hotwords.BASE, merged.take(Hotwords.BASE.size))
    }

    @Test fun `merge trims and drops blanks`() {
        val merged = Hotwords.merge(listOf("  spaced  ", "", "   "))
        assertTrue(merged.contains("spaced"))
        assertFalse(merged.any { it.isBlank() })
    }

    @Test fun `cap keeps words within char budget and stops at first overflow`() {
        // size=10:每词 4 字符 + 1 = 5 → budget 10 恰好 2 个,第 3 个溢出
        val capped = Hotwords.cap(listOf("aaaa", "bbbb", "cccc"), budget = 10)
        assertEquals(listOf("aaaa", "bbbb"), capped)
    }

    @Test fun `cap boundary - word that exactly fills budget is kept`() {
        // "aaaa"(4+1=5)+"bb"(2+1=3)=8 ≤ 10,第三 "c"(1+1=2)=10 ≤ 10 仍留,第四 "d" 溢出
        val capped = Hotwords.cap(listOf("aaaa", "bb", "c", "d"), budget = 10)
        assertEquals(listOf("aaaa", "bb", "c"), capped)
    }

    @Test fun `cap empty input`() {
        assertTrue(Hotwords.cap(emptyList()).isEmpty())
    }

    @Test fun `BASE fits default budget`() {
        // BASE 应整体在 200 字符预算内(否则后面的词会被默默截掉)
        assertEquals(Hotwords.BASE, Hotwords.cap(Hotwords.BASE))
    }
}
