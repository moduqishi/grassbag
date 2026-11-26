package dev.grassbag.grassbag

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.system.Os
import android.system.OsConstants
import android.util.Base64
import android.util.Log
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

class KeystoreVault(ctx: Context) {
    private val appCtx = ctx.applicationContext
    private val store = appCtx.getSharedPreferences("gb_vault_v1", Context.MODE_PRIVATE)
    private val rng = SecureRandom()
    @Volatile
    private var cachedKey: SecretKey? = null

    @Synchronized
    private fun masterKey(forceRegenerate: Boolean = false): SecretKey {
        if (!forceRegenerate) {
            cachedKey?.let { return it }
        }
        val ksKey = runCatching {
            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            if (forceRegenerate) {
                runCatching { ks.deleteEntry(ALIAS) }
            } else {
                (ks.getKey(ALIAS, null) as? SecretKey)?.let { return@runCatching it }
            }
            val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            gen.init(
                KeyGenParameterSpec.Builder(
                    ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build()
            )
            gen.generateKey()
        }.onFailure { err ->
            Log.w("GrassBagVault", "AndroidKeyStore unavailable (${err.javaClass.simpleName}): falling back to private 0600 AES key")
        }.getOrNull()

        if (ksKey != null) {
            cachedKey = ksKey
            return ksKey
        }
        // Never poison cachedKey with the fallback key on a transient AndroidKeyStore hiccup:
        // leaving cachedKey null allows subsequent reads to retry AndroidKeyStore cleanly!
        return loadOrCreateFallbackKey()
    }

    @Synchronized
    private fun loadOrCreateFallbackKey(): SecretKey {
        val dir = runCatching { appCtx.noBackupFilesDir }.getOrNull() ?: appCtx.filesDir
        dir.mkdirs()
        val keyFile = File(dir, ".gb_vault_key_v1")
        if (keyFile.isFile && keyFile.length() == 32L) {
            val raw = runCatching { keyFile.readBytes() }.getOrNull()
            if (raw != null && raw.size == 32) {
                return SecretKeySpec(raw, "AES")
            }
        }
        val raw = ByteArray(32).also(rng::nextBytes)
        // Create atomically with mode 0600 + fsync + Os.rename (zero TOCTOU window, never return unsaved key).
        val tmpFile = File(dir, ".gb_vault_key_v1.tmp")
        val fd = Os.open(
            tmpFile.absolutePath,
            OsConstants.O_CREAT or OsConstants.O_WRONLY or OsConstants.O_TRUNC,
            0x180 // 0600
        )
        try {
            var written = 0
            while (written < raw.size) {
                val n = Os.write(fd, raw, written, raw.size - written)
                if (n <= 0) throw java.io.IOException("Short write while persisting vault fallback key")
                written += n
            }
            Os.fsync(fd)
        } catch (t: Throwable) {
            runCatching { tmpFile.delete() }
            throw t
        } finally {
            runCatching { Os.close(fd) }
        }
        Os.rename(tmpFile.absolutePath, keyFile.absolutePath)
        return SecretKeySpec(raw, "AES")
    }

    fun putSecret(k: String, v: String) {
        fun encryptWith(key: SecretKey): ByteArray {
            val cipher = Cipher.getInstance(ALG)
            cipher.init(Cipher.ENCRYPT_MODE, key)
            cipher.updateAAD(k.toByteArray(Charsets.UTF_8))
            val iv = cipher.iv
            val enc = cipher.doFinal(v.toByteArray(Charsets.UTF_8))
            val blob = ByteArray(1 + iv.size + enc.size)
            blob[0] = iv.size.toByte()
            iv.copyInto(blob, 1)
            enc.copyInto(blob, 1 + iv.size)
            return blob
        }
        val blob = runCatching { encryptWith(masterKey()) }.getOrElse { err ->
            // Regenerate AndroidKeyStore key ONLY when permanently invalidated/unrecoverable
            // (never wipe existing secrets on transient KeyStore errors!).
            val invalidated = err is android.security.keystore.KeyPermanentlyInvalidatedException ||
                err is java.security.UnrecoverableKeyException ||
                err.cause is android.security.keystore.KeyPermanentlyInvalidatedException ||
                err.cause is java.security.UnrecoverableKeyException
            cachedKey = null
            if (invalidated) {
                runCatching { encryptWith(masterKey(forceRegenerate = true)) }.getOrElse {
                    encryptWith(loadOrCreateFallbackKey())
                }
            } else {
                // Transient KeyStore error: use fallback key for this write WITHOUT permanently poisoning cachedKey,
                // so previously stored AndroidKeyStore secrets stay readable when KeyStore recovers!
                encryptWith(loadOrCreateFallbackKey())
            }
        }
        store.edit().putString(k, Base64.encodeToString(blob, Base64.NO_WRAP)).apply()
    }

    fun getSecret(k: String): String? {
        val b64 = store.getString(k, null) ?: return null
        val blob = runCatching { Base64.decode(b64, Base64.NO_WRAP) }.getOrNull() ?: return null
        if (blob.size < 2) return null
        val ivLen = blob[0].toInt() and 0xFF
        if (ivLen <= 0 || 1 + ivLen >= blob.size) return null
        val iv = blob.copyOfRange(1, 1 + ivLen)
        val enc = blob.copyOfRange(1 + ivLen, blob.size)

        fun tryDecrypt(key: SecretKey, withAad: Boolean): String? = runCatching {
            val cipher = Cipher.getInstance(ALG)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
            if (withAad) cipher.updateAAD(k.toByteArray(Charsets.UTF_8))
            String(cipher.doFinal(enc), Charsets.UTF_8)
        }.getOrNull()

        val hadCachedKey = cachedKey != null
        val primary = masterKey()
        tryDecrypt(primary, withAad = true)?.let { return it }
        tryDecrypt(primary, withAad = false)?.let { plain ->
            runCatching { putSecret(k, plain) }
            return plain
        }
        // If a stale cached SecretKey reference failed after a keystore daemon reload/lock cycle,
        // clear cache and reload once from AndroidKeyStore before trying fallback key.
        if (hadCachedKey) {
            cachedKey = null
            val refreshed = masterKey()
            if (refreshed !== primary) {
                tryDecrypt(refreshed, withAad = true)?.let { return it }
                tryDecrypt(refreshed, withAad = false)?.let { plain ->
                    runCatching { putSecret(k, plain) }
                    return plain
                }
            }
        }
        // Fallback file key recovery if putSecret fell back after an OEM KeyStore GCM error.
        val fbDir = runCatching { appCtx.noBackupFilesDir }.getOrNull() ?: appCtx.filesDir
        if (File(fbDir, ".gb_vault_key_v1").isFile) {
            val fb = loadOrCreateFallbackKey()
            tryDecrypt(fb, withAad = true)?.let { return it }
            tryDecrypt(fb, withAad = false)?.let { plain ->
                runCatching { putSecret(k, plain) }
                return plain
            }
        }
        return null
    }

    fun deleteSecret(k: String) {
        store.edit().remove(k).apply()
    }

    fun generateRandomToken(len: Int = 24): String {
        val b = ByteArray(len)
        rng.nextBytes(b)
        return b.joinToString("") { "%02x".format(it) }
    }

    fun encryptWithPassphrase(plain: ByteArray, pass: String): ByteArray {
        require(pass.isNotBlank()) { "Passphrase must not be blank" }
        val salt = ByteArray(16).also(rng::nextBytes)
        val iv = ByteArray(12).also(rng::nextBytes)
        val spec = PBEKeySpec(pass.toCharArray(), salt, PBKDF2_ITERATIONS, 256)
        val key = try {
            SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        } finally {
            spec.clearPassword()
        }
        return try {
            val c = Cipher.getInstance(ALG)
            c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
            val header = "GBAG2".toByteArray(Charsets.US_ASCII)
            c.updateAAD(header + salt)
            val enc = c.doFinal(plain)
            header + salt + iv + enc
        } finally {
            key.fill(0)
        }
    }

    companion object {
        private const val ALIAS = "grassbag_master_aes_v1"
        private const val ALG = "AES/GCM/NoPadding"
        private const val PBKDF2_ITERATIONS = 100_000

        @Volatile
        private var instance: KeystoreVault? = null

        fun getInstance(ctx: Context): KeystoreVault {
            return instance ?: synchronized(this) {
                instance ?: KeystoreVault(ctx.applicationContext).also { instance = it }
            }
        }
    }
}
