package dev.grassbag.grassbag

import android.system.Os
import android.system.OsConstants
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.util.zip.GZIPInputStream

/**
 * Pure-Kotlin streaming USTAR / PAX / GNU tar.gz extractor tailored for Android unprivileged
 * Linux rootfs & Node/DSH bundles:
 *  - Verifies SHA-256 on the compressed stream in a single pass (zero extra disk copy!)
 *  - Preserves POSIX symlinks, hardlinks, and executable permissions via `android.system.Os`
 *  - Safely skips char/block/fifo device nodes (PRoot bind-mounts Android's real `/dev`)
 *  - Reports compressed-byte extraction progress smoothly for UI onboarding bars
 */
object TarGzExtractor {

    private class CountingDigestInputStream(
        input: InputStream,
        private val digest: MessageDigest,
        private val totalBytes: Long,
        private val onProgress: ((Long, Long) -> Unit)?
    ) : FilterInputStream(input) {
        var bytesRead: Long = 0
            private set
        private var lastReported: Long = 0

        override fun read(): Int {
            val b = super.read()
            if (b >= 0) {
                digest.update(b.toByte())
                bytesRead++
                maybeReport()
            }
            return b
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            val n = super.read(b, off, len)
            if (n > 0) {
                digest.update(b, off, n)
                bytesRead += n
                maybeReport()
            }
            return n
        }

        private fun maybeReport() {
            if (onProgress != null && bytesRead - lastReported >= 512 * 1024) {
                lastReported = bytesRead
                onProgress.invoke(bytesRead, totalBytes)
            }
        }
    }

