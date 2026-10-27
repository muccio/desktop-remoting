package com.desktopremoting.client

import com.google.gson.Gson

sealed class InputEvent {
    abstract val type: String

    fun toJson(): String = Gson().toJson(this)
}

data class MouseMoveEvent(
    val x: Float,
    val y: Float,
    override val type: String = "mouse_move"
) : InputEvent()

data class MouseDownEvent(
    val x: Float,
    val y: Float,
    val button: String = "left",
    override val type: String = "mouse_down"
) : InputEvent()

data class MouseUpEvent(
    val x: Float,
    val y: Float,
    val button: String = "left",
    override val type: String = "mouse_up"
) : InputEvent()

data class MouseScrollEvent(
    val dx: Float = 0f,
    val dy: Float,
    override val type: String = "mouse_scroll"
) : InputEvent()

data class MouseMoveRelEvent(
    val dx: Float,
    val dy: Float,
    override val type: String = "mouse_move_rel"
) : InputEvent()

data class MouseClickEvent(
    val button: String = "left",
    val double: Boolean = false,
    override val type: String = "mouse_click"
) : InputEvent()

data class DisconnectEvent(
    override val type: String = "disconnect"
) : InputEvent()

data class KeyEvent(
    val keyCode: Int,
    val isDown: Boolean,
    override val type: String = if (isDown) "key_down" else "key_up"
) : InputEvent()

data class TextInputEvent(
    val text: String,
    override val type: String = "text_input"
) : InputEvent()
