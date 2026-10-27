package com.desktopremoting.client

import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.desktopremoting.client.databinding.ActivityMainBinding

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.btnConnect.setOnClickListener {
            val serverUrl = binding.etServerUrl.text.toString().trim()
            val macId = binding.etMacId.text.toString().trim()

            if (serverUrl.isEmpty() || macId.isEmpty()) {
                Toast.makeText(this, "Compila tutti i campi", Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }

            binding.progressBar.visibility = View.VISIBLE
            binding.btnConnect.isEnabled = false
            binding.tvStatus.text = "Inizializzazione sessione..."

            val intent = Intent(this, RemoteDesktopActivity::class.java).apply {
                putExtra("SERVER_URL", serverUrl)
                putExtra("MAC_ID", macId)
            }
            startActivity(intent)

            binding.progressBar.visibility = View.GONE
            binding.btnConnect.isEnabled = true
            binding.tvStatus.text = "Pronto alla connessione"
        }
    }
}