    fun extractStream(
        compressedStream: InputStream,
        destDir: File,
        expectedSha256: String = "",
        totalCompressedBytes: Long = 0L,
        freshDir: Boolean = false,
        onProgress: ((bytesRead: Long, totalBytes: Long) -> Unit)? = null
    ) {
        destDir.mkdirs()
        val canonicalRoot = destDir.canonicalFile
        val rootPrefix = canonicalRoot.path + File.separator
        val digest = MessageDigest.getInstance("SHA-256")
        val counting = CountingDigestInputStream(
            BufferedInputStream(compressedStream, 131072),
            digest,
            totalCompressedBytes,
            onProgress
        )

        val deferredHardlinks = ArrayList<Pair<File, File>>()
        val verifiedParents = HashSet<String>(512)
        verifiedParents.add(canonicalRoot.path)
        val createdSymlinks = HashSet<String>(64)
        val header = ByteArray(512)
        val ioBuf = ByteArray(131072)

        var pendingLongName: String? = null
        var pendingLongLink: String? = null
        var paxPath: String? = null
        var paxLinkPath: String? = null
        var paxSize: Long? = null

        try {
            GZIPInputStream(counting, 131072).use { tar ->
                while (true) {
                    val readHeader = readFully(tar, header, 0, 512)
                    if (readHeader < 512) break
                    if (isAllZero(header)) break

                    val typeFlag = header[156].toInt().toChar()
                    val rawName = readTarString(header, 0, 100)
                    val prefix = readTarString(header, 345, 155)
                    val baseName = if (prefix.isNotEmpty()) "$prefix/$rawName" else rawName
                    val rawLink = readTarString(header, 157, 100)
                    val mode = parseOctal(header, 100, 8).toInt()
                    val rawSize = parseOctal(header, 124, 12)

                    when (typeFlag) {
                        'L' -> {
                            pendingLongName = readPayloadString(tar, rawSize)
                            skipPadding(tar, rawSize)
                            continue
                        }
                        'K' -> {
                            pendingLongLink = readPayloadString(tar, rawSize)
                            skipPadding(tar, rawSize)
                            continue
                        }
                        'x', 'g' -> {
                            val pax = parsePaxHeaders(readPayloadBytes(tar, rawSize))
                            skipPadding(tar, rawSize)
                            if (typeFlag == 'x') {
                                pax["path"]?.let { paxPath = it }
                                pax["linkpath"]?.let { paxLinkPath = it }
                                pax["size"]?.let { rawPaxSize ->
                                    val parsed = rawPaxSize.toLongOrNull()
                                        ?: throw IOException("Invalid PAX size header: $rawPaxSize")
                                    if (parsed < 0L) {
                                        throw IOException("Negative PAX entry size: $parsed")
                                    }
                                    paxSize = parsed
                                }
                            }
                            continue
                        }
                    }

                    val size = paxSize ?: rawSize
                    if (size < 0L) {
                        throw IOException("Invalid negative tar entry size: $size")
                    }

                    val effectiveName = sanitizeRelativePath(paxPath ?: pendingLongName ?: baseName)
                    val effectiveLink = paxLinkPath ?: pendingLongLink ?: rawLink

                    pendingLongName = null
                    pendingLongLink = null
                    paxPath = null
                    paxLinkPath = null
                    paxSize = null

                    if (effectiveName == null) {
                        skipFully(tar, size)
                        skipPadding(tar, size)
                        continue
                    }

                    val targetFile = File(canonicalRoot, effectiveName)
                    fun verifyParentContained(file: File, requireDirExists: Boolean = false) {
                        val parent = file.parentFile ?: return
                        val parentRawPath = parent.path
                        if (verifiedParents.contains(parentRawPath) && (!requireDirExists || parent.isDirectory)) {
                            return
                        }
                        if (requireDirExists && !parent.isDirectory) {
                            parent.mkdirs()
                        }
                        val parentCanon = parent.canonicalFile
                        if (parentCanon.path != canonicalRoot.path &&
                            !parentCanon.path.startsWith(rootPrefix)
                        ) {
                            throw IOException("Tar entry parent escapes destination: $effectiveName")
                        }
                        if (parent.isDirectory && parentCanon.path == parentRawPath) {
                            verifiedParents.add(parentRawPath)
                        }
                    }
                    verifyParentContained(targetFile)

                    when (typeFlag) {
                        '5' -> {
                            targetFile.mkdirs()
                            val targetCanon = targetFile.canonicalFile
                            if (targetCanon.path != canonicalRoot.path && !targetCanon.path.startsWith(rootPrefix)) {
                                throw IOException("Tar directory escapes destination: $effectiveName")
                            }
                            if (targetFile.isDirectory && targetCanon.path == targetFile.path) {
                                verifiedParents.add(targetFile.path)
                            }
                            if (!freshDir || (mode and 0xE00) != 0) {
                                runCatching { Os.chmod(targetFile.absolutePath, (mode and 0xFFF) or 0x1C0) }
                            }
                            skipFully(tar, size)
                        }
                        '2' -> {
                            verifyParentContained(targetFile, requireDirExists = true)
                            removeEntry(targetFile)
                            Os.symlink(effectiveLink, targetFile.absolutePath)
                            val symPath = targetFile.path
                            createdSymlinks.add(symPath)
                            val symParentCanon = targetFile.parentFile?.canonicalFile
                            if (symParentCanon != null) {
                                createdSymlinks.add(File(symParentCanon, targetFile.name).path)
                            }
                            // Clear all cached parent paths (retaining only canonicalRoot) so no symlink
                            // alias or replacement anywhere in the tree can bypass containment checks.
                            verifiedParents.clear()
                            verifiedParents.add(canonicalRoot.path)
                            skipFully(tar, size)
                        }
                        '1' -> {
                            val linkRel = sanitizeRelativePath(effectiveLink)
                            if (linkRel != null) {
                                val linkTarget = File(canonicalRoot, linkRel)
                                verifyParentContained(targetFile, requireDirExists = true)
                                removeEntry(targetFile)
                                if (linkTarget.exists()) {
                                    val srcLstat = runCatching { Os.lstat(linkTarget.absolutePath) }.getOrNull()
                                    val srcIsSymlink = srcLstat != null && android.system.OsConstants.S_ISLNK(srcLstat.st_mode)
                                    val srcCanon = linkTarget.canonicalFile
                                    if (!srcIsSymlink && (srcCanon.path == canonicalRoot.path || srcCanon.path.startsWith(rootPrefix))) {
                                        linkOrCopy(linkTarget, targetFile)
                                    }
                                } else {
                                    deferredHardlinks.add(linkTarget to targetFile)
                                }
                            }
                            skipFully(tar, size)
                        }
                        '0', '\u0000' -> {
                            verifyParentContained(targetFile, requireDirExists = true)
                            // On fresh empty target dirs, skip ~60k Os.lstat ENOENT throws ONLY when
                            // the parent is a verified real (non-symlink-aliased) directory AND no
                            // symlink or directory was previously created at this path in the archive.
                            val parentHasSymlinkAlias = targetFile.parentFile?.let { !verifiedParents.contains(it.path) } ?: false
                            val mayCollideWithSymlink = createdSymlinks.isNotEmpty() &&
                                (parentHasSymlinkAlias || createdSymlinks.contains(targetFile.path))
                            if (!freshDir || mayCollideWithSymlink || targetFile.isDirectory) {
                                val existingStat = runCatching { Os.lstat(targetFile.absolutePath) }.getOrNull()
                                if (existingStat != null) {
                                    removeEntry(targetFile)
                                }
                            }
                            FileOutputStream(targetFile).use { fos ->
                                var remaining = size
                                while (remaining > 0) {
                                    val want = minOf(remaining, ioBuf.size.toLong()).toInt()
                                    val n = tar.read(ioBuf, 0, want)
                                    if (n <= 0) {
                                        throw IOException("Unexpected EOF while extracting $effectiveName ($remaining bytes remaining)")
                                    }
                                    fos.write(ioBuf, 0, n)
                                    remaining -= n
                                }
                            }
                            val safeMode = (mode and 0x1FF) or 0x180 // ensure owner rw
                            // On a fresh single-UID Android extraction, skip ~55k redundant chmod syscalls
                            // for ordinary non-executable regular files (already owner rw from FileOutputStream).
                            if (!freshDir || (safeMode and 0x49) != 0 || (mode and 0xE00) != 0) {
                                runCatching { Os.chmod(targetFile.absolutePath, safeMode) }
                            }
                        }
                        else -> {
                            // Skip char/block devices, fifos, PAX/Apple metadata headers cleanly
                            skipFully(tar, size, ioBuf)
                        }
                    }
                    skipPadding(tar, size, ioBuf)
                }
                // Drain remaining tar stream through GZIPInputStream first so GZIP trailer CRC32/ISIZE
                // is verified even when expectedSha256 is blank, then drain any remaining compressed bytes.
                while (tar.read(ioBuf) > 0) { /* verify gzip trailer */ }
                while (counting.read(ioBuf) > 0) { /* drain */ }
            }

            for ((src, dst) in deferredHardlinks) {
                if (src.exists()) {
                    val srcLstat = runCatching { Os.lstat(src.absolutePath) }.getOrNull()
                    val srcIsSymlink = srcLstat != null && android.system.OsConstants.S_ISLNK(srcLstat.st_mode)
                    val srcCanon = src.canonicalFile
                    val dstParentCanon = dst.parentFile?.canonicalFile
                    if (!srcIsSymlink &&
                        (srcCanon.path == canonicalRoot.path || srcCanon.path.startsWith(rootPrefix)) &&
                        (dstParentCanon == null || dstParentCanon.path == canonicalRoot.path || dstParentCanon.path.startsWith(rootPrefix))
                    ) {
                        dst.parentFile?.mkdirs()
                        removeEntry(dst)
                        linkOrCopy(src, dst)
                    }
                }
            }

            onProgress?.invoke(counting.bytesRead, totalCompressedBytes)

            if (expectedSha256.isNotBlank()) {
                val got = digest.digest().joinToString("") { "%02x".format(it) }
                if (!got.equals(expectedSha256, ignoreCase = true)) {
                    throw IOException("SHA-256 mismatch: expected=$expectedSha256 got=$got")
                }
            }
        } catch (t: Throwable) {
            // Never leave hundreds of MB of partial/corrupted files behind on ENOSPC or IO failure!
            if (freshDir) {
                runCatching { deleteTreeNoFollow(destDir) }
            }
            throw t
        }
    }

