package com.desktopremoting.client

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

class SignalingClient {
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()

    suspend fun pollOffer(serverBaseUrl: String, macId: String, sinceIndex: Int = 0): JSONObject =
        withContext(Dispatchers.IO) {
            val cleanUrl = if (serverBaseUrl.endsWith("/")) serverBaseUrl.dropLast(1) else serverBaseUrl
            val url = "$cleanUrl/poll.php?mac_id=$macId&role=client&since_index=$sinceIndex"

            val request = Request.Builder().url(url).get().build()
            client.newCall(request).execute().use { response ->
                val body = response.body?.string() ?: "{}"
                JSONObject(body)
            }
        }

    suspend fun sendAnswer(serverBaseUrl: String, macId: String, sdpAnswer: String) =
        withContext(Dispatchers.IO) {
            val cleanUrl = if (serverBaseUrl.endsWith("/")) serverBaseUrl.dropLast(1) else serverBaseUrl
            val url = "$cleanUrl/register.php"

            val json = JSONObject().apply {
                put("action", "answer")
                put("mac_id", macId)
                put("role", "client")
                put("sdp", sdpAnswer)
            }

            val body = json.toString().toRequestBody(jsonMediaType)
            val request = Request.Builder().url(url).post(body).build()
            client.newCall(request).execute().close()
        }

    suspend fun sendCandidate(serverBaseUrl: String, macId: String, candidate: JSONObject) =
        withContext(Dispatchers.IO) {
            val cleanUrl = if (serverBaseUrl.endsWith("/")) serverBaseUrl.dropLast(1) else serverBaseUrl
            val url = "$cleanUrl/register.php"

            val json = JSONObject().apply {
                put("action", "candidate")
                put("mac_id", macId)
                put("role", "client")
                put("candidate", candidate)
            }

            val body = json.toString().toRequestBody(jsonMediaType)
            val request = Request.Builder().url(url).post(body).build()
            client.newCall(request).execute().close()
        }

    suspend fun sendResetRequest(serverBaseUrl: String, macId: String) =
        withContext(Dispatchers.IO) {
            val cleanUrl = if (serverBaseUrl.endsWith("/")) serverBaseUrl.dropLast(1) else serverBaseUrl
            val url = "$cleanUrl/register.php"

            val json = JSONObject().apply {
                put("action", "reset_request")
                put("mac_id", macId)
                put("role", "client")
            }

            val body = json.toString().toRequestBody(jsonMediaType)
            val request = Request.Builder().url(url).post(body).build()
            client.newCall(request).execute().close()
        }
}
