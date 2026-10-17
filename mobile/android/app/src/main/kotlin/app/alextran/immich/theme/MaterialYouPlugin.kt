package app.alextran.immich.theme

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * Fork feature: Material You theming (see FORK.md).
 *
 * `scheme` returns the color roles of the device's current Material You scheme for light and dark, exactly as the
 * system computes them, including its style (tonal spot, monochrome, …). Android 14+ exposes the roles directly as
 * `system_<role>_light/dark` colors; Android 12–13 only have the tonal palettes, so the roles are mapped from those.
 */
class MaterialYouPlugin : FlutterPlugin {
  private var channel: MethodChannel? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    val context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "immich/material_you").apply {
      setMethodCallHandler { call, result ->
        when (call.method) {
          "scheme" -> result.success(scheme(context))
          else -> result.notImplemented()
        }
      }
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
  }

  private fun scheme(context: Context): Map<String, Map<String, Long>>? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
    val light = mutableMapOf<String, Long>()
    val dark = mutableMapOf<String, Long>()
    for (role in ROLES) {
      color(context, "system_${role}_light")?.let { light[camel(role)] = it }
      color(context, "system_${role}_dark")?.let { dark[camel(role)] = it }
    }
    if (light.size < ROLES.size / 2) {
      light.clear()
      dark.clear()
      for ((role, tones) in PALETTE_ROLES) {
        color(context, tones.first)?.let { light[role] = it }
        color(context, tones.second)?.let { dark[role] = it }
      }
    }
    if (light.isEmpty() || dark.isEmpty()) return null
    return mapOf("light" to light, "dark" to dark)
  }

  @SuppressLint("DiscouragedApi")
  private fun color(context: Context, name: String): Long? {
    val id = context.resources.getIdentifier(name, "color", "android")
    if (id == 0) return null
    return context.getColor(id).toLong() and 0xFFFFFFFFL
  }

  private fun camel(role: String) =
    role.split('_').mapIndexed { i, part -> if (i == 0) part else part.replaceFirstChar { it.uppercase() } }.joinToString("")

  private companion object {
    val ROLES = listOf(
      "primary", "on_primary", "primary_container", "on_primary_container",
      "secondary", "on_secondary", "secondary_container", "on_secondary_container",
      "tertiary", "on_tertiary", "tertiary_container", "on_tertiary_container",
      "error", "on_error", "error_container", "on_error_container",
      "surface", "on_surface", "surface_variant", "on_surface_variant",
      "surface_dim", "surface_bright",
      "surface_container_lowest", "surface_container_low", "surface_container",
      "surface_container_high", "surface_container_highest",
      "outline", "outline_variant",
    )

    /** Android 12–13: role → (light tone, dark tone) from the system tonal palettes. */
    val PALETTE_ROLES = mapOf(
      "primary" to ("system_accent1_600" to "system_accent1_200"),
      "onPrimary" to ("system_accent1_0" to "system_accent1_800"),
      "primaryContainer" to ("system_accent1_100" to "system_accent1_700"),
      "onPrimaryContainer" to ("system_accent1_900" to "system_accent1_100"),
      "secondary" to ("system_accent2_600" to "system_accent2_200"),
      "onSecondary" to ("system_accent2_0" to "system_accent2_800"),
      "secondaryContainer" to ("system_accent2_100" to "system_accent2_700"),
      "onSecondaryContainer" to ("system_accent2_900" to "system_accent2_100"),
      "tertiary" to ("system_accent3_600" to "system_accent3_200"),
      "onTertiary" to ("system_accent3_0" to "system_accent3_800"),
      "tertiaryContainer" to ("system_accent3_100" to "system_accent3_700"),
      "onTertiaryContainer" to ("system_accent3_900" to "system_accent3_100"),
      "surface" to ("system_neutral1_10" to "system_neutral1_900"),
      "onSurface" to ("system_neutral1_900" to "system_neutral1_100"),
      "surfaceVariant" to ("system_neutral2_100" to "system_neutral2_700"),
      "onSurfaceVariant" to ("system_neutral2_700" to "system_neutral2_200"),
      "outline" to ("system_neutral2_500" to "system_neutral2_400"),
    )
  }
}
