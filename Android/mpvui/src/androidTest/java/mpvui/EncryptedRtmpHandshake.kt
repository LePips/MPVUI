package mpvui

import java.math.BigInteger
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Type 6 handshake for the loopback RTMPE fixture. */
internal class EncryptedRtmpHandshake {
    private val random = SecureRandom()
    private lateinit var confirmationKey: ByteArray
    private lateinit var incoming: CipherStream
    private lateinit var outgoing: CipherStream

    fun reply(hello: ByteArray): ByteArray? {
        if (hello.size != HANDSHAKE_BYTES + 1 || hello[0] != 6.toByte()) return null
        val client = hello.copyOfRange(1, hello.size)
        val clientDigestAt = digestOffset(client)
        val clientDigest = client.copyOfRange(clientDigestAt, clientDigestAt + 32)
        if (!MessageDigest.isEqual(clientDigest, sign(CLIENT_KEY, withoutDigest(client, clientDigestAt)))) return null

        val clientKeyAt = keyOffset(client)
        val clientKey = client.copyOfRange(clientKeyAt, clientKeyAt + KEY_BYTES)
        val clientPublic = BigInteger(1, clientKey)
        if (clientPublic < TWO || clientPublic >= PRIME - BigInteger.ONE || clientPublic.modPow(ORDER, PRIME) != BigInteger.ONE) return null

        val privateKey = BigInteger(1023, random).mod(ORDER - TWO) + TWO
        val serverKey = keyBytes(TWO.modPow(privateKey, PRIME))
        val secret = keyBytes(clientPublic.modPow(privateKey, PRIME))
        incoming = CipherStream(sign(secret, serverKey).copyOf(16))
        outgoing = CipherStream(sign(secret, clientKey).copyOf(16))

        val server = ByteArray(HANDSHAKE_BYTES).also(random::nextBytes)
        server.fill(0, 0, 8)
        server[4] = 9
        serverKey.copyInto(server, keyOffset(server))
        val serverDigestAt = digestOffset(server)
        val serverDigest = sign(SERVER_KEY, withoutDigest(server, serverDigestAt))
        serverDigest.copyInto(server, serverDigestAt)
        confirmationKey = sign(CLIENT_KEY + KEY_SUFFIX, serverDigest)

        val response = ByteArray(HANDSHAKE_BYTES - 32).also(random::nextBytes)
        return byteArrayOf(6) + server + response + sign(sign(SERVER_KEY + KEY_SUFFIX, clientDigest), response)
    }

    fun accepts(confirmation: ByteArray): Boolean {
        val payloadSize = HANDSHAKE_BYTES - 32
        return MessageDigest.isEqual(confirmation.copyOfRange(payloadSize, HANDSHAKE_BYTES), sign(confirmationKey, confirmation.copyOf(payloadSize)))
    }

    fun decrypt(data: ByteArray): ByteArray = incoming.transform(data)

    fun encrypt(data: ByteArray): ByteArray = outgoing.transform(data)

    private fun sign(key: ByteArray, data: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(key, algorithm))
        doFinal(data)
    }

    private fun withoutDigest(message: ByteArray, offset: Int): ByteArray =
        message.copyOfRange(0, offset) + message.copyOfRange(offset + 32, message.size)

    private fun digestOffset(message: ByteArray): Int = 776 + offsetSum(message, 772) % 728

    private fun keyOffset(message: ByteArray): Int = 8 + offsetSum(message, 768) % 632

    private fun offsetSum(message: ByteArray, start: Int): Int =
        (start until start + 4).sumOf { message[it].toInt() and 255 }

    private fun keyBytes(key: BigInteger): ByteArray {
        val bytes = key.toByteArray()
        val count = minOf(bytes.size, KEY_BYTES)
        return ByteArray(KEY_BYTES).also { bytes.copyInto(it, KEY_BYTES - count, bytes.size - count) }
    }

    private class CipherStream(key: ByteArray) {
        private val state = IntArray(256) { it }
        private var left = 0
        private var right = 0

        init {
            var index = 0
            for (position in state.indices) {
                index = (index + state[position] + (key[position % key.size].toInt() and 255)) and 255
                swap(position, index)
            }
            // RTMPE discards the first handshake-sized block of each RC4 stream.
            transform(ByteArray(HANDSHAKE_BYTES))
        }

        fun transform(data: ByteArray): ByteArray = ByteArray(data.size) { index ->
            left = (left + 1) and 255
            right = (right + state[left]) and 255
            swap(left, right)
            (data[index].toInt() xor state[(state[left] + state[right]) and 255]).toByte()
        }

        private fun swap(first: Int, second: Int) {
            val value = state[first]
            state[first] = state[second]
            state[second] = value
        }
    }

    private companion object {
        const val HANDSHAKE_BYTES = 1536
        const val KEY_BYTES = 128
        val TWO: BigInteger = BigInteger.valueOf(2)
        val PRIME = BigInteger(
            "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1" +
                "29024E088A67CC74020BBEA63B139B22514A08798E3404DD" +
                "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245" +
                "E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED" +
                "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381" +
                "FFFFFFFFFFFFFFFF",
            16,
        )
        val ORDER: BigInteger = (PRIME - BigInteger.ONE) / TWO
        val SERVER_KEY = "Genuine Adobe Flash Media Server 001".encodeToByteArray()
        val CLIENT_KEY = "Genuine Adobe Flash Player 001".encodeToByteArray()
        val KEY_SUFFIX = "f0eec24a8068bee82e00d0d1029e7e576eec5d2d29806fab93b8e636cfeb31ae"
            .chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    }
}
