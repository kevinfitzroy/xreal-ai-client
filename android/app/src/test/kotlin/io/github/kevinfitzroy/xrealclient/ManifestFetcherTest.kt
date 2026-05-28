package io.github.kevinfitzroy.xrealclient

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** [ManifestFetcher.parseManifest] 的边界:版本校验、非法项目跳过、坏 JSON、空清单。 */
class ManifestFetcherTest {

    @Test fun parses_valid_manifest() {
        val json = """
            { "version": 1, "projects": [
              { "session": "maestro", "name": "Maestro", "type": "maestro", "dir": "/h" },
              { "session": "demo", "name": "演示", "type": "claude" },
              { "session": "logs", "type": "ssh" }
            ] }
        """.trimIndent()
        val p = ManifestFetcher.parseManifest(json, "h")!!
        assertEquals(3, p.size)
        assertEquals(ProjectType.MAESTRO, p[0].type)
        assertEquals("演示", p[1].displayName)
        assertEquals("logs", p[2].displayName)   // 无 name → 回退 session
    }

    @Test fun version_mismatch_returns_null() {
        assertNull(ManifestFetcher.parseManifest("""{ "version": 2, "projects": [] }""", "h"))
    }

    @Test fun malformed_json_returns_null() {
        assertNull(ManifestFetcher.parseManifest("not json", "h"))
        assertNull(ManifestFetcher.parseManifest("", "h"))
    }

    @Test fun skips_invalid_projects_keeps_valid() {
        val json = """
            { "version": 1, "projects": [
              { "session": "ok", "type": "claude" },
              { "session": "bad type", "type": "claude" },
              { "session": "weird", "type": "nope" },
              { "type": "ssh" }
            ] }
        """.trimIndent()
        val p = ManifestFetcher.parseManifest(json, "h")!!
        assertEquals(1, p.size)            // 只 "ok" 合法(session 含空格/未知 type/缺 session 都跳过)
        assertEquals("ok", p[0].sessionName)
    }

    @Test fun empty_projects_is_empty_not_null() {
        val p = ManifestFetcher.parseManifest("""{ "version": 1, "projects": [] }""", "h")
        assertEquals(emptyList<ProjectConfig>(), p)
    }
}