    /**
     * Symlink-safe recursive delete using `Os.lstat()` + `Os.remove()` so removing
     * Linux rootfs trees never follows symlinks outside the container directory.
     */
    fun deleteTreeNoFollow(target: File) {
        val st = runCatching { Os.lstat(target.absolutePath) }.getOrNull() ?: return
        val isDir = OsConstants.S_ISDIR(st.st_mode)
        if (isDir) {
            if ((st.st_mode and 0x1C0) != 0x1C0) {
                runCatching { Os.chmod(target.absolutePath, (st.st_mode and 0xFFF) or 0x1C0) }
            }
            val children = target.listFiles()
            if (children != null) {
                for (child in children) {
                    deleteTreeNoFollow(child)
                }
            }
        }
        runCatching { Os.remove(target.absolutePath) }.onFailure {
            runCatching { target.delete() }
        }
    }

    private fun linkOrCopy(src: File, dst: File) {
        val linked = runCatching {
            Os.link(src.absolutePath, dst.absolutePath)
            true
        }.getOrDefault(false)
        if (!linked) {
            src.inputStream().use { ins -> dst.outputStream().use { out -> ins.copyTo(out) } }
            val st = runCatching { Os.stat(src.absolutePath) }.getOrNull()
            val mode = ((st?.st_mode ?: 0x1A4) and 0x1FF) or 0x180
            runCatching { Os.chmod(dst.absolutePath, mode) }
        }
    }

    private fun removeEntry(file: File) {
        deleteTreeNoFollow(file)
    }

    private fun sanitizeRelativePath(raw: String): String? {
        if (raw.indexOf('\u0000') >= 0) return null
        var s = raw
        while (s.startsWith("./")) s = s.substring(2)
        while (s.startsWith("/")) s = s.substring(1)
        if (s.isEmpty() || s == ".") return null
        val parts = s.split('/').filter { it.isNotEmpty() && it != "." }
        if (parts.isEmpty() || parts.any { it == ".." }) return null
        return parts.joinToString("/")
    }

    private fun parsePaxHeaders(bytes: ByteArray): Map<String, String> {
        val map = HashMap<String, String>()
        var idx = 0
        while (idx < bytes.size) {
            var sp = idx
            while (sp < bytes.size && bytes[sp] != ' '.code.toByte()) sp++
            if (sp >= bytes.size) break
            val recLen = String(bytes, idx, sp - idx, Charsets.UTF_8).toIntOrNull() ?: break
            val bodyLen = (idx + recLen) - (sp + 1)
            if (recLen <= 0 || bodyLen <= 0 || idx + recLen > bytes.size) break
            val body = String(bytes, sp + 1, bodyLen, Charsets.UTF_8).trimEnd('\n')
            val eq = body.indexOf('=')
            if (eq > 0) {
                map[body.substring(0, eq)] = body.substring(eq + 1)
            }
            idx += recLen
        }
        return map
    }

    private const val MAX_METADATA_PAYLOAD_BYTES = 1024L * 1024L // 1 MiB safety cap for PAX/GNU headers

    private fun readPayloadBytes(ins: InputStream, size: Long): ByteArray {
        if (size < 0 || size > MAX_METADATA_PAYLOAD_BYTES) {
            throw IOException("Tar metadata payload size out of bounds: $size")
        }
        val out = ByteArrayOutputStream(size.toInt().coerceIn(0, 65536))
        val buf = ByteArray(4096)
        var rem = size
        while (rem > 0) {
            val n = ins.read(buf, 0, minOf(rem, buf.size.toLong()).toInt())
            if (n <= 0) break
            out.write(buf, 0, n)
            rem -= n
        }
        return out.toByteArray()
    }

    private fun readPayloadString(ins: InputStream, size: Long): String {
        val raw = readPayloadBytes(ins, size)
        var len = raw.size
        while (len > 0 && raw[len - 1].toInt() == 0) len--
        return String(raw, 0, len, Charsets.UTF_8)
    }

    private fun readTarString(buf: ByteArray, off: Int, len: Int): String {
        var end = off
        val max = off + len
        while (end < max && buf[end].toInt() != 0) end++
        return String(buf, off, end - off, Charsets.UTF_8)
    }

    private fun parseOctal(buf: ByteArray, off: Int, len: Int): Long {
        // Handle GNU base-256 binary size encoding (reject negative 0xFF two's complement sizes)
        if ((buf[off].toInt() and 0x80) != 0) {
            val lead = buf[off].toInt() and 0xFF
            if (lead != 0x80) {
                throw IOException("Unsupported or negative base-256 tar header value (0x${lead.toString(16)})")
            }
            var v = 0L
            for (i in 1 until len) {
                if (v > (Long.MAX_VALUE ushr 8)) {
                    throw IOException("Base-256 tar header value overflow")
                }
                v = (v shl 8) or (buf[off + i].toLong() and 0xFF)
            }
            if (v < 0L) {
                throw IOException("Negative base-256 tar header value")
            }
            return v
        }
        var result = 0L
        val max = off + len
        var i = off
        while (i < max && (buf[i] == ' '.code.toByte() || buf[i].toInt() == 0)) i++
        while (i < max && buf[i] in '0'.code.toByte()..'7'.code.toByte()) {
            result = (result shl 3) + (buf[i] - '0'.code.toByte())
            i++
        }
        return result
    }

    private fun readFully(ins: InputStream, buf: ByteArray, off: Int, len: Int): Int {
        var total = 0
        while (total < len) {
            val n = ins.read(buf, off + total, len - total)
            if (n <= 0) break
            total += n
        }
        return total
    }

    private fun skipFully(ins: InputStream, count: Long, scratch: ByteArray? = null) {
        var rem = count
        val buf = scratch ?: ByteArray(8192)
        while (rem > 0) {
            val n = ins.read(buf, 0, minOf(rem, buf.size.toLong()).toInt())
            if (n <= 0) break
            rem -= n
        }
    }

    private fun skipPadding(ins: InputStream, size: Long, scratch: ByteArray? = null) {
        val mod = (size % 512L)
        if (mod != 0L) skipFully(ins, 512L - mod, scratch)
    }

    private fun isAllZero(buf: ByteArray): Boolean {
        for (b in buf) if (b.toInt() != 0) return false
        return true
    }
}
